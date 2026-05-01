import Foundation

/// Specialized sub-agent types with focused tool sets and system prompts.
/// Each type reduces token usage from 220+ tools to 10-25 relevant ones.
public enum SubAgentType: String, CaseIterable, Sendable {
    case researcher
    case fileOperator
    case systemControl
    case uiAutomation
    case composer

    public var toolCategories: Set<ToolCategory> {
        switch self {
        case .researcher:
            return [.web, .webContent, .clipboard, .memory, .academicResearch]
        case .fileOperator:
            return [.files, .fileContent, .fileSearch, .terminal]
        case .systemControl:
            return [.appControl, .systemSettings, .power, .music, .windows, .notifications, .scheduler]
        case .uiAutomation:
            return [.cursor, .keyboard, .screenshot, .appControl]
        case .composer:
            return [.clipboard, .fileContent, .memory, .notifications, .language]
        }
    }

    public var focusedSystemPrompt: String {
        switch self {
        case .researcher:
            return """
            You are a research sub-agent. Fetch academic papers and web content using your tools.
            ALWAYS use semantic_scholar_search to find academic papers first, then fetch_url_content for web sources. Never answer from memory alone.
            For deep research: use limit=10 for 10+ papers. For quick lookups: use limit=3.
            Use get_paper_details for the top cited papers to get abstracts and TL;DRs.
            Format findings as: **Key finding** | source_url
            Be concise. Batch semantic_scholar_search and fetch_url_content calls in one response for speed.
            """
        case .fileOperator:
            return """
            You are a file operations sub-agent. Search, read, write, and organize files.
            The user's main files are in ~/Documents/works (usually the G8 subfolder).
            Use find_files to locate files, read_file for text, read_pdf_text for PDFs.
            Be careful with destructive operations — confirm paths before moving or deleting.
            """
        case .systemControl:
            return """
            You are a system control sub-agent. Manage apps, windows, system settings, and music.
            Be concise — confirm actions in 5 words or less. "Done." is perfect.
            Batch independent tool calls (e.g., multiple quit_app) in one response.
            """
        case .uiAutomation:
            return """
            You are a UI automation sub-agent. Control the cursor, keyboard, and screen.
            Batch sequential UI actions together. Trust your commands — don't verify with screenshots.
            Only use capture_screen when you genuinely need to see what's on screen.
            """
        case .composer:
            return """
            You are a writing sub-agent. Draft text, compose emails, and format content.
            Write clearly and concisely. Use set_clipboard_text to make output easily accessible.
            Match the user's tone from context.
            """
        }
    }

    /// Infer sub-agent type from a task description.
    public static func infer(from description: String) -> SubAgentType {
        let lower = description.lowercased()

        if lower.contains("research") || lower.contains("fetch") || lower.contains("url") ||
           lower.contains("search") || lower.contains("web") || lower.contains("look up") ||
           lower.contains("find out") || lower.contains("source") {
            return .researcher
        }
        if lower.contains("file") || lower.contains("folder") || lower.contains("read") ||
           lower.contains("write") || lower.contains("move") || lower.contains("organize") ||
           lower.contains("directory") || lower.contains("download") {
            return .fileOperator
        }
        if lower.contains("click") || lower.contains("type") || lower.contains("cursor") ||
           lower.contains("scroll") || lower.contains("screenshot") || lower.contains("screen") ||
           lower.contains("press") || lower.contains("keyboard") {
            return .uiAutomation
        }
        if lower.contains("draft") || lower.contains("compose") || lower.contains("write") ||
           lower.contains("email") || lower.contains("summarize") || lower.contains("format") {
            return .composer
        }
        return .systemControl
    }
}
