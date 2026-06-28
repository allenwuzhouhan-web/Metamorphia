import Foundation

// MARK: - Categories

/// Categories used for intent-aware filtering — when a query is classified,
/// only tools in matching categories are sent to the LLM. Keeps the active
/// tool count low for better model performance.
public enum ToolCategory: String, CaseIterable, Sendable, Codable {
    case appControl, music, systemSettings, power, files, web, windows
    case productivity, terminal, screenshot, clipboard, notifications
    case skills, webContent, fileContent, fileSearch, memory
    case aliases, clipboardHistory, systemInfo, automation
    case cursor, keyboard, language, scheduler, weather
    case messaging, academicResearch, documents, browser, mcp
    case systemBash, media, screenPerception
    case input
}

// MARK: - Registry

/// Central registry of all tools the LLM can invoke.
///
/// Ported from Executer with three structural changes:
///
/// 1. **Empty init.** Executer's original instantiated 220+ concrete tool structs
///    (LaunchAppTool(), MusicPlaySongTool(), ...) directly in `init`. Those tools
///    live in MetamorphiaExecutors/the Metamorphia app target — the package sees only the
///    `ToolDefinition` protocol. The app target calls `register(_:category:)` at
///    bootstrap to populate the registry.
/// 2. **`ToolSafetyClassifier.register(toolName:tier:)`** → optional ``ToolSafetyGate``
///    protocol injected at init. If `nil`, safety-tier classification is skipped.
/// 3. **`classifyQueryIntentScored(_:)`** (which delegated to `IntentScorer.shared`)
///    is removed to break the cycle. Callers that want scored classification should
///    call `IntentScorer` directly.
///
/// The registry is NOT a singleton in the package — the app target holds the
/// single instance and threads it through where needed.
public final class ToolRegistry: @unchecked Sendable {
    private var tools: [String: ToolDefinition] = [:]
    private var cachedSchemas: [[String: AnyCodable]] = []
    private var toolCategories: [String: ToolCategory] = [:]
    private var schemasByCategory: [ToolCategory: [[String: AnyCodable]]] = [:]
    private var deferredTools: [String: ToolDefinition] = [:]
    private let lock = NSLock()

    public let safetyGate: ToolSafetyGate?

    public init(safetyGate: ToolSafetyGate? = nil) {
        self.safetyGate = safetyGate
    }

    // MARK: - Registration (used by app target at bootstrap)

    /// Register a single tool with its category. Idempotent — re-registering a
    /// tool with the same name overwrites the previous definition.
    public func register(_ tool: ToolDefinition, category: ToolCategory) {
        lock.lock(); defer { lock.unlock() }
        tools[tool.name] = tool
        toolCategories[tool.name] = category
        rebuildCachesUnlocked()
    }

    /// Bulk-register tools. More efficient than calling `register(_:category:)`
    /// in a loop because caches are rebuilt once at the end.
    public func register(_ items: [(tool: ToolDefinition, category: ToolCategory)]) {
        lock.lock(); defer { lock.unlock() }
        for item in items {
            tools[item.tool.name] = item.tool
            toolCategories[item.tool.name] = item.category
        }
        rebuildCachesUnlocked()
    }

    /// Explicitly set the category for a tool name without re-registering the tool
    /// itself. Useful when the app's category map is richer than the per-registration
    /// category (e.g., the same tool belongs to multiple logical categories).
    public func setCategory(_ category: ToolCategory, forTool toolName: String) {
        lock.lock(); defer { lock.unlock() }
        toolCategories[toolName] = category
        rebuildCachesUnlocked()
    }

    // MARK: - Schema Queries

    /// All tool schemas in OpenAI function-calling format.
    public func toolDefinitions() -> [[String: AnyCodable]] {
        lock.lock(); defer { lock.unlock() }
        return cachedSchemas
    }

    /// Tool schemas filtered by explicit allowlist. Used for per-agent tool scoping.
    public func filteredToolDefinitions(allowlist: Set<String>) -> [[String: AnyCodable]] {
        lock.lock()
        let toolsCopy = tools
        lock.unlock()
        let schemas = allowlist.compactMap { name -> [String: AnyCodable]? in
            guard let tool = toolsCopy[name] else { return nil }
            return tool.toAPISchema()
        }
        print("[ToolRegistry] Filtered to \(schemas.count) tools by allowlist")
        return schemas
    }

