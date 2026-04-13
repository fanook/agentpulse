import SwiftUI
import AppKit

struct MenuBarContent: View {
    @ObservedObject var store: SessionStore

    @State private var now: Date = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @State private var selection: Int = 0
    @FocusState private var keyboardFocus: Bool

    private var sorted: [Session] {
        store.sessions.sorted(by: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 8).padding(.bottom, 4)
            if sorted.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(width: 440)
        .padding(.vertical, 6)
        // Translucent system color over the popover's native Liquid Glass.
        // 0.6 alpha = mostly opaque (consistent color across apps) with a
        // hint of the glass material still showing through behind it.
        .background(Color(.windowBackgroundColor).opacity(0.6))
        .focusable()
        .focused($keyboardFocus)
        .focusEffectDisabled()
        .onAppear {
            resetSelection()
            keyboardFocus = true
        }
        .onChange(of: store.sessions.count) { _, _ in resetSelection() }
        .onReceive(timer) { now = $0 }
        .onKeyPress(.upArrow)   { move(-1); return .handled }
        .onKeyPress(.downArrow) { move( 1); return .handled }
        .onKeyPress(.return)    { confirm(); return .handled }
        .onKeyPress(.escape)    { dismiss(); return .handled }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.appShortName)
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            if store.waitingCount > 0 {
                HStack(spacing: 4) {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                    Text(L10n.waitingBadge(store.waitingCount))
                        .font(.system(.caption2, design: .rounded, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(L10n.noSessions)
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 1) {
            ForEach(Array(sorted.enumerated()), id: \.element.id) { idx, session in
                SessionRow(session: session,
                           age: ageText(session),
                           isSelected: idx == selection,
                           onJump: { Jumper.jump(to: session) },
                           onRemove: { store.remove(id: session.id) })
                    .onHover { inside in if inside { selection = idx } }
                    .contextMenu {
                        Button(L10n.jumpToTerminal) { Jumper.jump(to: session) }
                        Button(L10n.revealInFinder) { Jumper.revealInFinder(session) }
                        Divider()
                        Button(L10n.removeFromList) { store.remove(id: session.id) }
                    }
            }
        }
        .padding(.horizontal, 6)
    }

    // MARK: - Keyboard

    private func move(_ delta: Int) {
        guard !sorted.isEmpty else { return }
        let n = sorted.count
        selection = (selection + delta + n) % n
    }

    private func confirm() {
        guard sorted.indices.contains(selection) else { return }
        Jumper.jump(to: sorted[selection])
    }

    private func dismiss() {
        NSApp.keyWindow?.resignKey()
    }

    private func resetSelection() {
        if let i = sorted.firstIndex(where: { $0.status == .waiting }) {
            selection = i
        } else {
            selection = 0
        }
    }

    // MARK: - Sort / format

    private func sortOrder(_ a: Session, _ b: Session) -> Bool {
        // Two buckets:
        //   1. Recently active (anything touched in the last hour) —
        //      sorted stably by startedAt DESC so new sessions land at
        //      the top of the list and then stay put as they flip between
        //      thinking/running/idle. The orange dot + notification
        //      banner + menu-bar count already signal urgency.
        //   2. Quiet (>1h no event) — sorted by updatedAt descending so
        //      the most recently used one among old sessions floats up.
        let cutoff = Date().addingTimeInterval(-3600)
        let aActive = a.updatedAt >= cutoff
        let bActive = b.updatedAt >= cutoff

        if aActive != bActive { return aActive }
        if aActive { return a.startedAt > b.startedAt }
        return a.updatedAt > b.updatedAt
    }

    private func ageText(_ s: Session) -> String? {
        let secs = Int(now.timeIntervalSince(s.updatedAt))
        if secs < 1 { return nil }
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        return "\(secs / 3600)h"
    }
}

// MARK: - Row

private struct SessionRow: View {
    let session: Session
    let age: String?
    let isSelected: Bool
    let onJump: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            StatusBadge(status: session.status)
            VStack(alignment: .leading, spacing: 1) {
                // Finder-style: name · dir (only when they differ).
                HStack(spacing: 5) {
                    Text(session.displayName)
                        .font(.system(.body, design: .rounded, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let dir = dirBadgeText {
                        Text("·").foregroundStyle(.tertiary)
                        Text(dir)
                            .font(.system(.callout, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 4) {
                    Text(statusLine)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                    if let age {
                        Text("·").foregroundStyle(.tertiary)
                        Text(age).foregroundStyle(.tertiary)
                    }
                }
                .font(.system(.caption2, design: .rounded))
            }
            Spacer(minLength: 4)
            // Source text on the right; swap for a close button on hover.
            ZStack(alignment: .trailing) {
                Text(sourceText)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 0 : 1)
                if isHovered {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.tertiary)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.removeFromList)
                }
            }
            .frame(minWidth: 60, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(perform: onJump)
        .onHover { isHovered = $0 }
    }

    private var rowBackground: some View {
        // Waiting rows get a soft orange wash so they read as
        // "needs attention" without any motion. Selection is a neutral
        // gray that composes on top.
        ZStack {
            if session.status == .waiting {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.10))
            }
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.gray.opacity(0.18))
            }
        }
    }

