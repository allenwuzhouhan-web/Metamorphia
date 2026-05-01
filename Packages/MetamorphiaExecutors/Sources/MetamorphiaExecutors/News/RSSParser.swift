import Foundation

/// SAX-based RSS 2.0 parser. Produces `[NewsArticle]` from a raw feed blob.
///
/// Thread safety: `RSSParser` is a value type whose `parse` method constructs
/// a fresh `Delegate` each call, so concurrent calls are safe.
///
/// HTML stripping: `<description>` and `<title>` sometimes contain entity-
/// encoded HTML. We strip tags with a simple regex fallback rather than
/// bouncing through `NSAttributedString`'s `.html` document type — the
/// AppKit/WebKit HTML parser it calls internally is not concurrency-safe and
/// requires a main-thread dispatch, which would block the async caller.
/// A tag-stripping regex is sufficient for RSS snippets.
public struct RSSParser: Sendable {
    public init() {}

    public func parse(_ data: Data, feedOrigin: NewsFeedOrigin) throws -> [NewsArticle] {
        let delegate = Delegate(feedOrigin: feedOrigin)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        if let error = delegate.parseError {
            throw error
        }
        return delegate.articles
    }

    // MARK: - Parse errors

    public enum ParseError: Error, LocalizedError {
        case xmlError(String)

        public var errorDescription: String? {
            if case .xmlError(let msg) = self { return "RSS parse error: \(msg)" }
            return nil
        }
    }
}

// MARK: - Private SAX delegate

/// One-shot delegate — created per `parse` call, not reused.
private final class Delegate: NSObject, XMLParserDelegate, @unchecked Sendable {
    let feedOrigin: NewsFeedOrigin
    var articles: [NewsArticle] = []
    var parseError: Error?

    // Current item state
    private var inItem = false
    private var currentElement = ""
    private var currentTitle = ""
    private var currentLink = ""
    private var currentDescription = ""
    private var currentPubDate = ""
    private var currentSource = ""
    private var currentSourceURL = ""

    // Atom / Media extensions
    private var currentCreator = ""

    private let rfc822: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    private let rfc822Short: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    init(feedOrigin: NewsFeedOrigin) {
        self.feedOrigin = feedOrigin
    }

    // MARK: XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        if elementName == "item" || elementName == "entry" {
            inItem = true
            currentTitle = ""
            currentLink = ""
            currentDescription = ""
            currentPubDate = ""
            currentSource = ""
            currentSourceURL = ""
            currentCreator = ""
        }
        // RSS <source url="...">Name</source>
        if elementName == "source", let url = attributeDict["url"] {
            currentSourceURL = url
        }
        // Atom <link href="..." />
        if elementName == "link", inItem,
           let rel = attributeDict["rel"], rel == "alternate" || rel == "",
           let href = attributeDict["href"], !href.isEmpty {
            currentLink = href
        } else if elementName == "link", inItem, currentLink.isEmpty,
                  let href = attributeDict["href"], !href.isEmpty {
            currentLink = href
        }
    }

    func parser(
        _ parser: XMLParser,
        foundCharacters string: String
    ) {
        guard inItem else { return }
        switch currentElement {
        case "title":       currentTitle       += string
        case "link":        currentLink        += string
        case "description", "summary", "content:encoded": currentDescription += string
        case "pubDate", "published", "updated":            currentPubDate     += string
        case "source":      currentSource      += string
        case "dc:creator", "author":                       currentCreator     += string
        default: break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "item" || elementName == "entry" {
            commitArticle()
            inItem = false
        }
        currentElement = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = RSSParser.ParseError.xmlError(parseError.localizedDescription)
    }

    // MARK: - Article assembly

    private func commitArticle() {
        let title = stripHTML(currentTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        var link  = currentLink.trimmingCharacters(in: .whitespacesAndNewlines)

        // Google News redirect links — keep as-is; the LLM can open them.
        // Plain links may be accumulated character-by-character, strip whitespace.
        link = link.components(separatedBy: .newlines).joined()

        guard !title.isEmpty, !link.isEmpty else { return }

        // Source name: prefer explicit <source> text, fall back to creator, then feed origin.
        let source: String = {
            let s = currentSource.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { return s }
            let c = currentCreator.trimmingCharacters(in: .whitespacesAndNewlines)
            if !c.isEmpty { return c }
            return feedOrigin.rawValue
        }()

        let date = parseDate(currentPubDate.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Date()
        let snippet = stripHTML(currentDescription)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .truncated(to: 300)

        articles.append(NewsArticle(
            title: title,
            link: link,
            source: source,
            publishedAt: date,
            snippet: snippet,
            feedOrigin: feedOrigin
        ))
    }

    // MARK: - HTML strip (regex-based, safe on any thread)

    private func stripHTML(_ raw: String) -> String {
        // Decode common HTML entities first.
        var s = raw
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;",  with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&apos;", with: "'")

        // Strip all remaining HTML tags.
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>") {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        }
        // Collapse whitespace.
        s = s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return s
    }

    // MARK: - Date parsing

    private func parseDate(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        // RFC 822 with day-of-week
        if let d = rfc822.date(from: raw)      { return d }
        // RFC 822 without day-of-week
        if let d = rfc822Short.date(from: raw) { return d }
        // ISO 8601 / Atom
        if let d = ISO8601DateFormatter().date(from: raw) { return d }
        // Try stripping a fractional-seconds component that ISO8601DateFormatter
        // might not handle on older OS versions.
        let trimmed = raw.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression
        )
        return ISO8601DateFormatter().date(from: trimmed)
    }
}

// MARK: - String helpers

private extension String {
    func truncated(to length: Int) -> String {
        guard count > length else { return self }
        return String(prefix(length)) + "…"
    }
}