    /// Tool schemas filtered by category set.
    public func filteredToolDefinitions(categories: Set<ToolCategory>) -> [[String: AnyCodable]] {
        lock.lock()
        let byCatCopy = schemasByCategory
        lock.unlock()
        var schemas: [[String: AnyCodable]] = []
        for cat in categories {
            if let catSchemas = byCatCopy[cat] {
                schemas.append(contentsOf: catSchemas)
            }
        }
        var seen = Set<String>()
        schemas = schemas.filter { schema in
            guard let fn = schema["function"]?.value as? [String: AnyCodable],
                  let name = fn["name"]?.value as? String else { return true }
            return seen.insert(name).inserted
        }
        return schemas
    }

    /// Tool schemas relevant to a query — uses keyword intent classification.
    /// Falls back to a narrow utility set if the classifier returned too few tools.
    public func filteredToolDefinitions(for query: String) -> [[String: AnyCodable]] {
        let categories = classifyQueryIntent(query)
        guard !categories.isEmpty else {
            print("[ToolRegistry] Direct-answer query; no tools exposed")
            return []
        }

        lock.lock()
        let byCatCopy = schemasByCategory
        let totalCount = cachedSchemas.count
        lock.unlock()

        var schemas: [[String: AnyCodable]] = []
        for cat in categories {
            if let catSchemas = byCatCopy[cat] {
                schemas.append(contentsOf: catSchemas)
            }
        }
        let count = schemas.count
        print("[ToolRegistry] Filtered to \(count) tools (from \(totalCount)) for query")
        if count < 3 && Self.shouldUseUtilityFallback(query) {
            let utilityCategories: [ToolCategory] = [.files, .fileContent, .terminal, .appControl, .systemBash]
            for cat in utilityCategories {
                if let catSchemas = byCatCopy[cat], !categories.contains(cat) {
                    schemas.append(contentsOf: catSchemas)
                }
            }
            print("[ToolRegistry] Expanded to \(schemas.count) tools with utility categories")
        }
        return schemas
    }

    /// Schemas filtered by both agent allowlist (if any) AND query intent.
    public func filteredToolDefinitions(for query: String, agent: AgentProfile) -> [[String: AnyCodable]] {
        let categories = classifyQueryIntent(query)
        guard !categories.isEmpty else {
            print("[ToolRegistry] Agent '\(agent.id)' direct-answer query; no tools exposed")
            return []
        }

        lock.lock()
        let toolsCopy = tools
        let cachedSchemasCopy = cachedSchemas
        let toolCategoriesCopy = toolCategories
        lock.unlock()

        let agentSchemas: [[String: AnyCodable]]
        if let allowed = agent.allowedToolIDs {
            agentSchemas = allowed.compactMap { name in
                guard let tool = toolsCopy[name] else { return nil }
                return tool.toAPISchema()
            }
            print("[ToolRegistry] Agent '\(agent.id)' whitelist: \(agentSchemas.count) tools")
        } else {
            agentSchemas = cachedSchemasCopy
        }

        let filtered = agentSchemas.filter { schema in
            guard let fn = schema["function"]?.value as? [String: AnyCodable],
                  let name = fn["name"]?.value as? String,
                  let cat = toolCategoriesCopy[name] else {
                return true
            }
            return categories.contains(cat)
        }

        let count = filtered.count
        print("[ToolRegistry] Agent '\(agent.id)' + intent filtered to \(count) tools")
        return count >= 3 || !Self.shouldUseUtilityFallback(query) ? filtered : agentSchemas
    }

    // MARK: - Intent Classification

