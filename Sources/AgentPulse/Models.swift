import Foundation

enum SessionStatus: String, Codable, Sendable {
    case thinking         // Prompt submitted, agent reasoning — no tool yet
    case running          // Agent is executing a tool
    case waiting          // Agent is waiting for user input / permission
    case idle             // Turn ended, no pending prompt
}

struct TerminalHint: Codable, Sendable, Equatable {
    var termProgram: String?          // iTerm.app, Apple_Terminal, JetBrains-JediTerm, vscode (also Cursor!), ...
    var iTermSessionId: String?       // $ITERM_SESSION_ID
    var tmuxPane: String?             // $TMUX_PANE
    var tmuxSocket: String?           // parsed from $TMUX
    var wezTermPane: String?          // $WEZTERM_PANE
    var terminalEmulator: String?     // $TERMINAL_EMULATOR (JetBrains)
    var bundleIdentifier: String?     // $__CFBundleIdentifier — usually distinguishes GoLand vs IntelliJ etc
    var hostApp: String?              // parent process app name (e.g. "Cursor", "Code", "Windsurf") — beats env vars when forks share TERM_PROGRAM
    var ppid: Int?                    // parent pid of the hook process
    var tty: String?                  // best-effort tty path
}

struct PendingTool: Codable, Sendable, Equatable {
    var name: String                  // "Bash", "Edit", "Write", "Read", ...
    var summary: String               // one-line preview of the input (e.g. "rm -rf /tmp/foo")
}

struct Session: Codable, Sendable, Identifiable {
    var id: String                    // session_id from the agent
    var agent: String?                // "claude", "aider", "gemini", ... nil = unknown
    var cwd: String
    var status: SessionStatus
    var startedAt: Date
    var updatedAt: Date
    var lastNotification: String?     // "permission_prompt" | "idle_prompt" | ...
    var transcriptPath: String?
    var terminal: TerminalHint?
    var activity: String?             // "Bash", "Edit foo.ts", ... set by PreToolUse, cleared by PostToolUse/Stop
    var customTitle: String?          // user-assigned label (e.g. from Claude's /rename)
    var pendingTool: PendingTool?     // populated when status == .waiting (from transcript scan)

    var displayName: String {
        if let t = customTitle, !t.isEmpty { return t }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}

/// Raw event coming in from a hook over HTTP.
/// This is the public API contract — see docs/api.md.
struct HookEvent: Codable, Sendable {
    var event: String                 // "SessionStart" | "Stop" | "Notification" | "SessionEnd" | "PreToolUse" | "PostToolUse" | "UserPromptSubmit" | "CwdChanged"
    var sessionId: String
    var agent: String? = nil          // identifier of the originating agent
    var cwd: String? = nil
    var transcriptPath: String? = nil
    var notificationType: String? = nil
    var exitReason: String? = nil
    var toolName: String? = nil
    var toolSummary: String? = nil
    var terminal: TerminalHint? = nil

    enum CodingKeys: String, CodingKey {
        case event
        case sessionId = "session_id"
        case agent
        case cwd
        case transcriptPath = "transcript_path"
        case notificationType = "notification_type"
        case exitReason = "exit_reason"
        case toolName = "tool_name"
        case toolSummary = "tool_summary"
        case terminal
    }
}
