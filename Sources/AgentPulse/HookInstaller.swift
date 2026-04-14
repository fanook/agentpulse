import Foundation

/// Swift port of `hooks/claude/install.sh` — wires (or unwires) the
/// AgentPulse hook bridge entries in `~/.claude/settings.json`. Lets
/// users installed via the DMG set things up without ever opening a
/// terminal.
///
/// The path baked into `settings.json` points at `report.sh` bundled
/// inside `AgentPulse.app/Contents/Resources`. Moving the .app after
/// install invalidates the path — `isInstalled()` notices that, and
/// clicking Connect again rewrites the entries with the new path.
enum HookInstaller {
    static let sentinel       = "# agentpulse-hook"
    static let legacySentinel = "# tap-hook"

    /// Every Claude Code lifecycle event we hook. Keep in lockstep with
    /// `hooks/claude/install.sh` so the shell-installed and app-installed
    /// variants stay interchangeable.
    static let events = [
        "SessionStart", "Stop", "Notification", "SessionEnd",
        "PreToolUse", "PostToolUse", "CwdChanged", "UserPromptSubmit",
    ]

    static var settingsURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/settings.json")
    }

    /// Path to the `report.sh` we'll register in Claude's config.
    /// Inside the .app bundle for DMG/CI installs; nil when running via
    /// `swift run` without a bundle (dev mode).
    static var bundledReportScriptPath: String? {
        Bundle.main.url(forResource: "report", withExtension: "sh")?.path
    }

    enum Status {
        case installed           // Our entries are present and point to the current bundle
        case needsRelink         // Entries exist but point to a different (old) bundle path
        case notInstalled        // No AgentPulse entries
        case noReportScript      // Running from `swift run` — no bundled report.sh to reference

        var isActive: Bool { self == .installed }
    }

    static func currentStatus() -> Status {
        guard let reportPath = bundledReportScriptPath else { return .noReportScript }
        guard let json = readSettings(),
              let hooks = json["hooks"] as? [String: Any]
        else { return .notInstalled }

        var sawAnyOurs    = false
        var sawMismatch   = false
        var missingEvents = false

        for evt in events {
            let arr = (hooks[evt] as? [[String: Any]]) ?? []
            let ourCommands = arr.flatMap { entry -> [String] in
                let inner = (entry["hooks"] as? [[String: Any]]) ?? []
                return inner.compactMap { $0["command"] as? String }
            }.filter { $0.contains(sentinel) }

            if ourCommands.isEmpty {
                missingEvents = true
            } else {
                sawAnyOurs = true
                if !ourCommands.contains(where: { $0.hasPrefix(reportPath) }) {
                    sawMismatch = true
                }
            }
        }

        if !sawAnyOurs    { return .notInstalled }
        if missingEvents  { return .needsRelink }
        if sawMismatch    { return .needsRelink }
        return .installed
    }

    /// Merge our hook entries into `~/.claude/settings.json`, stripping any
    /// previous AgentPulse entries (or legacy `# tap-hook` ones).
    static func install() throws {
        guard let reportPath = bundledReportScriptPath else {
            throw HookInstallerError.noReportScript
        }
        var json = readSettings() ?? [:]
        var hooks = (json["hooks"] as? [String: Any]) ?? [:]

        for evt in events {
            var arr = (hooks[evt] as? [[String: Any]]) ?? []
            arr = strip(arr)
            let entry: [String: Any] = [
                "hooks": [
                    [
                        "type":    "command",
                        "command": "\(reportPath) \(evt) \(sentinel)"
                    ]
                ]
            ]
            arr.append(entry)
            hooks[evt] = arr
        }
        json["hooks"] = hooks
        try writeSettings(json)
    }

    /// Strip every AgentPulse (or legacy tap-hook) entry from the config.
    /// Leaves hooks from other tools alone.
    static func uninstall() throws {
        guard var json = readSettings() else { return }
        guard var hooks = json["hooks"] as? [String: Any] else { return }

        for evt in events {
            var arr = (hooks[evt] as? [[String: Any]]) ?? []
            arr = strip(arr)
            if arr.isEmpty { hooks.removeValue(forKey: evt) }
            else           { hooks[evt] = arr }
        }
        if hooks.isEmpty { json.removeValue(forKey: "hooks") }
        else             { json["hooks"] = hooks }

        try writeSettings(json)
    }

    // MARK: - Internals

    private static func strip(_ entries: [[String: Any]]) -> [[String: Any]] {
        entries.compactMap { entry -> [String: Any]? in
            var entry = entry
            let inner = (entry["hooks"] as? [[String: Any]]) ?? []
            let filtered = inner.filter { hook in
                let cmd = (hook["command"] as? String) ?? ""
                return !cmd.contains(sentinel) && !cmd.contains(legacySentinel)
            }
            if filtered.isEmpty { return nil }
            entry["hooks"] = filtered
            return entry
        }
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func writeSettings(_ json: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: settingsURL, options: .atomic)
    }
}

enum HookInstallerError: LocalizedError {
    case noReportScript

    var errorDescription: String? {
        switch self {
        case .noReportScript:
            return "report.sh isn't bundled in this build. Reinstall via the DMG or run install.sh."
        }
    }
}