    /// Canonical keyword-to-category mapping — exposed for `IntentScorer`.
    public static let intentKeywords: [(keywords: [String], categories: [ToolCategory])] = [
        (["open", "launch", "quit", "close", "switch to", "app"], [.appControl, .automation]),
        (["music", "play", "song", "pause", "next track", "shuffle"], [.music, .automation]),
        (["volume", "brightness", "dark mode", "light mode", "wifi", "bluetooth", "night shift", "dnd"], [.systemSettings, .automation]),
        (["lock", "sleep", "shutdown", "restart", "log out"], [.power, .automation]),
        (["file", "folder", "document", "move", "copy", "trash", "rename", "downloads", "organize", "finder window", "current folder", "frontmost folder"], [.files, .fileContent, .fileSearch]),
        (["project", "projects", "what am i working on", "my projects", "active projects"], [.memory, .files]),
        (["incomplete", "finish this", "complete this", "complete the", "unfinished", "half done", "finish for me"], [.documents, .fileContent]),
        (["read", "write", "edit", "create file", "save to"], [.fileContent, .files]),
        (["research", "search", "url", "web", "http", "fetch", "browse", "website",
          "current president", "current prime minister", "current ceo", "who is the current",
          "latest", "today", "right now", "up to date", "recent"],
         [.web, .webContent, .browser]),
        (["screen", "screenshot", "capture", "ocr", "look at"], [.screenshot]),
        (["click", "cursor", "scroll", "drag", "tap", "press the"], [.cursor]),
        (["type", "press key", "hotkey", "keyboard", "shortcut", "cmd+"], [.keyboard]),
        (["window", "tile", "arrange", "side by side", "fullscreen", "minimize"], [.windows]),
        (["remind", "calendar", "note", "timer", "event", "meeting", "schedule"], [.productivity, .scheduler]),
        (["mail", "email", "inbox", "mailbox", "unread", "sent me", "from lisa", "from ", "that email"], [.productivity]),
        (["terminal", "shell", "command", "run", "brew", "npm", "pip"], [.terminal, .systemBash]),
        (["git", "commit", "branch", "repo", "push", "pull", "merge", "stash"], [.systemBash, .terminal]),
        (["network", "ip", "ip address", "wifi", "ping", "dns", "speed test", "internet", "connectivity", "latency"], [.systemBash]),
        (["disk", "storage", "space", "disk usage", "free space"], [.systemBash, .systemInfo]),
        (["process", "cpu", "memory usage", "ram", "top", "kill process", "pid"], [.systemBash]),
        (["port", "listening", "address in use", "lsof", "what's using"], [.systemBash]),
        (["lines of code", "loc", "count lines", "codebase size"], [.systemBash, .fileSearch]),
        (["compress", "zip", "tar", "archive", "unzip"], [.systemBash, .files]),
        (["environment", "python version", "node version", "runtime", "installed", "which", "venv", "virtual env"], [.systemBash]),
        (["download", "curl", "wget", "fetch file"], [.systemBash, .web]),
        (["extract", "unzip", "untar", "decompress"], [.systemBash, .files]),
        (["http", "api", "request", "post", "endpoint", "rest", "curl"], [.systemBash, .web]),
        (["script", "run script", "python script", "node script", "execute code", "write a script", "code"], [.systemBash, .terminal]),
        (["pdf", "split", "merge pages", "extract page", "chapter", "separate", "convert", "parse",
          "transform", "batch", "process files", "csv", "json file", "xml", "yaml", "watermark",
          "ocr pdf", "combine pdf", "split pdf", "merge pdf", "metadata", "epub", "textbook",
          "by chapter", "by section", "each page", "page range", "data processing", "scrape",
          "crawl", "regex", "pattern match", "calculate", "compute", "analyze", "statistics",
          "chart", "plot", "graph data", "generate report", "automate", "bulk", "mass rename"],
         [.systemBash, .files, .fileContent, .automation]),
        (["install", "package", "brew install", "pip install", "npm install"], [.systemBash]),
        (["diff", "compare", "difference"], [.systemBash, .fileContent]),
        (["hash", "checksum", "md5", "sha256", "sha1", "verify"], [.systemBash]),
        (["symlink", "symbolic link", "link"], [.systemBash, .files]),
        (["permission", "chmod", "executable"], [.systemBash, .files]),
        (["serve", "http server", "localhost"], [.systemBash]),
        (["docker", "container", "compose", "image"], [.systemBash]),
        (["find replace", "sed", "refactor", "rename across"], [.systemBash, .fileContent]),
        (["base64", "encode", "decode"], [.systemBash]),
        (["json", "parse json", "jq", "pretty print"], [.systemBash]),
        (["cron", "crontab", "scheduled job"], [.systemBash, .scheduler]),
        (["ssh", "remote", "server"], [.systemBash]),
        (["text", "sort", "unique", "frequency", "column", "awk", "wc"], [.systemBash]),
        (["watch", "poll", "wait for", "monitor"], [.systemBash]),
        (["sqlite", "database", "sql", "query db"], [.systemBash]),
        (["image convert", "resize image", "sips", "heic", "png to jpg"], [.systemBash]),
        (["rename", "rename file"], [.systemBash, .files]),
        (["hardware", "system profiler", "serial number", "usb", "thunderbolt", "graphics card"], [.systemBash, .systemInfo]),
        (["define", "definition", "synonym", "spell", "meaning"], [.language]),
        (["weather", "temperature", "forecast"], [.weather]),
        (["automation", "when", "whenever", "rule", "background", "in the background", "silently", "while I work"], [.automation]),
        (["clipboard", "copied", "paste"], [.clipboard, .clipboardHistory]),
        (["remember", "memory", "recall", "forget", "what did i tell you",
          "what do you know about me", "my preference", "my preferred",
          "my usual", "last time i told you"],
         [.memory]),
        (["skill", "skills", "capability", "capabilities", "integration", "integrations",
          "what can you do", "what tools do you have", "what skills do you have"],
         [.skills]),
        (["alias", "shortcut"], [.aliases]),
        (["system info", "about this mac"], [.systemInfo]),
        (["notification", "announce", "say ", "speak"], [.notifications, .automation]),
        (["tell", "text", "message", "msg", "send message", "wechat"], [.messaging]),
        (["news", "headlines", "article"], [.academicResearch]),
        (["paper", "research paper", "scholar", "academic", "semantic scholar"], [.academicResearch]),
        (["document", "presentation", "slide", "pptx", "docx", "xlsx", "powerpoint", "word", "excel", "spreadsheet", "deck", "train", "study", "learn from", "keynote", "pages", "report", "essay", "memo", "letter", "table", "data sheet", "image", "photo", "picture", "3d", "3d model", "blender", "mesh", "glb", "obj", "fbx", "stl", "3d print"], [.documents, .files, .fileContent, .terminal, .systemBash]),
        (["fill form", "login", "sign up", "sign in", "book", "order", "purchase", "checkout", "add to cart", "scrape", "automate web", "web form", "submit form", "browser"], [.browser, .web]),
        (["notion", "notion page", "notion database", "notion db", "notion workspace",
          "add to notion", "create notion", "update notion", "notion wiki", "notion tracker"], [.productivity]),
        (["video", "ffmpeg", "narration", "tts", "text to speech", "youtube",
          "trim video", "cut video", "merge video", "subtitle", "voiceover", "mp4", "mkv", "mov",
          "background music", "sound effect", "transition", "montage",
          "promo video", "explainer", "slideshow", "ken burns", "video edit", "video production",
          "download video", "download youtube", "yt-dlp", "tiktok", "instagram video", "vimeo",
          "quick video", "make a video", "create a video", "make me a video"],
         [.media, .files, .documents]),
        (["podcast", "podcast episode", "audio episode", "audio show"],
         [.media, .files]),
        (["audio", "wav", "mp3", "m4a", "create audio", "mix audio", "audio track"],
         [.media, .files]),
    ]

