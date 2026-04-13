import Foundation

/// Centralized user-facing strings. English only — the project ships in
/// one language and routes everything through here so future translation
/// (or just renaming a label) is a one-file edit.
enum L10n {
    // Brand
    static var appShortName: String { "AgentPulse" }

    // Header
    static var waitingBadge: (Int) -> String = { n in "\(n) waiting" }

    // Empty state
    static var noSessions: String { "no active sessions" }

    // Status lines
    static var statusWaiting:  String { "waiting for permission" }
    static var statusThinking: String { "thinking" }
    static var statusRunning:  String { "running" }
    static var statusIdle:     String { "idle" }

    // Context menu / actions
    static var jumpToTerminal: String { "Jump to terminal" }
    static var revealInFinder: String { "Reveal in Finder" }
    static var removeFromList: String { "Remove from list" }
    static var quit:           String { "Quit" }

    // Notification
    static var notificationPermissionLine: String { "permission prompt" }

    /// Map the short agent identifier used in the hook payload to the
    /// marketing name users recognize. "claude" → "Claude Code", etc.
    static func agentDisplayName(_ agent: String?) -> String {
        guard let a = agent?.lowercased(), !a.isEmpty else { return "Agent" }
        switch a {
        case "claude":        return "Claude Code"
        case "aider":         return "Aider"
        case "gemini":        return "Gemini CLI"
        case "codex":         return "Codex CLI"
        case "cursor":        return "Cursor"
        default:              return agent!.capitalized
        }
    }
}
