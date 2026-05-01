import Foundation
import IOKit.ps
import MetamorphiaAgentKit

/// Structured system snapshot: hostname, macOS version, uptime, CPU count,
/// memory, disk usage (for /), battery level if available.
///
/// Single-call replacement for a handful of shell one-liners the agent would
/// otherwise string together.
public struct SystemInfoTool: ToolDefinition {
    public let name = "system_info"
    public let description = "Report the Mac's hostname, macOS version, uptime, CPU count, RAM, disk usage, and battery level. Use for 'how's my Mac doing', 'how much disk space left', 'what's the uptime'."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let pi = ProcessInfo.processInfo
        let host = pi.hostName
        let os = pi.operatingSystemVersionString
        let cpuCount = pi.activeProcessorCount
        let physicalMem = pi.physicalMemory
        let uptime = pi.systemUptime
        let formatter = ByteCountFormatter()

        var lines: [String] = []
        lines.append("Host: \(host)")
        lines.append("OS: \(os)")
        lines.append("Uptime: \(formatUptime(uptime))")
        lines.append("CPU cores: \(cpuCount)")
        lines.append("RAM: \(formatter.string(fromByteCount: Int64(physicalMem)))")

        if let diskLine = diskUsageLine(for: "/") {
            lines.append(diskLine)
        }
        if let batteryLine = batteryLine() {
            lines.append(batteryLine)
        }

        return lines.joined(separator: "\n")
    }

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func diskUsageLine(for path: String) -> String? {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: path)
            guard
                let total = attrs[.systemSize] as? NSNumber,
                let free = attrs[.systemFreeSize] as? NSNumber
            else { return nil }
            let used = total.int64Value - free.int64Value
            let fm = ByteCountFormatter()
            let pct = Int((Double(used) / Double(total.int64Value)) * 100)
            return "Disk (/): \(fm.string(fromByteCount: used)) used of \(fm.string(fromByteCount: total.int64Value)) (\(pct)%), \(fm.string(fromByteCount: free.int64Value)) free"
        } catch {
            return nil
        }
    }

    private func batteryLine() -> String? {
        let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        guard let snapshot else { return nil }
        let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            guard let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let max = info[kIOPSMaxCapacityKey] as? Int else { continue }
            let state = info[kIOPSPowerSourceStateKey] as? String ?? "unknown"
            let pct = max > 0 ? Int(Double(current) / Double(max) * 100) : 0
            let isCharging = state == (kIOPSACPowerValue as String)
            return "Battery: \(pct)% (\(isCharging ? "charging" : "on battery"))"
        }
        return nil
    }
}

/// List running processes, with optional name-match filter. Thin wrapper over
/// `ps -axo pid,user,%cpu,%mem,comm` — returns the first N matches.
public struct ListProcessesTool: ToolDefinition {
    public let name = "list_processes"
    public let description = "List running processes. Optional `filter` does a case-insensitive substring match against the command name. Returns PID, user, %CPU, %MEM, command."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "filter": JSONSchema.string(description: "Case-insensitive substring match against command name (optional)."),
            "limit": JSONSchema.integer(description: "Max rows to return (default 30, max 300).", minimum: 1, maximum: 300),
            "sort_by_cpu": JSONSchema.boolean(description: "Sort by CPU% desc (default true). False = PID order."),
        ], required: [])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let filter = optionalString("filter", from: args)?.lowercased()
        let limit = optionalInt("limit", from: args) ?? 30
        let sortByCPU = optionalBool("sort_by_cpu", from: args) ?? true

        let psCmd = sortByCPU ? "ps -axo pid,user,%cpu,%mem,comm -r" : "ps -axo pid,user,%cpu,%mem,comm"
        let result = try ShellRunner.run(psCmd, timeout: 10)
        let allLines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard allLines.count > 1 else {
            return "Error: ps returned no output."
        }
        let header = allLines[0]
        var body = Array(allLines.dropFirst())
        if let filter {
            body = body.filter { $0.lowercased().contains(filter) }
        }
        let sliced = Array(body.prefix(limit))
        if sliced.isEmpty {
            return "No processes matching '\(filter ?? "")'."
        }
        return ([header] + sliced).joined(separator: "\n")
    }
}

/// Send a signal to a process (default SIGTERM). Accepts a PID or a name
/// (resolved via pgrep). Marked for elevated/critical safety tier at
/// registration time.
public struct KillProcessTool: ToolDefinition {
    public let name = "kill_process"
    public let description = "Send a signal to a process. Pass `pid` OR `name` (not both). Default signal is TERM (graceful). Use KILL only if TERM didn't work. Dangerous — confirm with the user before killing anything critical."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "pid": JSONSchema.integer(description: "Process ID to signal.", minimum: 1),
            "name": JSONSchema.string(description: "Process name — matched via pgrep. Kills every matching process."),
            "signal": JSONSchema.enumString(description: "Signal to send. Default TERM.", values: ["TERM", "INT", "HUP", "QUIT", "KILL", "USR1", "USR2"]),
        ], required: [])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let signal = optionalString("signal", from: args) ?? "TERM"
        let pid = optionalInt("pid", from: args)
        let name = optionalString("name", from: args)

        guard pid != nil || name != nil else {
            throw MetamorphiaError.invalidArguments("kill_process needs pid or name.")
        }
        if pid != nil && name != nil {
            return "Error: pass pid OR name, not both."
        }

        let cmd: String
        if let pid {
            cmd = "kill -\(signal) \(pid)"
        } else if let name {
            // pgrep returns non-zero exit (1) when there are no matches.
            // pkill signals every match. Quote the name to avoid splitting.
            cmd = "pkill -\(signal) -f \(shellEscape(name))"
        } else {
            return "Error: unreachable."
        }
        let result = try ShellRunner.run(cmd, timeout: 5)
        if result.exitCode != 0 {
            return "Signal \(signal) returned exit \(result.exitCode). Output: \(result.stdout.isEmpty ? "(empty)" : result.stdout)"
        }
        return "Sent SIG\(signal) to \(pid.map(String.init) ?? "processes matching \"\(name ?? "")\"")."
    }

    private func shellEscape(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
