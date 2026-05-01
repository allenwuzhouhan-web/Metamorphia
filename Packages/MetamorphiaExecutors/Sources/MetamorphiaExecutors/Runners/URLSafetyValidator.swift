import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Validates URLs destined for LLM-driven HTTP tools.
///
/// Tool calls like `http_request` and `fetch_url_content` let the LLM reach
/// arbitrary hosts. Without a guard, a prompt-injected tool result can steer
/// the agent to:
///   - `http://169.254.169.254/` (cloud-instance metadata),
///   - `http://127.0.0.1:…` / `http://localhost:…` (local services behind the
///     firewall — developer Postgres, Ollama admin endpoints, Redis, printer
///     config pages),
///   - `http://10.0.0.1/` / `http://192.168.1.1/` (home-network routers,
///     printers, IoT devices),
///   - `file:///etc/passwd`, `ftp://…`, `gopher://…` (scheme-based escape).
///
/// The validator rejects all of these at request-construction time. Hostnames
/// are resolved through `getaddrinfo` and every returned address is checked
/// against the private/reserved/loopback ranges — so a public-looking name that
/// points at an RFC1918 address (DNS-rebinding stage 1) is still blocked.
///
/// ### Known limitation
///
/// A fully-determined DNS-rebinding attacker can flip the name to a private
/// address *after* `validate` returns but *before* `URLSession` resolves it
/// independently. Defeating that requires IP-pinning the resolved address and
/// connecting to the pinned IP explicitly (adding a `Host:` header), which is
/// a material engineering cost for a low-frequency threat in this product.
/// The more common attacker — a malicious web page scraped into tool output
/// with an absolute URL — is blocked entirely by this validator.
public enum URLSafetyValidator {

