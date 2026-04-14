import SwiftUI
import AppKit

/// Anthropic-flavored palette used when the session list is shown inside the
/// notch capsule. Keeps the popover (which uses native Liquid Glass) untouched.
///
/// Every entry uses a dynamic NSColor so the cream / warm-dark variant swaps
/// automatically with the system appearance.
enum ClaudeTheme {
    static let cream         = dyn(NSColor(red: 0.965, green: 0.945, blue: 0.890, alpha: 1.0),
                                    NSColor(red: 0.150, green: 0.130, blue: 0.110, alpha: 1.0))   // bg
    static let creamSubtle   = dyn(NSColor(red: 0.925, green: 0.900, blue: 0.840, alpha: 1.0),
                                    NSColor(red: 0.230, green: 0.205, blue: 0.180, alpha: 1.0))   // divider / hover
    static let card          = dyn(NSColor(red: 0.990, green: 0.975, blue: 0.935, alpha: 1.0),
                                    NSColor(red: 0.205, green: 0.180, blue: 0.155, alpha: 1.0))   // section card fill
    static let cardBorder    = dyn(NSColor(red: 0.895, green: 0.870, blue: 0.810, alpha: 1.0),
                                    NSColor(red: 0.285, green: 0.255, blue: 0.220, alpha: 1.0))   // section card edge
    static let ink           = dyn(NSColor(red: 0.165, green: 0.145, blue: 0.125, alpha: 1.0),
                                    NSColor(red: 0.965, green: 0.935, blue: 0.870, alpha: 1.0))   // primary text
    static let inkMuted      = dyn(NSColor(red: 0.420, green: 0.365, blue: 0.320, alpha: 1.0),
                                    NSColor(red: 0.760, green: 0.715, blue: 0.640, alpha: 1.0))   // secondary text
    static let inkFaint      = dyn(NSColor(red: 0.620, green: 0.575, blue: 0.530, alpha: 1.0),
                                    NSColor(red: 0.555, green: 0.510, blue: 0.450, alpha: 1.0))   // tertiary text
    static let coral         = dyn(NSColor(red: 0.835, green: 0.420, blue: 0.290, alpha: 1.0),
                                    NSColor(red: 0.910, green: 0.520, blue: 0.385, alpha: 1.0))   // accent
    static let waitingWash   = dyn(NSColor(red: 0.945, green: 0.700, blue: 0.560, alpha: 0.22),
                                    NSColor(red: 0.910, green: 0.520, blue: 0.385, alpha: 0.18))
    static let selectionWash = dyn(NSColor(red: 0.580, green: 0.500, blue: 0.430, alpha: 0.18),
                                    NSColor(red: 0.965, green: 0.935, blue: 0.870, alpha: 0.10))

    // Status palette — each tuned to read on its respective bg.
    static let statusWaiting  = coral
    static let statusRunning  = dyn(NSColor(red: 0.310, green: 0.510, blue: 0.640, alpha: 1.0),
                                    NSColor(red: 0.510, green: 0.690, blue: 0.825, alpha: 1.0))
    static let statusThinking = dyn(NSColor(red: 0.490, green: 0.380, blue: 0.620, alpha: 1.0),
                                    NSColor(red: 0.685, green: 0.580, blue: 0.815, alpha: 1.0))
    static let statusIdle     = dyn(NSColor(red: 0.420, green: 0.560, blue: 0.420, alpha: 1.0),
                                    NSColor(red: 0.560, green: 0.730, blue: 0.555, alpha: 1.0))

    private static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

struct MenuBarContent: View {
    @ObservedObject var store: SessionStore

    /// `true` when this view is embedded inside the notch / floating panel.
    /// Skips the popover chrome (fixed width, opaque background, keyboard
    /// focus) since DynamicNotchKit owns the surrounding window.
    var embedded: Bool = false

    @State private var now: Date = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @State private var selection: Int = 0
    @FocusState private var keyboardFocus: Bool