    /// Always-included categories are intentionally empty. Ambient tools make
    /// weakly classified prompts look tool-worthy, which causes ordinary
    /// knowledge questions to call `recall_memory` or file search. Categories
    /// are exposed only when the query contains a concrete intent signal.
    private static let alwaysIncluded: Set<ToolCategory> = []

    /// Binary keyword-based classification. Simple, fast, deterministic.
    public func classifyQueryIntent(_ query: String) -> Set<ToolCategory> {
        let lower = query.lowercased()
        var cats = Self.alwaysIncluded

        for entry in Self.intentKeywords {
            if entry.keywords.contains(where: { Self.containsIntentKeyword($0, in: lower) }) {
                for cat in entry.categories { cats.insert(cat) }
            }
        }

        if Self.needsFreshWebInfo(lower) {
            cats.formUnion([.web, .webContent, .browser])
        }

        // Media tasks should NOT get web/browser — tools handle everything internally.
        if cats.contains(.media) {
            cats.remove(.web)
            cats.remove(.webContent)
            cats.remove(.browser)
        }

        // Web tasks often need browser interaction.
        if cats.contains(.web) || cats.contains(.webContent) {
            cats.insert(.cursor)
            cats.insert(.keyboard)
            cats.insert(.browser)
        }

        // UI interaction tasks should have keyboard shortcuts available.
        if cats.contains(.cursor) || cats.contains(.appControl) || cats.contains(.windows)
            || cats.contains(.browser) || cats.contains(.screenshot) {
            cats.insert(.keyboard)
        }

        // If nothing matched beyond always-included, prefer no tools for
        // ordinary Q&A. Use the utility fallback only for command-like prompts
        // that imply local action but do not hit a narrower keyword rule.
        if cats.count <= Self.alwaysIncluded.count, Self.shouldUseUtilityFallback(query) {
            cats.formUnion([
                .files, .fileContent, .fileSearch,
                .appControl, .windows, .keyboard, .cursor,
                .terminal, .systemBash, .systemInfo,
                .productivity, .documents, .screenshot,
            ])
        }

        return cats
    }

    private static func containsIntentKeyword(_ keyword: String, in lowercasedQuery: String) -> Bool {
        let needle = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }

        var searchStart = lowercasedQuery.startIndex
        while let range = lowercasedQuery.range(of: needle, range: searchStart..<lowercasedQuery.endIndex) {
            let hasValidPrefix: Bool
            if range.lowerBound == lowercasedQuery.startIndex {
                hasValidPrefix = true
            } else {
                let before = lowercasedQuery.index(before: range.lowerBound)
                hasValidPrefix = !lowercasedQuery[before].isLetter && !lowercasedQuery[before].isNumber
            }

            let hasValidSuffix: Bool
            if range.upperBound == lowercasedQuery.endIndex {
                hasValidSuffix = true
            } else {
                hasValidSuffix = !lowercasedQuery[range.upperBound].isLetter && !lowercasedQuery[range.upperBound].isNumber
            }

            if hasValidPrefix && hasValidSuffix {
                return true
            }
            searchStart = range.upperBound
        }

