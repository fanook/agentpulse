import Foundation
import AppKit

enum Jumper {
    static func jump(to session: Session) {
        guard let hint = session.terminal else { return }
        // Order matters: iTerm/tmux give tab-precise jumps; JetBrains
        // bundle id is exact; generic hostApp / bundle id is the fallback
        // for editors like Cursor / VS Code / Windsurf / Zed where the
        // best we can do is bring the IDE window forward.
        if jumpITerm(hint: hint) { return }
        if jumpTmux(hint: hint) { return }
        if activateJetBrains(hint: hint) { return }
        _ = activateGenericApp(hint: hint)
    }

    /// Explicit Finder reveal — used only from the context menu.
    static func revealInFinder(_ session: Session) {
        NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd))
    }

    // MARK: - Input sanitization (defense against injection via hook payload)

    /// iTerm session UUIDs are standard UUIDs (hex + dashes). Anything else
    /// is untrusted and we refuse to interpolate it into an AppleScript.
    private static let uuidRegex = try! NSRegularExpression(
        pattern: "^[0-9A-Fa-f-]{1,64}$")

    /// tmux pane ids look like `%12`; targets can include session/window too
    /// e.g. `session:window.%pane`. Keep to a conservative allow-list.
    private static let tmuxTargetRegex = try! NSRegularExpression(
        pattern: "^[A-Za-z0-9_:.%-]{1,128}$")

    /// tmux socket paths live in system tmp; only allow absolute paths with
    /// filesystem-safe chars.
    private static let tmuxSocketRegex = try! NSRegularExpression(
        pattern: "^/[A-Za-z0-9_./-]{1,256}$")

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        let r = NSRange(location: 0, length: s.utf16.count)
        return re.firstMatch(in: s, range: r) != nil
    }

    // MARK: - iTerm

    private static func jumpITerm(hint: TerminalHint) -> Bool {
        guard (hint.termProgram ?? "").contains("iTerm"),
              let sid = hint.iTermSessionId, !sid.isEmpty else { return false }
        // $ITERM_SESSION_ID looks like "w0t0p0:UUID"; the tail after ':' is the UUID.
        let uuid = sid.split(separator: ":").last.map(String.init) ?? sid
        guard matches(uuidRegex, uuid) else {
            NSLog("[AgentPulse] rejected iTerm session id: \(sid)")
            return false
        }
        let script = """
        tell application "iTerm"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (unique id of s) is "\(uuid)" then
                            select w
                            select t
                            select s
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
        return runAppleScript(script)
    }

    // MARK: - tmux

    private static func jumpTmux(hint: TerminalHint) -> Bool {
        guard let pane = hint.tmuxPane, !pane.isEmpty,
              matches(tmuxTargetRegex, pane) else {
            if let p = hint.tmuxPane, !p.isEmpty {
                NSLog("[AgentPulse] rejected tmux pane: \(p)")
            }
            return false
        }

        var args = ["tmux", "switch-client", "-t", pane]
        if let socket = hint.tmuxSocket, !socket.isEmpty {
            if matches(tmuxSocketRegex, socket) {
                args = ["tmux", "-S", socket, "switch-client", "-t", pane]
            } else {
                NSLog("[AgentPulse] rejected tmux socket: \(socket)")
            }
        }

        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = args
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Generic app activation (Cursor / VS Code / Windsurf / Zed / etc.)

    /// Activate any GUI app the hook detected as the parent of the shell.
    /// We try matching by `__CFBundleIdentifier` first (most reliable),
    /// then by localized name.
    private static func activateGenericApp(hint: TerminalHint) -> Bool {
        if let bid = hint.bundleIdentifier, !bid.isEmpty,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
            app.activate(options: [.activateAllWindows])
            return true
        }
        if let host = hint.hostApp, !host.isEmpty {
            for app in NSWorkspace.shared.runningApplications {
                if app.localizedName == host {
                    app.activate(options: [.activateAllWindows])
                    return true
                }
            }
        }
        return false
    }

    private static func activateJetBrains(hint: TerminalHint) -> Bool {
        // Prefer the exact bundle id captured by the hook, so we activate
        // the *actual* IDE (GoLand vs IntelliJ vs PyCharm…) this session
        // came from, not whichever happens to be running first.
        if let bid = hint.bundleIdentifier,
           bid.lowercased().contains("jetbrains"),
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
            app.activate(options: [.activateAllWindows])
            return true
        }

        // Fallback: if the hint only told us "JetBrains" generically, sweep
        // the common IDE bundle ids and use the first one that's running.
        guard let emu = hint.terminalEmulator, emu.lowercased().contains("jetbrains") else { return false }
        let bundleIDs = [
            "com.jetbrains.goland",
            "com.jetbrains.intellij",
            "com.jetbrains.intellij.ce",
            "com.jetbrains.pycharm",
            "com.jetbrains.WebStorm",
            "com.jetbrains.rider"
        ]
        for bid in bundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
                app.activate(options: [.activateAllWindows])
                return true
            }
        }
        return false
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> Bool {
        var err: NSDictionary?
        if let s = NSAppleScript(source: source) {
            s.executeAndReturnError(&err)
            return err == nil
        }
        return false
    }
}