    private var sorted: [Session] {
        store.sessions.sorted(by: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if embedded {
                summaryHeader
                divider
            } else {
                header
                divider
            }
            if sorted.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(width: embedded ? 420 : 440)
        .padding(.vertical, embedded ? 8 : 6)
        .modifier(MenuBarChrome(embedded: embedded, focus: $keyboardFocus))
        .environment(\.embeddedInNotch, embedded)
        .onAppear {
            resetSelection()
            if !embedded { keyboardFocus = true }
        }
        .onChange(of: store.sessions.count) { _, _ in resetSelection() }
        .onReceive(timer) { now = $0 }
        .onKeyPress(.upArrow)   { move(-1); return .handled }
        .onKeyPress(.downArrow) { move( 1); return .handled }
        .onKeyPress(.return)    { confirm(); return .handled }
        .onKeyPress(.escape)    { dismiss(); return .handled }
    }

    @ViewBuilder
    private var divider: some View {
        if embedded {
            Rectangle()
                .fill(ClaudeTheme.creamSubtle)
                .frame(height: 1)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
        } else {
            Divider().padding(.horizontal, 8).padding(.bottom, 4)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 7) {
                if embedded {
                    Circle()
                        .fill(ClaudeTheme.coral)
                        .frame(width: 7, height: 7)
                }
                Text(L10n.appShortName)
                    .font(embedded
                          ? .system(.headline, design: .serif, weight: .semibold)
                          : .system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(embedded ? ClaudeTheme.ink : Color.primary)
            }
            Spacer()
            if store.waitingCount > 0 {
                HStack(spacing: 4) {
                    Circle()
                        .fill(embedded ? ClaudeTheme.coral : .orange)
                        .frame(width: 6, height: 6)
                    Text(L10n.waitingBadge(store.waitingCount))
                        .font(.system(.caption2, design: .rounded, weight: .medium))
                        .foregroundStyle(embedded ? ClaudeTheme.coral : Color.orange)
                }
            }
        }
        .padding(.horizontal, embedded ? 16 : 14)
        .padding(.vertical, 6)
    }

    /// Embedded capsule header: row of colored dots (one per session,
    /// sorted waiting-first) + inline count summary. Gives an at-a-glance
    /// read of "who's busy / who needs you" before the user reads any row.
    private var summaryHeader: some View {
        let total   = store.sessions.count
        let waiting = store.waitingCount

        return HStack(spacing: 6) {
            Text(sessionCountLabel(total))
                .font(.system(.callout, design: .rounded, weight: .medium))
                .foregroundStyle(ClaudeTheme.ink)
            if waiting > 0 {
                Text("·").foregroundStyle(ClaudeTheme.inkFaint)
                Text(L10n.waitingBadge(waiting))
                    .foregroundStyle(ClaudeTheme.coral)
                    .fontWeight(.medium)
            }
            Spacer()
        }
        .font(.system(.callout, design: .rounded))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func sessionCountLabel(_ n: Int) -> String {
        switch n {
        case 0:  return L10n.noSessions
        case 1:  return "1 session"
        default: return "\(n) sessions"
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(embedded ? ClaudeTheme.inkFaint : Color.secondary.opacity(0.7))
            Text(L10n.noSessions)
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(embedded ? ClaudeTheme.inkMuted : Color.secondary)
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
        // Buckets:
        //   1. Waiting on permission — pinned to the very top, since these
        //      are the rows the user might want to act on immediately
        //      (especially with the inline Allow/Deny buttons). Sorted by
        //      most recent updatedAt so the freshest prompt is always on
        //      top.
        //   2. Recently active (touched in the last hour) — sorted by
        //      startedAt DESC so new sessions land at the top and then
        //      stay put as they flip between thinking/running/idle.
        //   3. Quiet (>1h no event) — sorted by updatedAt descending so
        //      the most recently used among old sessions floats up.
        let aWaiting = a.status == .waiting
        let bWaiting = b.status == .waiting
        if aWaiting != bWaiting { return aWaiting }
        if aWaiting { return a.updatedAt > b.updatedAt }

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

/// Applies the popover-only chrome (opaque background, focusable wrapper).
/// When embedded in the notch we skip both — the panel provides its own
/// translucent background, and a non-activating panel can't take key focus
/// anyway.
private struct MenuBarChrome: ViewModifier {
    let embedded: Bool
    var focus: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if embedded {
            // DynamicNotchKit wraps our content with a `.popover` VisualEffectView
            // (which picks up the system accent color in dark mode → looks maroon)
            // plus a 15pt safe-area inset. Extend our cream past the safe area so
            // it covers the entire panel and the maroon material stops showing.
            content
                .background {
                    ClaudeTheme.cream.ignoresSafeArea()
                }
        } else {
            content
                .background(Color(.windowBackgroundColor).opacity(0.6))
                .focusable()
                .focused(focus)
                .focusEffectDisabled()
        }
    }
}

/// Environment flag so child rows can pick the Claude palette without
/// threading another bool through every initializer.
private struct EmbeddedInNotchKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var embeddedInNotch: Bool {
        get { self[EmbeddedInNotchKey.self] }
        set { self[EmbeddedInNotchKey.self] = newValue }
    }
}

// MARK: - Row

private struct SessionRow: View {
    let session: Session
    let age: String?
    let isSelected: Bool
    let onJump: () -> Void
    let onRemove: () -> Void

    @Environment(\.embeddedInNotch) private var embedded
    @State private var isHovered = false
    @State private var commandExpanded = false

    private var isWaitingCard: Bool {
        embedded && session.status == .waiting
    }

    var body: some View {
        Group {
            if isWaitingCard {
                waitingCard
            } else {
                standardRow
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isWaitingCard ? 10 : 7)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(perform: onJump)
        .onHover { isHovered = $0 }
        .opacity(embedded && session.status == .idle ? 0.62 : 1.0)
    }

    /// Non-waiting rows use a two-line info hierarchy:
    ///   Line 1: status dot + session name (prominent)    · source · age (dim, right)
    ///   Line 2: monospaced activity summary, indented under the name
    /// Idle rows have the whole row dimmed via the outer `.opacity` modifier.
    private var standardRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                StatusBadge(status: session.status)
                Text(session.displayName)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(embedded ? ClaudeTheme.ink : Color.primary)
                    .lineLimit(1)
                if let dir = dirBadgeText {
                    Text("·")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(embedded ? ClaudeTheme.inkFaint : Color.secondary.opacity(0.6))
                    Text(dir)
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(embedded ? ClaudeTheme.inkMuted : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                rightMeta
            }
            activityLine
        }
    }

    @ViewBuilder
    private var rightMeta: some View {
        if isHovered {
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(embedded ? ClaudeTheme.inkMuted : Color.secondary.opacity(0.6))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .help(L10n.removeFromList)
        } else if !sourceText.isEmpty {
            Text(sourceText)
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(embedded ? ClaudeTheme.inkFaint : Color.secondary.opacity(0.6))
                .lineLimit(1)
        }
    }

    /// Second line — the "what" of the row. Running sessions show the tool
    /// + one-line input; thinking shows a placeholder; idle stays quiet (no
    /// duplicate "idle" text since the dim row already says as much).
    @ViewBuilder
    private var activityLine: some View {
        let faint = embedded ? ClaudeTheme.inkFaint : Color.secondary.opacity(0.6)

        switch session.status {
        case .running:
            HStack(spacing: 6) {
                let parts = parsedActivity
                if let tool = parts.tool {
                    Text(tool)
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                        .foregroundStyle(embedded ? ClaudeTheme.ink : Color.primary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(embedded ? ClaudeTheme.creamSubtle : Color.gray.opacity(0.15))
                        )
                }
                if let detail = parts.detail {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(embedded ? ClaudeTheme.inkMuted : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let age {
                    Text("·").foregroundStyle(faint)
                    Text(age).foregroundStyle(faint)
                }
            }
            .font(.system(.caption2, design: .rounded))
            .padding(.leading, 24)
        case .thinking:
            HStack(spacing: 4) {
                Text("thinking…")
                if let age {
                    Text("·")
                    Text(age)
                }
            }
            .font(.system(.caption, design: .rounded))
            .foregroundStyle(faint)
            .padding(.leading, 24)
        case .idle:
            if let age {
                HStack(spacing: 4) {
                    Text(L10n.statusIdle)
                    Text("·")
                    Text(age)
                }
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(faint)
                .padding(.leading, 24)
            }
        case .waiting:
            EmptyView()
        }
    }

    /// Split an activity string like "Bash git push" into (tool, rest) so
    /// we can tag the tool name and render the rest as plain mono text.
    private var parsedActivity: (tool: String?, detail: String?) {
        guard let a = session.activity, !a.isEmpty else { return (nil, nil) }
        let parts = a.split(separator: " ", maxSplits: 1)
        if parts.count == 2 {
            return (String(parts[0]), String(parts[1]))
        }
        return (String(parts[0]), nil)
    }

    /// Waiting cards are restructured into three clear blocks so the user
    /// can scan: who is waiting, what they want, and how to respond.
    private var waitingCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                StatusBadge(status: .waiting)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayName)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.ink)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(L10n.statusWaiting)
                            .foregroundStyle(ClaudeTheme.coral)
                        if let age {
                            Text("·").foregroundStyle(ClaudeTheme.inkFaint)
                            Text(age).foregroundStyle(ClaudeTheme.inkFaint)
                        }
                    }
                    .font(.system(.caption2, design: .rounded))
                }
                Spacer(minLength: 6)
                if !sourceText.isEmpty {
                    Text(sourceText)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(ClaudeTheme.inkFaint)
                        .lineLimit(1)
                }
            }

