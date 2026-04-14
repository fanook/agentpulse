import SwiftUI
import AppKit
import Combine
import DynamicNotchKit

/// Drives the Dynamic-Island-style notch UI on top of `SessionStore`.
///
/// State machine:
/// - 0 sessions → notch hidden
/// - ≥1 sessions → notch visible in `compact` mode (color dot + label)
/// - new `waiting` session appears → auto-expand for 5s, then back to compact
/// - hover on compact → expand; leave → compact (debounced)
/// - tap expanded → jump to the primary waiting session (or any primary)
@MainActor
final class NotchPresenter {
    private let store: SessionStore
    private let viewModel = NotchViewModel()

    private var notch: DynamicNotch<NotchExpandedView, NotchCompactLeadingView, NotchCompactTrailingView>?
    private var storeObserver: AnyCancellable?
    private var hoverObserver: AnyCancellable?
    private var lastSnapshot = NotchSnapshot.empty
    private var revertTask: Task<Void, Never>?

    private var prefsObserver: AnyCancellable?

    init(store: SessionStore) {
        self.store = store
        viewModel.store = store
        viewModel.onJump = { [weak self] sessionId in
            guard let session = self?.store.sessions.first(where: { $0.id == sessionId }) else { return }
            Jumper.jump(to: session)
        }
        storeObserver = store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        // Re-evaluate when the user flips "Show session capsule" in prefs.
        prefsObserver = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        refresh()
    }

    /// Manual summon (e.g. menu-bar icon click). Toggles a sticky expanded
    /// state with the full session list.
    func toggle() {
        if viewModel.summoned {
            dismiss()
        } else {
            summon()
        }
    }

    func summon(on screen: NotchScreen = .sessions) {
        viewModel.screen = screen
        viewModel.summoned = true
        revertTask?.cancel()
        ensureNotch()
        guard let notch else { return }
        Task { await notch.expand() }
    }

    func dismiss() {
        guard viewModel.summoned else { return }
        viewModel.summoned = false
        viewModel.screen = .sessions
        revertTask?.cancel()
        // Manual dismiss always collapses the capsule even if a waiting
        // session is still pending — the user has explicitly acknowledged
        // it. A brand-new waiting event will pop it back up (refresh()
        // compares against lastSnapshot to detect that).
        if hasNotch {
            let snap = lastSnapshot
            if snap.items.isEmpty { teardownNotch() }
            else { Task { await notch?.compact() } }
        } else {
            teardownNotch()
        }
    }

    var isSummoned: Bool { viewModel.summoned }

    private func ensureNotch() {
        guard notch == nil else { return }
        let vm = viewModel
        let n = DynamicNotch(
            hoverBehavior: [.keepVisible, .increaseShadow],
            style: .auto,
            expanded:        { NotchExpandedView(viewModel: vm) },
            compactLeading:  { NotchCompactLeadingView(viewModel: vm) },
            compactTrailing: { NotchCompactTrailingView(viewModel: vm) }
        )
        notch = n
        // Hover-to-expand only on notched displays. On floating displays
        // `compact()` is documented to *hide* the panel, so reacting to
        // hover-out would dismiss the very capsule the user is trying to read.
        guard hasNotch else { return }
        hoverObserver = n.$isHovering
            .removeDuplicates()
            .sink { [weak self] hovering in
                guard let self else { return }
                if hovering {
                    self.revertTask?.cancel()
                    Task { await n.expand() }
                } else {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        if !n.isHovering && !self.viewModel.summoned { await n.compact() }
                    }
                }
            }
    }

    private func teardownNotch() {
        revertTask?.cancel()
        hoverObserver = nil
        let dying = notch
        notch = nil
        Task { await dying?.hide() }
    }

    /// True when at least one screen has a notch (MBP 14"/16" 2021+, MBA M2+).
    /// On non-notch displays DynamicNotchKit auto-falls-back to floating style,
    /// where `compact()` is documented to *hide* the window — so the UX has to
    /// branch.
    private var hasNotch: Bool {
        NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
    }

    private func refresh() {
        let snap = NotchSnapshot.from(store.sessions)
        let prev = lastSnapshot
        guard snap != prev else { return }
        lastSnapshot = snap
        viewModel.snapshot = snap

        let prevWaitingIds = Set(prev.waiting.map(\.id))
        let newWaiting = snap.waiting.first(where: { !prevWaitingIds.contains($0.id) }) != nil
        let autoPop   = UserDefaults.boolWithDefault(PrefKey.autoPopOnWaiting)
        let shouldAutoPop = newWaiting && autoPop

        if hasNotch {
            refreshNotchedDisplay(snap: snap, prev: prev, newWaiting: shouldAutoPop)
        } else {
            refreshFloatingDisplay(snap: snap, newWaiting: shouldAutoPop)
        }
    }

    /// Notched MacBook: keep a compact pill at the notch whenever there is any
    /// session, expand on hover or on a new waiting event.
    private func refreshNotchedDisplay(snap: NotchSnapshot, prev: NotchSnapshot, newWaiting: Bool) {
        if snap.items.isEmpty && !viewModel.summoned {
            teardownNotch()
            return
        }

        ensureNotch()
        guard let notch else { return }

        if viewModel.summoned {
            // Sticky summoned state — stay expanded.
            Task { await notch.expand() }
            return
        }

        if prev.items.isEmpty {
            Task { await notch.compact() }
        }

        if newWaiting {
            revertTask?.cancel()
            revertTask = Task {
                await notch.expand()
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                if !notch.isHovering && !self.viewModel.summoned { await notch.compact() }
            }
        }
    }

    /// No notch: floating banner — show only on explicit summon or a
    /// *freshly triggered* waiting event. Persistent waiting state does
    /// not keep it on-screen, so clicking outside always dismisses cleanly.
    private func refreshFloatingDisplay(snap: NotchSnapshot, newWaiting: Bool) {
        let shouldShow = viewModel.summoned || newWaiting

        if !shouldShow {
            if !viewModel.summoned { teardownNotch() }
            return
        }

        ensureNotch()
        guard let notch else { return }

        Task { await notch.expand() }

        // Auto-pop from a new waiting event collapses on a timer unless the
        // user manually pinned it open by clicking AP.
        if newWaiting && !viewModel.summoned {
            revertTask?.cancel()
            revertTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self,
                      !self.viewModel.summoned
                else { return }
                self.teardownNotch()
            }
        }
    }
}