    private var statusColor: Color {
        session.status == .waiting ? .orange : .secondary
    }

    /// Directory name to show alongside the custom title, or nil when
    /// the display name IS the directory name (don't repeat it).
    private var dirBadgeText: String? {
        guard let title = session.customTitle, !title.isEmpty else { return nil }
        let dir = URL(fileURLWithPath: session.cwd).lastPathComponent
        return dir == title ? nil : dir
    }

    private var statusLine: String {
        switch session.status {
        case .waiting:  return L10n.statusWaiting
        case .thinking: return L10n.statusThinking
        case .running:
            if let a = session.activity, !a.isEmpty { return a }
            return L10n.statusRunning
        case .idle:     return L10n.statusIdle
        }
    }

    private var sourceText: String {
        var parts: [String] = []
        if let agent = session.agent, !agent.isEmpty {
            parts.append(L10n.agentDisplayName(agent))
        }
        if let t = session.terminal, let term = terminalLabel(for: t) {
            parts.append(term)
        }
        return parts.joined(separator: " · ")
    }

    /// Resolve a friendly terminal/IDE name from the various hints we
    /// collect. Priority: hostApp (process tree, most reliable) →
    /// JetBrains bundle id → JetBrains generic → TERM_PROGRAM cleanup.
    private func terminalLabel(for t: TerminalHint) -> String? {
        if let app = t.hostApp, !app.isEmpty { return app }
        if let name = friendlyJetBrainsName(t.bundleIdentifier) { return name }
        if let emu = t.terminalEmulator, emu.lowercased().contains("jetbrains") {
            return "JetBrains"
        }
        guard let p = t.termProgram, !p.isEmpty else { return nil }
        if p.contains("iTerm")          { return "iTerm" }
        if p.contains("Apple_Terminal") { return "Terminal" }
        if p == "vscode"                { return "VS Code" }   // best-guess fallback
        return p
    }

    /// Map a JetBrains bundle id to its marketing name, e.g.
    /// `com.jetbrains.goland` → "GoLand".
    private func friendlyJetBrainsName(_ bid: String?) -> String? {
        guard let b = bid?.lowercased(), b.contains("jetbrains") else { return nil }
        if b.contains("goland")       { return "GoLand" }
        if b.contains("intellij")     { return "IntelliJ" }
        if b.contains("pycharm")      { return "PyCharm" }
        if b.contains("webstorm")     { return "WebStorm" }
        if b.contains("rider")        { return "Rider" }
        if b.contains("clion")        { return "CLion" }
        if b.contains("rubymine")     { return "RubyMine" }
        if b.contains("phpstorm")     { return "PhpStorm" }
        if b.contains("datagrip")     { return "DataGrip" }
        if b.contains("appcode")      { return "AppCode" }
        if b.contains("rustrover")    { return "RustRover" }
        return "JetBrains"
    }
}

// MARK: - Status badge

private struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .frame(width: 14, height: 14)   // outer slot for visual alignment
    }

    private var color: Color {
        // Slightly muted shades — easier on the eyes than the system
        // saturated defaults, and they read cleanly against both light
        // and dark materials.
        switch status {
        case .waiting:  return Color(red: 0.95, green: 0.55, blue: 0.18)   // amber
        case .running:  return Color(red: 0.30, green: 0.62, blue: 0.95)   // steel blue
        case .thinking: return Color(red: 0.62, green: 0.48, blue: 0.92)   // soft violet
        case .idle:     return Color(red: 0.35, green: 0.72, blue: 0.50)   // sage
        }
    }
}