    public enum ValidationError: LocalizedError {
        case invalidURL(String)
        case unsupportedScheme(String)
        case missingHost(String)
        case privateAddress(String, resolvedTo: String)
        case resolutionFailed(String, message: String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL(let raw):
                return "Invalid URL: \(raw)"
            case .unsupportedScheme(let scheme):
                return "URL scheme '\(scheme)' is not allowed. Only http and https are supported."
            case .missingHost(let raw):
                return "URL has no host component: \(raw)"
            case .privateAddress(let host, let addr):
                return "Host '\(host)' resolves to a private or loopback address (\(addr)); refusing to issue a request there."
            case .resolutionFailed(let host, let message):
                return "Could not resolve host '\(host)': \(message)"
            }
        }
    }

    public struct Options: Sendable {
        /// Allow http:// (in addition to https://). Default true — we're a
        /// local-network-friendly agent. If this ever ships as a sandboxed
        /// App-Store app, flip to false and require opt-in.
        public var allowHTTP: Bool
        /// Skip IP-literal + DNS resolution checks. Only use for unit tests
        /// that want to verify scheme handling in isolation.
        public var skipNetworkValidation: Bool

        public init(allowHTTP: Bool = true, skipNetworkValidation: Bool = false) {
            self.allowHTTP = allowHTTP
            self.skipNetworkValidation = skipNetworkValidation
        }

        public static let `default` = Options()
    }

    /// Validate a URL for outbound LLM-driven HTTP. Throws on any rejection.
    public static func validate(_ url: URL, options: Options = .default) throws {
        // 1. Scheme check.
        guard let scheme = url.scheme?.lowercased() else {
            throw ValidationError.unsupportedScheme("(none)")
        }
        let allowedSchemes: Set<String> = options.allowHTTP ? ["http", "https"] : ["https"]
        guard allowedSchemes.contains(scheme) else {
            throw ValidationError.unsupportedScheme(scheme)
        }

        // 2. Must have a host.
        guard let host = url.host, !host.isEmpty else {
            throw ValidationError.missingHost(url.absoluteString)
        }

        if options.skipNetworkValidation { return }

        // 3. Strip an IPv6 bracket wrapper (`[::1]` → `::1`) for classification.
        let bareHost = Self.stripBrackets(host)

        // 4. If the host is itself an IP literal, check it directly. If it's a
        // name, resolve every A/AAAA and reject if any lands in a private range.
        let resolved = try Self.resolve(host: bareHost)
        for addr in resolved {
            if Self.isForbidden(address: addr) {
                throw ValidationError.privateAddress(host, resolvedTo: addr)
            }
        }
    }

    /// Convenience: validate a URL string. Returns the parsed URL on success.
    @discardableResult
    public static func validate(_ urlString: String, options: Options = .default) throws -> URL {
        guard let url = URL(string: urlString) else {
            throw ValidationError.invalidURL(urlString)
        }
        try validate(url, options: options)
        return url
    }

    // MARK: - Host Resolution

    /// Resolve a host to its IP-literal addresses. If `host` is already an IP
    /// literal, returns `[host]` without hitting DNS. If the resolver fails,
    /// throws `.resolutionFailed`.
    static func resolve(host: String) throws -> [String] {
        if Self.parseIPv4(host) != nil || Self.parseIPv6(host) != nil {
            return [host]
        }

        #if canImport(Darwin)
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var results: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &results)
        guard status == 0 else {
            let message = String(cString: gai_strerror(status))
            throw ValidationError.resolutionFailed(host, message: message)
        }
        defer { if let results { freeaddrinfo(results) } }

        var addresses: [String] = []
        var cursor = results
        while let info = cursor {
            if let sa = info.pointee.ai_addr {
                if info.pointee.ai_family == AF_INET,
                   let ipv4 = Self.stringFromSockaddrIn(sa) {
                    addresses.append(ipv4)
                } else if info.pointee.ai_family == AF_INET6,
                          let ipv6 = Self.stringFromSockaddrIn6(sa) {
                    addresses.append(ipv6)
                }
            }
            cursor = info.pointee.ai_next
        }
        return addresses
        #else
        throw ValidationError.resolutionFailed(host, message: "getaddrinfo unavailable on this platform")
        #endif
    }

    // MARK: - Address Classification

    /// True if the address falls in a range that should not be reachable by
    /// LLM-driven HTTP: loopback, link-local, private, CGN, multicast,
    /// reserved, or unspecified.
    static func isForbidden(address: String) -> Bool {
        if let v4 = parseIPv4(address) {
            return isForbiddenIPv4(v4)
        }
        if let v6 = parseIPv6(address) {
            return isForbiddenIPv6(v6)
        }
        // Unparseable — be conservative and reject so an unknown format
        // doesn't sneak through classification.
        return true
    }

    /// IPv4 classification. `octets` is (a, b, c, d).
    private static func isForbiddenIPv4(_ octets: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        let (a, b, _, _) = octets

        // 0.0.0.0/8 "this network" — sometimes used to mean "localhost-ish".
        if a == 0 { return true }
        // 10.0.0.0/8 private.
        if a == 10 { return true }
        // 127.0.0.0/8 loopback.
        if a == 127 { return true }
        // 169.254.0.0/16 link-local (includes AWS 169.254.169.254).
        if a == 169 && b == 254 { return true }
        // 172.16.0.0/12 private (172.16.* through 172.31.*).
        if a == 172 && (b >= 16 && b <= 31) { return true }
        // 192.0.0.0/24 IETF protocol assignments (includes 192.0.0.1).
        if a == 192 && b == 0 && octets.2 == 0 { return true }
        // 192.0.2.0/24 documentation.
        if a == 192 && b == 0 && octets.2 == 2 { return true }
        // 192.168.0.0/16 private.
        if a == 192 && b == 168 { return true }
        // 198.18.0.0/15 benchmarking.
        if a == 198 && (b == 18 || b == 19) { return true }
        // 198.51.100.0/24 documentation.
        if a == 198 && b == 51 && octets.2 == 100 { return true }
        // 203.0.113.0/24 documentation.
        if a == 203 && b == 0 && octets.2 == 113 { return true }
        // 100.64.0.0/10 Carrier-Grade NAT (100.64.0.0 through 100.127.255.255).
        if a == 100 && (b >= 64 && b <= 127) { return true }
        // 224.0.0.0/4 multicast (224.x through 239.x).
        if a >= 224 && a <= 239 { return true }
        // 240.0.0.0/4 reserved (240.x through 255.x).
        if a >= 240 { return true }

        return false
    }

    /// IPv6 classification. Takes the 16-byte address.
    private static func isForbiddenIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return true }

        // ::/128 unspecified.
        if bytes.allSatisfy({ $0 == 0 }) { return true }

        // ::1/128 loopback.
        var loopback = Array(repeating: UInt8(0), count: 15)
        loopback.append(1)
        if bytes == loopback { return true }

        // fe80::/10 link-local.
        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return true }

        // fc00::/7 unique local.
        if (bytes[0] & 0xFE) == 0xFC { return true }

        // ff00::/8 multicast.
        if bytes[0] == 0xFF { return true }

        // ::ffff:0:0/96 IPv4-mapped — re-check the embedded v4.
        let v4MappedPrefix: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF]
        if Array(bytes.prefix(12)) == v4MappedPrefix {
            let v4 = (bytes[12], bytes[13], bytes[14], bytes[15])
            return isForbiddenIPv4(v4)
        }

        // ::/96 IPv4-compatible (deprecated) — re-check embedded v4.
        if bytes.prefix(12).allSatisfy({ $0 == 0 }) {
            let v4 = (bytes[12], bytes[13], bytes[14], bytes[15])
            return isForbiddenIPv4(v4)
        }

        // 2001:db8::/32 documentation.
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0D && bytes[3] == 0xB8 {
            return true
        }

        return false
    }

    // MARK: - Parsers

    static func parseIPv4(_ s: String) -> (UInt8, UInt8, UInt8, UInt8)? {
        let parts = s.split(separator: ".").map(String.init)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard let n = UInt(part), n <= 255 else { return nil }
            octets.append(UInt8(n))
        }
        return (octets[0], octets[1], octets[2], octets[3])
    }

    static func parseIPv6(_ s: String) -> [UInt8]? {
        #if canImport(Darwin)
        var addr = in6_addr()
        let ok = s.withCString { inet_pton(AF_INET6, $0, &addr) }
        guard ok == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Array($0) }
        #else
        return nil
        #endif
    }

    private static func stripBrackets(_ host: String) -> String {
        guard host.hasPrefix("[") && host.hasSuffix("]") else { return host }
        return String(host.dropFirst().dropLast())
    }

    #if canImport(Darwin)
    private static func stringFromSockaddrIn(_ sa: UnsafePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0 }
        var addr = sin.pointee.sin_addr
        guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        return String(cString: buffer)
    }

    private static func stringFromSockaddrIn6(_ sa: UnsafePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let sin6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0 }
        var addr = sin6.pointee.sin6_addr
        guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
            return nil
        }
        return String(cString: buffer)
    }
    #endif
}