        return false
    }

    private static func needsFreshWebInfo(_ lowercasedQuery: String) -> Bool {
        let officeMarkers = [
            "potus", "president", "vice president", "vp", "prime minister",
            "pm", "chancellor", "ceo", "cfo", "cto", "mayor", "governor",
            "senator", "representative", "incumbent", "head of state"
        ]
        let questionMarkers = [
            "who", "who's", "who is", "whos", "which", "what is", "what's", "name the"
        ]
        let freshMarkers = [
            "now", "current", "currently", "today", "latest", "recent",
            "right now", "up to date", "as of"
        ]
        return officeMarkers.contains(where: { containsIntentKeyword($0, in: lowercasedQuery) })
            && (
                questionMarkers.contains(where: { containsIntentKeyword($0, in: lowercasedQuery) })
                || freshMarkers.contains(where: { containsIntentKeyword($0, in: lowercasedQuery) })
            )
    }

    private static func shouldUseUtilityFallback(_ query: String) -> Bool {
        let lower = query.lowercased()
        let actionPrefixes = [
            "open", "launch", "close", "quit", "create", "make", "build",
            "delete", "move", "copy", "rename", "find", "show", "list",
            "get", "run", "set", "change", "check", "fix", "debug",
            "install", "download", "upload", "save", "send", "click",
            "type", "press", "read", "write", "edit"
        ]
        if actionPrefixes.contains(where: { lower.hasPrefix($0 + " ") || lower == $0 }) {
            return true
        }

        let localIntentMarkers = [
            "my file", "my folder", "my download", "my desktop", "my document",
            "~/", "/users/", ".swift", ".txt", ".md", ".pdf", ".docx",
            ".pptx", ".xlsx", "this file", "this folder", "frontmost",
            "selected file", "current folder", "current window"
        ]
        return localIntentMarkers.contains { lower.contains($0) }
    }

    /// Look up the category for a tool name. Used by `IntentScorer` for historical learning.
    public func categoryForTool(_ toolName: String) -> ToolCategory? {
        lock.lock(); defer { lock.unlock() }
        return toolCategories[toolName]
    }

    // MARK: - MCP Tool Registration

    /// Register MCP-discovered tools as DEFERRED by default. They're not sent to
    /// the LLM until promoted via `search_tools`. Each tool is classified by risk
    /// tier via the injected ``ToolSafetyGate``.
    public func registerMCPTools(_ mcpTools: [any ToolDefinition]) {
        lock.lock()
        for tool in mcpTools {
            deferredTools[tool.name] = tool
            toolCategories[tool.name] = .mcp

            let tier = Self.inferredTier(forMCPToolName: tool.name)
            safetyGate?.register(toolName: tool.name, tier: tier)
        }
        let deferredCount = deferredTools.count
        let activeCount = tools.count
        lock.unlock()
        print("[ToolRegistry] Registered \(mcpTools.count) MCP tools as deferred (active: \(activeCount), deferred: \(deferredCount))")
    }

    /// Infer a conservative risk tier for an MCP tool from its name.
    private static func inferredTier(forMCPToolName name: String) -> ToolRiskTier {
        let lower = name.lowercased()
        let criticalTokens = [
            "delete", "drop", "destroy", "remove_all", "truncate",
            "shell", "exec", "execute", "run_command", "eval",
            "sudo", "root", "format", "wipe", "purge",
            "kill", "stop_all", "force",
            "password", "secret", "key", "credential",
        ]
        for token in criticalTokens where lower.contains(token) {
            return .critical
        }
        return .elevated
    }

    /// Remove all MCP tools for a given server (active + deferred).
    public func unregisterMCPTools(forServer serverName: String) {
        let prefix = "mcp__\(serverName)__"
        lock.lock()
        let activeRemoved = tools.keys.filter { $0.hasPrefix(prefix) }
        for key in activeRemoved {
            tools.removeValue(forKey: key)
            toolCategories.removeValue(forKey: key)
        }
        let deferredRemoved = deferredTools.keys.filter { $0.hasPrefix(prefix) }
        for key in deferredRemoved {
            deferredTools.removeValue(forKey: key)
            toolCategories.removeValue(forKey: key)
        }
        rebuildCachesUnlocked()
        let total = tools.count
        lock.unlock()
        let removed = activeRemoved.count + deferredRemoved.count
        if removed > 0 {
            print("[ToolRegistry] Unregistered \(removed) MCP tools for \(serverName), total active: \(total)")
        }
    }

    // MARK: - Deferred Tool API

    /// Summaries of all deferred tools — used by `DeferredToolMiddleware` to inject
    /// the manifest into the system prompt.
    public func deferredToolSummaries() -> [(name: String, description: String)] {
        lock.lock()
        let snapshot = deferredTools
        lock.unlock()
        return snapshot.map { (name: $0.key, description: String($0.value.description.prefix(120))) }
            .sorted { $0.name < $1.name }
    }

    /// Promote deferred tools to active. Rebuilds schema caches once at the end.
    public func promoteDeferred(names: Set<String>) {
        lock.lock()
        var promoted = 0
        for name in names {
            guard let tool = deferredTools.removeValue(forKey: name) else { continue }
            tools[name] = tool
            promoted += 1
        }
        guard promoted > 0 else { lock.unlock(); return }
        rebuildCachesUnlocked()
        lock.unlock()
        print("[ToolRegistry] Promoted \(promoted) deferred tools to active")
    }

    /// Fuzzy-rank deferred tools against a query.
    public func searchDeferredTools(query: String) -> [(name: String, description: String)] {
        lock.lock()
        let snapshot = deferredTools
        lock.unlock()
        return Self.fuzzyRank(query: query, tools: snapshot)
    }

    /// Fuzzy-rank active tools against a query.
    public func searchActiveTools(query: String) -> [(name: String, description: String)] {
        lock.lock()
        let snapshot = tools
        lock.unlock()
        return Self.fuzzyRank(query: query, tools: snapshot)
    }

    // MARK: - Synonym Map

    private static let synonymMap: [String: [String]] = [
        "email": ["mail", "message", "compose", "send", "smtp", "imap", "gmail", "inbox"],
        "mail": ["email", "message", "compose", "inbox", "gmail"],
        "message": ["chat", "imessage", "sms", "text", "wechat", "whatsapp", "send", "slack", "tell"],
        "send": ["post", "deliver", "submit", "publish"],
        "click": ["tap", "press", "select", "activate", "interact"],
        "type": ["enter", "input", "write", "key", "keyboard"],
        "search": ["find", "lookup", "query", "discover", "browse"],
        "find": ["search", "lookup", "locate", "discover", "where"],
        "open": ["launch", "start", "activate", "run", "show"],
        "close": ["quit", "exit", "shut", "dismiss", "stop"],
        "create": ["make", "build", "generate", "new", "produce", "compose"],
        "make": ["create", "build", "generate", "produce"],
        "build": ["create", "make", "compile", "generate"],
        "delete": ["remove", "trash", "erase", "discard", "clear"],
        "remove": ["delete", "trash", "erase", "discard"],
        "list": ["show", "display", "enumerate", "all"],
        "show": ["list", "display", "view"],
        "calendar": ["event", "schedule", "appointment", "meeting"],
        "schedule": ["calendar", "cron", "timer", "alarm", "appointment"],
        "video": ["movie", "clip", "mp4", "ffmpeg", "youtube", "footage"],
        "audio": ["sound", "music", "podcast", "voice", "tts", "mp3"],
        "image": ["photo", "picture", "img", "screenshot", "png", "jpg"],
        "screen": ["display", "monitor", "window", "view"],
        "presentation": ["slides", "pptx", "powerpoint", "deck", "keynote"],
        "document": ["doc", "docx", "word", "file", "text"],
        "spreadsheet": ["xlsx", "excel", "sheet", "table", "csv"],
        "notion": ["wiki", "page", "database", "doc"],
        "slack": ["chat", "channel", "message", "team"],
        "github": ["repo", "git", "code", "branch", "commit"],
        "remember": ["memory", "save", "store", "note", "recall"],
        "forget": ["delete", "remove", "clear"],
        "browser": ["chrome", "safari", "web", "browse", "url"],
        "url": ["link", "web", "http", "https", "address"],
        "transcribe": ["transcript", "speech", "voice", "audio"],
        "automate": ["automation", "rule", "trigger", "schedule", "cron"],
        "monitor": ["watch", "track", "observe", "poll"],
        "download": ["fetch", "save", "get", "retrieve"],
        "upload": ["post", "send", "push"],
        "edit": ["modify", "change", "update", "alter"],
        "format": ["style", "design", "layout"],
        "analyze": ["inspect", "study", "examine", "review", "audit"],
    ]

    /// Tokenize a query: lowercase, drop stop words, expand synonyms, naive stem.
    private static func expandQueryTokens(_ query: String) -> Set<String> {
        let stopWords: Set<String> = [
            "a", "an", "the", "to", "of", "for", "in", "on", "at", "is", "are",
            "and", "or", "with", "i", "me", "my", "this", "that", "it", "be",
            "do", "can", "you", "want", "need", "please", "would", "could",
            "should", "all", "some"
        ]
        let raw = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) && $0.count >= 2 }
        var expanded = Set(raw)
        for tok in raw {
            if let syns = synonymMap[tok] {
                expanded.formUnion(syns)
            }
            if tok.hasSuffix("ing") && tok.count > 5 {
                expanded.insert(String(tok.dropLast(3)))
            }
            if tok.hasSuffix("ed") && tok.count > 4 {
                expanded.insert(String(tok.dropLast(2)))
            }
            if tok.hasSuffix("s") && tok.count > 3 {
                expanded.insert(String(tok.dropLast(1)))
            }
        }
        return expanded
    }

    private static func scoreTool(name: String, description: String, tokens: Set<String>) -> Double {
        let nameLower = name.lowercased()
        let descLower = description.lowercased()
        let nameTokens = Set(nameLower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })

        var score = 0.0
        for tok in tokens {
            if nameTokens.contains(tok) { score += 5.0 }
            else if nameLower.contains(tok) { score += 3.0 }
            else if descLower.contains(tok) { score += 1.0 }
        }
        return score
    }

    private static func fuzzyRank(
        query: String,
        tools: [String: ToolDefinition]
    ) -> [(name: String, description: String)] {
        let tokens = expandQueryTokens(query)
        guard !tokens.isEmpty else { return [] }

        var scored: [(name: String, description: String, score: Double)] = []
        for (name, tool) in tools {
            let score = scoreTool(name: name, description: tool.description, tokens: tokens)
            if score > 0 {
                scored.append((name, String(tool.description.prefix(120)), score))
            }
        }
        scored.sort { $0.score > $1.score }
        return scored.map { ($0.name, $0.description) }
    }

    // MARK: - Execution

    /// Execute a tool by name. Auto-promotes deferred tools on first use.
    ///
    /// If a `ToolSafetyGate` was injected, every call is routed through
    /// `checkPermission` first. A `.deny` decision short-circuits dispatch and
    /// returns an "Error: ..." string so the LLM sees a graceful failure and
    /// can re-plan, rather than the task aborting with a thrown error.
    public func execute(toolName: String, arguments: String) async throws -> String {
        // Lock acquisition + tool lookup in a sync helper so the async `tool.execute`
        // call below never sits inside an active critical section. Avoids the Swift 6
        // "NSLock.unlock from async context" warning.
        let tool = lookupOrPromote(toolName: toolName)
        guard let tool else {
            throw MetamorphiaError.toolNotFound(toolName)
        }

        if let gate = safetyGate {
            switch await gate.checkPermission(toolName: toolName, arguments: arguments) {
            case .allow:
                break
            case .deny(let reason):
                return "Error: Tool '\(toolName)' was blocked. \(reason)"
            }
        } else if Self.builtInDenylist.contains(toolName) {
            // No gate injected — fall back to a conservative built-in denylist so a
            // mis-wired path can't dispatch known-destructive tools unsupervised.
            // The app's real path injects a gate and never reaches this branch.
            return "Error: Tool '\(toolName)' was blocked. No safety gate is configured; "
                + "this tool can take destructive autonomous action and is denied by default."
        }

        return try await tool.execute(arguments: arguments)
    }

    /// Conservative deny set used only when no ``ToolSafetyGate`` is injected.
    /// Mirrors the destructive autonomous-input / file / process tools the app's
    /// real gate classifies as critical. Read-only perception/web tools are NOT
    /// listed so the nil-gate fallback doesn't wreck ordinary read paths.
    private static let builtInDenylist: Set<String> = [
        "computer_batch", "key_combo", "type", "press", "invoke_menu",
        "drag", "swipe", "click_at",
        "run_shell_command", "run_applescript", "run_python", "run_node", "run_ruby",
        "kill_process", "file_operation", "write_file", "edit_file",
    ]

    /// Synchronous lock-protected lookup. If the tool is deferred, it's promoted
    /// to active and caches are rebuilt before returning.
    private func lookupOrPromote(toolName: String) -> ToolDefinition? {
        lock.lock()
        defer { lock.unlock() }

        if let active = tools[toolName] {
            return active
        }
        if let deferred = deferredTools[toolName] {
            deferredTools.removeValue(forKey: toolName)
            tools[toolName] = deferred
            rebuildCachesUnlocked()
            print("[ToolRegistry] Auto-promoted deferred tool: \(toolName)")
            return deferred
        }
        return nil
    }

    public func tool(named name: String) -> ToolDefinition? {
        lock.lock(); defer { lock.unlock() }
        return tools[name]
    }

    public func executeDirectly(toolName: String, arguments: String) async throws -> String {
        try await execute(toolName: toolName, arguments: arguments)
    }

    public func singleToolSchema(_ name: String) -> [[String: AnyCodable]]? {
        lock.lock()
        let tool = tools[name]
        lock.unlock()
        guard let tool else { return nil }
        return [tool.toAPISchema()]
    }

    public func allToolNames() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(tools.keys).sorted()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return tools.count
    }

    // MARK: - Private: Cache Rebuild

    /// Rebuild `cachedSchemas` and `schemasByCategory` from scratch. Must be called
    /// inside the lock.
    private func rebuildCachesUnlocked() {
        cachedSchemas = tools.values.map { $0.toAPISchema() }
        var byCategory: [ToolCategory: [[String: AnyCodable]]] = [:]
        for (name, tool) in tools {
            let cat = toolCategories[name] ?? .files
            byCategory[cat, default: []].append(tool.toAPISchema())
        }
        schemasByCategory = byCategory
    }
}