// MARK: - View model

enum NotchScreen: Equatable {
    case sessions
    case preferences
    case about
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var snapshot: NotchSnapshot = .empty
    @Published var summoned: Bool = false
    @Published var screen: NotchScreen = .sessions
    weak var store: SessionStore?
    var onJump: ((String) -> Void)?
}

// MARK: - Snapshot

struct NotchSnapshot: Equatable {
    struct Item: Equatable, Identifiable {
        let id: String
        let displayName: String
        let cwd: String
        let agent: String?
        let status: SessionStatus
        let activity: String?
    }

    var items: [Item]

    static let empty = NotchSnapshot(items: [])

    static func from(_ sessions: [Session]) -> NotchSnapshot {
        NotchSnapshot(items: sessions.map { s in
            Item(id: s.id,
                 displayName: s.displayName,
                 cwd: s.cwd,
                 agent: s.agent,
                 status: s.status,
                 activity: s.activity)
        })
    }

    var waiting:  [Item] { items.filter { $0.status == .waiting  } }
    var running:  [Item] { items.filter { $0.status == .running  } }
    var thinking: [Item] { items.filter { $0.status == .thinking } }

    var dominantStatus: SessionStatus {
        if !waiting.isEmpty  { return .waiting }
        if !running.isEmpty  { return .running }
        if !thinking.isEmpty { return .thinking }
        return .idle
    }

    /// The session we'd want to jump to or describe in the expanded view.
    var primary: Item? {
        waiting.first ?? running.first ?? thinking.first ?? items.first
    }
}

extension SessionStatus {
    var notchColor: Color {
        switch self {
        case .waiting:  return .orange
        case .running:  return .blue
        case .thinking: return .purple
        case .idle:     return .green
        }
    }
}

// MARK: - Compact: leading (status dot)

struct NotchCompactLeadingView: View {
    @ObservedObject var viewModel: NotchViewModel

    @State private var pulse = false

    var body: some View {
        let status = viewModel.snapshot.dominantStatus
        let color = status.notchColor

        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: 16, height: 16)
                .scaleEffect(pulse && status == .waiting ? 1.4 : 1.0)
                .opacity(pulse && status == .waiting ? 0.0 : 1.0)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .frame(width: 22, height: 22)
        .padding(.leading, 6)
        .onAppear { startPulseIfNeeded(status: status) }
        .onChange(of: status) { _, newStatus in startPulseIfNeeded(status: newStatus) }
        .animation(.easeOut(duration: 1.0).repeatForever(autoreverses: false), value: pulse)
    }

    private func startPulseIfNeeded(status: SessionStatus) {
        pulse = false
        if status == .waiting {
            DispatchQueue.main.async { pulse = true }
        }
    }
}

// MARK: - Compact: trailing (label + count)

struct NotchCompactTrailingView: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        let snap = viewModel.snapshot
        let waitCount = snap.waiting.count

        HStack(spacing: 6) {
            if waitCount > 0 {
                Text(L10n.notchNeedsYou)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                if waitCount > 1 {
                    Text("\(waitCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange))
                }
            } else if let primary = snap.primary {
                Text(compactLabel(for: primary))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 140)
            }
        }
        .padding(.trailing, 8)
    }

    private func compactLabel(for item: NotchSnapshot.Item) -> String {
        if let act = item.activity, !act.isEmpty { return act }
        return item.displayName
    }
}

// MARK: - Expanded view

struct NotchExpandedView: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        Group {
            switch viewModel.screen {
            case .sessions:
                if let store = viewModel.store {
                    MenuBarContent(store: store, embedded: true)
                }
            case .preferences:
                PreferencesView(embedded: true) {
                    viewModel.screen = .sessions
                }
            case .about:
                AboutView(embedded: true) {
                    viewModel.screen = .sessions
                }
            }
        }
    }
}
