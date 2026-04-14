import SwiftUI
import AppKit
import ServiceManagement

/// Centralized keys so AppDelegate / NotchPresenter can read the same
/// defaults the preferences pane writes.
enum PrefKey {
    static let autoPopOnWaiting = "pref.autoPopOnWaiting"
}

extension UserDefaults {
    /// `true` when nothing has been written — keeps new features opt-out
    /// rather than surprising existing users with silent off-by-default.
    static func boolWithDefault(_ key: String, default defaultValue: Bool = true) -> Bool {
        if standard.object(forKey: key) == nil { return defaultValue }
        return standard.bool(forKey: key)
    }
}

// MARK: - Settings

/// Claude-themed settings rendered inside the notch capsule.
struct PreferencesView: View {
    var embedded: Bool = true
    var onBack: (() -> Void)? = nil

    @State private var launchAtLogin: Bool = false
    @AppStorage(PrefKey.autoPopOnWaiting) private var autoPop: Bool = true
    @State private var hookStatus: HookInstaller.Status = .notInstalled
    @State private var hookError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(title: "Settings", onBack: onBack)
            Rectangle()
                .fill(ClaudeTheme.creamSubtle)
                .frame(height: 1)
                .padding(.horizontal, 12)
                .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 14) {
                SectionCard(title: "Claude Code") {
                    hookRow
                }

                SectionCard(title: "General") {
                    PrefRow(title: "Launch at login",
                            subtitle: nil,
                            trailing: Toggle("", isOn: $launchAtLogin)
                                .labelsHidden()
                                .onChange(of: launchAtLogin) { _, new in applyLaunchAtLogin(new) })
                    CardDivider()
                    PrefRow(title: "Auto-open capsule when waiting",
                            subtitle: "Pop the expanded view for 5 s on a new permission prompt.",
                            trailing: Toggle("", isOn: $autoPop).labelsHidden())
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
        .frame(width: 420)
        .padding(.vertical, 8)
        .background { ClaudeTheme.cream.ignoresSafeArea() }
        .onAppear {
            refreshLaunchAtLogin()
            refreshHookStatus()
        }
    }

    // MARK: - Claude Code integration row

    @ViewBuilder
    private var hookRow: some View {
        PrefRow(
            title: hookRowTitle,
            subtitle: hookRowSubtitle,
            trailing: hookRowTrailing
        )
        if let err = hookError {
            Text(err)
                .font(.caption2)
                .foregroundStyle(ClaudeTheme.coral)
                .padding(.top, 2)
        }
    }

    private var hookRowTitle: String {
        switch hookStatus {
        case .installed:       return "Integration connected"
        case .needsRelink:     return "Integration needs reconnect"
        case .notInstalled:    return "Connect to Claude Code"
        case .noReportScript:  return "Integration unavailable"
        }
    }

    private var hookRowSubtitle: String? {
        switch hookStatus {
        case .installed:
            return "AgentPulse is listening to every Claude Code session on this Mac."
        case .needsRelink:
            return "Hook entries point to an older copy of AgentPulse. Reconnect to fix."
        case .notInstalled:
            return "Wires this app into ~/.claude/settings.json so sessions show up here."
        case .noReportScript:
            return "This build wasn't bundled as a .app. Install via the DMG or install.sh."
        }
    }

    @ViewBuilder
    private var hookRowTrailing: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(hookStatusDot)
                .frame(width: 7, height: 7)
            Group {
                if hookStatus == .installed {
                    // Disconnect is a "put down" action — don't make it
                    // look urgent. Neutral bordered button for parity with
                    // the dim green "connected" dot beside it.
                    Button(hookActionLabel) { runHookAction() }
                        .buttonStyle(.bordered)
                        .tint(.gray)
                } else {
                    // Connect / Reconnect are the primary nudge for a
                    // first-time user — keep them on-brand coral.
                    Button(hookActionLabel) { runHookAction() }
                        .buttonStyle(.borderedProminent)
                        .tint(ClaudeTheme.coral)
                }
            }
            .controlSize(.small)
            .disabled(hookStatus == .noReportScript)
        }
    }

    private var hookStatusDot: Color {
        switch hookStatus {
        case .installed:      return ClaudeTheme.statusIdle      // sage green
        case .needsRelink:    return ClaudeTheme.statusWaiting   // coral
        case .notInstalled,
             .noReportScript: return ClaudeTheme.inkFaint
        }
    }

    private var hookActionLabel: String {
        switch hookStatus {
        case .installed:       return "Disconnect"
        case .needsRelink:     return "Reconnect"
        case .notInstalled:    return "Connect"
        case .noReportScript:  return "Connect"
        }
    }

    private func runHookAction() {
        hookError = nil
        do {
            switch hookStatus {
            case .installed:        try HookInstaller.uninstall()
            case .needsRelink,
                 .notInstalled:     try HookInstaller.install()
            case .noReportScript:   return
            }
            refreshHookStatus()
        } catch {
            hookError = error.localizedDescription
        }
    }

    private func refreshHookStatus() {
        hookStatus = HookInstaller.currentStatus()
    }

    // MARK: - Launch at login

    private func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else       { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("[AgentPulse] launch-at-login toggle failed: \(error)")
            DispatchQueue.main.async { refreshLaunchAtLogin() }
        }
    }
}