// MARK: - ToolCatalog Adapter

/// Adapter so `ToolRegistry` can serve as the `ToolCatalog` for `DeferredToolMiddleware`
/// and `SearchToolsTool`. The adapter lives in the package so the middleware doesn't
/// need to know about `ToolRegistry` directly — it uses the protocol.
public final class ToolRegistryCatalogAdapter: ToolCatalog, @unchecked Sendable {
    private let registry: ToolRegistry

    public init(registry: ToolRegistry) {
        self.registry = registry
    }

    public func deferredToolSummaries() -> [ToolSummary] {
        registry.deferredToolSummaries().map { ToolSummary(name: $0.name, description: $0.description) }
    }

    public func searchDeferredTools(query: String) -> [ToolSummary] {
        registry.searchDeferredTools(query: query).map { ToolSummary(name: $0.name, description: $0.description) }
    }

    public func searchActiveTools(query: String) -> [ToolSummary] {
        registry.searchActiveTools(query: query).map { ToolSummary(name: $0.name, description: $0.description) }
    }

    public func promoteDeferred(names: Set<String>) {
        registry.promoteDeferred(names: names)
    }

    public func activeToolNames() -> [String] {
        registry.allToolNames()
    }

    public func singleToolSchema(_ toolName: String) -> [[String: AnyCodable]]? {
        registry.singleToolSchema(toolName)
    }