            if let tool = session.pendingTool {
                askBlock(tool: tool)
            }
        }
    }

    private func askBlock(tool: PendingTool) -> some View {
        let firstLine = firstStatement(of: tool.summary)
        let hasMore   = firstLine != tool.summary

        return HStack(alignment: .top, spacing: 8) {
            Text(tool.name)
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(ClaudeTheme.ink)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(ClaudeTheme.cream)
                )

            if !tool.summary.isEmpty {
                Text(commandExpanded ? tool.summary : firstLine)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(ClaudeTheme.inkMuted)
                    .lineLimit(commandExpanded ? nil : 1)
                    .truncationMode(.tail)
                    .help(tool.summary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if hasMore {
                Button { commandExpanded.toggle() } label: {
                    Image(systemName: commandExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.inkMuted)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .help(commandExpanded ? "Collapse" : "Show full command")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.45))
        )
        .padding(.leading, 24)
    }

    /// Pick the first shell statement so a long Bash command shows the
    /// meaningful prefix (`git push origin main`) instead of being middle-
    /// truncated through the body.
    ///
    /// Splits on `; && || |` and newlines. A single `&` is *not* a split
    /// because shell redirects (`2>&1`, `>&2`) embed it inside an
    /// otherwise-single statement.
    private func firstStatement(of command: String) -> String {
        let chars = Array(command)
        var i = 0
        var inSingle = false
        var inDouble = false

        func cut(at n: Int) -> String {
            let trimmed = String(chars[..<n]).trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? command : trimmed
        }

        while i < chars.count {
            let c = chars[i]
            if !inSingle && c == "\"" { inDouble.toggle() }
            else if !inDouble && c == "'" { inSingle.toggle() }
            else if !inSingle && !inDouble {
                if c == ";" || c == "\n" { return cut(at: i) }
                if c == "&" && i + 1 < chars.count && chars[i + 1] == "&" { return cut(at: i) }
                if c == "|" {
                    // `||` (or-list) and `|` (pipe) both terminate the
                    // first statement for our display purposes.
                    return cut(at: i)
                }
            }
            i += 1
        }
        return command
    }

    private var rowBackground: some View {
        ZStack {
            if session.status == .waiting {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(embedded ? ClaudeTheme.waitingWash : Color.orange.opacity(0.10))
            }
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(embedded ? ClaudeTheme.selectionWash : Color.gray.opacity(0.18))
            }
            if isHovered && !isSelected && session.status != .waiting {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(embedded ? ClaudeTheme.creamSubtle.opacity(0.55) : Color.clear)
            }
        }
    }

    /// Directory name to show alongside the custom title, or nil when
    /// the display name IS the directory name (don't repeat it).
    private var dirBadgeText: String? {
        guard let title = session.customTitle, !title.isEmpty else { return nil }
        let dir = URL(fileURLWithPath: session.cwd).lastPathComponent
        return dir == title ? nil : dir
    }

    private var sourceText: String {
        // Show the terminal / IDE only. The agent ("Claude Code") is
        // redundant in single-agent setups and eats row width. If we
        // ever lose the terminal hint, fall back to the agent name so
        // the user still sees *something*.
        if let t = session.terminal, let term = terminalLabel(for: t) {
            return term
        }
        if let agent = session.agent, !agent.isEmpty {
            return L10n.agentDisplayName(agent)
        }
        return ""
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
    @Environment(\.embeddedInNotch) private var embedded

    var body: some View {
        ZStack {
            if status == .waiting {
                Circle()
                    .fill(color.opacity(0.25))
                    .frame(width: 14, height: 14)
            }
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
        }
        .frame(width: 14, height: 14)   // outer slot for visual alignment
    }

    private var color: Color {
        if embedded {
            switch status {
            case .waiting:  return ClaudeTheme.statusWaiting
            case .running:  return ClaudeTheme.statusRunning
            case .thinking: return ClaudeTheme.statusThinking
            case .idle:     return ClaudeTheme.statusIdle
            }
        }
        // Popover (non-embedded) uses the original muted system-friendly palette.
        switch status {
        case .waiting:  return Color(red: 0.95, green: 0.55, blue: 0.18)
        case .running:  return Color(red: 0.30, green: 0.62, blue: 0.95)
        case .thinking: return Color(red: 0.62, green: 0.48, blue: 0.92)
        case .idle:     return Color(red: 0.35, green: 0.72, blue: 0.50)
        }
    }
}
