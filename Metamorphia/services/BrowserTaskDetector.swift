import Foundation

enum BrowserTaskDetector {
    static let lookupKeywords: [String] = [
        "look up", "search for", "find out", "find information",
        "find reviews", "find the best", "find prices", "compare",
        "check availability", "check the price", "research",
        "fill form", "fill out", "log in to", "login to",
        "sign up on", "sign in to", "book a", "book on",
        "order from", "order on", "purchase", "checkout",
        "add to cart", "submit form", "automate web",
        "on the website", "on the site", "using the browser",
    ]

    static let simpleNavPrefixes: [String] = [
        "go to ", "navigate to ", "browse to ", "open ",
    ]

    static let siteReferenceTokens: [String] = [
        ".com", ".org", ".net", "http", "website", "site",
        "browser", "online",
    ]

    static let complexIndicators: [String] = [
        "fill", "submit", "log in", "login", "sign in", "sign up", "register",
        "checkout", "check out", "purchase", "buy", "add to cart", "payment",
        "book ", "booking", "automate", "form", "multi-page", "multiple pages",
        "download", "upload",
    ]

    static func matches(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if simpleNavPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return false
        }

        let hasLookup = lookupKeywords.contains { lower.contains($0) }
        let hasSite = siteReferenceTokens.contains { lower.contains($0) }
        guard hasLookup && hasSite else { return false }

        return complexIndicators.contains { lower.contains($0) }
    }
}