    public func execute(toolName: String, arguments: String) async throws -> String {
        try await registry.execute(toolName: toolName, arguments: arguments)
    }
}

// MARK: - AgentProfile

/// Agent-level tool scoping. An `AgentProfile` identifies a subagent and optionally
/// restricts which tools it can use.
public struct AgentProfile: Sendable {
    public let id: String
    /// Optional allowlist of tool names. If `nil`, the agent has access to all tools.
    public let allowedToolIDs: Set<String>?

    public init(id: String, allowedToolIDs: Set<String>? = nil) {
        self.id = id
        self.allowedToolIDs = allowedToolIDs
    }

    /// The default "general-purpose" agent with access to all tools.
    public static let general = AgentProfile(id: "general", allowedToolIDs: nil)
}

// MARK: - RequestToolsTool (legacy meta-tool)

/// Legacy fallback — replaced by `SearchToolsTool` but retained for compatibility
/// with prompt templates that still reference it.
public struct RequestToolsTool: ToolDefinition {
    public let name = "request_tools"
    public let description = "Request additional tools that aren't currently available. Use this when you need a tool that wasn't provided. Describe what you need and I'll find matching tools."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "need": JSONSchema.string(description: "What capability you need (e.g., 'click on UI element', 'create a file', 'send a message')"),
        ], required: ["need"])
    }

    private let registry: ToolRegistry

    public init(registry: ToolRegistry) {
        self.registry = registry
    }

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let need = try requiredString("need", from: args)

        let activeMatches = registry.searchActiveTools(query: need)
        let deferredMatches = registry.searchDeferredTools(query: need)

        if !deferredMatches.isEmpty {
            let names = Set(deferredMatches.prefix(10).map(\.name))
            registry.promoteDeferred(names: names)
        }

        let combined = deferredMatches + activeMatches
        guard !combined.isEmpty else {
            return "No matching tools found for '\(need)'. Try a different description."
        }

        var seen = Set<String>()
        var result = "Available tools matching '\(need)':\n"
        var shown = 0
        for match in combined where seen.insert(match.name).inserted {
            result += "- **\(match.name)**: \(match.description)\n"
            shown += 1
            if shown >= 12 { break }
        }
        result += "\nYou can now call any of these tools directly."
        return result
    }
}