// MARK: - About

struct AboutView: View {
    var embedded: Bool = true
    var onBack: (() -> Void)? = nil

    private static let repoURL = URL(string: "https://github.com/fanook/agentpulse")!
    private static let docsURL = URL(string: "https://github.com/fanook/agentpulse/blob/main/README.md")!

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(title: "About", onBack: onBack)
            Rectangle()
                .fill(ClaudeTheme.creamSubtle)
                .frame(height: 1)
                .padding(.horizontal, 12)
                .padding(.bottom, 14)

            VStack(spacing: 14) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 72, height: 72)
                }
                VStack(spacing: 2) {
                    Text(L10n.appShortName)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.ink)
                    Text("Version \(version) · MIT License")
                        .font(.caption)
                        .foregroundStyle(ClaudeTheme.inkMuted)
                }
                Text("Menu-bar companion for coding agents. Zero telemetry, everything stays local.")
                    .font(.callout)
                    .foregroundStyle(ClaudeTheme.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)

                HStack(spacing: 8) {
                    LinkChip(label: "GitHub", symbol: "link",  url: Self.repoURL)
                    LinkChip(label: "README", symbol: "book",  url: Self.docsURL)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
        .frame(width: 420)
        .padding(.vertical, 8)
        .background { ClaudeTheme.cream.ignoresSafeArea() }
    }
}

// MARK: - Shared pieces

/// Centered title with a left-aligned back button. Used by both the
/// Settings and About screens so the transitions feel like one surface.
private struct ScreenHeader: View {
    let title: String
    var onBack: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if let onBack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Sessions")
                            .font(.system(.callout, design: .rounded, weight: .medium))
                    }
                    .foregroundStyle(ClaudeTheme.inkMuted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text(title)
                .font(.system(.headline, design: .serif, weight: .semibold))
                .foregroundStyle(ClaudeTheme.ink)
            Spacer()
            // Symmetry spacer so title stays centered even with back button.
            Color.clear.frame(width: 70, height: 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ClaudeTheme.inkFaint)
                .tracking(0.8)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ClaudeTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(ClaudeTheme.cardBorder, lineWidth: 0.5)
            )
        }
    }
}

private struct CardDivider: View {
    var body: some View {
        Rectangle()
            .fill(ClaudeTheme.cardBorder.opacity(0.55))
            .frame(height: 0.5)
    }
}

private struct PrefRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .foregroundStyle(ClaudeTheme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(ClaudeTheme.inkMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
                .tint(ClaudeTheme.coral)
        }
    }
}

private struct LinkChip: View {
    let label: String
    let symbol: String
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(.system(.caption, design: .rounded, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(ClaudeTheme.ink)
            .background(
                Capsule().fill(ClaudeTheme.creamSubtle.opacity(0.7))
            )
            .overlay(
                Capsule().strokeBorder(ClaudeTheme.creamSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
