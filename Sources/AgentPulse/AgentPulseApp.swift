import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, UNUserNotificationCenterDelegate {
    let store = SessionStore()
    private var server: HTTPServer?
    private var lastNotified: [String: Date] = [:]
    private let notifyCooldown: TimeInterval = 60

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var storeObserver: AnyCancellable?
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if Bundle.main.bundleIdentifier != nil {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        setupStatusItem()
        startServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Runtime.clearPortFile()
    }

    // MARK: - Menu bar item + popover

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshIcon()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 440, height: 320)
        // `.applicationDefined` keeps the popover open when focus jumps to
        // iTerm / JetBrains after clicking a row, so users can keep
        // arrow-key / click-hopping between sessions. We close it manually
        // on Esc, outside click, or a second tap of the menu bar icon.
        popover.behavior = .applicationDefined
        popover.animates = true

        // NSPopover windows are inactive-by-default; without acceptsFirstMouse
        // the OS eats the first click as an "activation" tap and users have
        // to click twice to hit a row. Wrap the SwiftUI view in a host that
        // claims first mouse, so every click is a real click.
        let hosting = FirstMouseHostingView(rootView: MenuBarContent(store: store))
        let vc = NSViewController()
        vc.view = hosting
        popover.contentViewController = vc

        // Re-render icon whenever session state changes.
        storeObserver = store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
    }

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        // "AP" wordmark as a template image — picks up the system tint so
        // it adapts to light/dark menu bars. Append an orange count when
        // any session is waiting; otherwise just the mark.
        button.image = Self.menuBarMark()
        button.imagePosition = .imageLeft

        let waiting = store.waitingCount
        if waiting > 0 {
            button.attributedTitle = NSAttributedString(
                string: " \(waiting)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.labelColor
                ]
            )
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    /// Render "AP" once as a small monochrome template image —
    /// a rounded-rectangle outline with the wordmark inside.
    private static let _menuBarMark: NSImage = {
        let text = "AP" as NSString
        var font = NSFont.systemFont(ofSize: 9, weight: .heavy)
        if let descriptor = font.fontDescriptor.withDesign(.rounded),
           let rounded = NSFont(descriptor: descriptor, size: 0) {
            font = rounded
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .kern: -0.4
        ]

        let textSize = text.size(withAttributes: attrs)
        let padX: CGFloat = 3
        let padY: CGFloat = 1.5
        let canvas = NSSize(
            width: ceil(textSize.width + padX * 2),
            height: ceil(textSize.height + padY * 2)
        )

        let image = NSImage(size: canvas)
        image.lockFocus()
        let ctx = NSGraphicsContext.current!.cgContext

        // Solid rounded-rect "tile". Drawn in black so the system can
        // tint it with the menu bar's foreground color when template.
        let frame = NSRect(origin: .zero, size: canvas)
        let radius: CGFloat = 3.0
        let tilePath = CGPath(roundedRect: frame,
                              cornerWidth: radius, cornerHeight: radius,
                              transform: nil)
        ctx.addPath(tilePath)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()

        // Knock out "AP" so the menu bar background shows through the
        // letters, like a stamp.
        let drawOrigin = NSPoint(
            x: (canvas.width - textSize.width) / 2,
            y: (canvas.height - textSize.height) / 2
        )
        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        text.draw(at: drawOrigin, withAttributes: attrs)
        ctx.restoreGState()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }()
    private static func menuBarMark() -> NSImage { _menuBarMark }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { togglePopover(); return }
        switch event.type {
        case .rightMouseUp:
            showContextMenu()
        default:
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // Activate the app (even though it's .accessory) so the popover
        // window is already key when it appears. Without this, macOS
        // swallows the first click as an "activation" tap and users have
        // to click twice to actually hit a row.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    private func closePopover() {
        if popover.isShown { popover.performClose(nil) }
        if let mon = eventMonitor {
            NSEvent.removeMonitor(mon)
            eventMonitor = nil
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let quit = NSMenuItem(title: L10n.quit, action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Server

    private func startServer() {
        let token = Runtime.loadOrCreateToken()
        let server = HTTPServer(port: Runtime.preferredPort, token: token) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }
        do {
            let actual = try server.start(preferredPort: Runtime.preferredPort,
                                          maxTries: Runtime.maxPortTries)
            Runtime.writePortFile(actual)
            self.server = server
        } catch {
            NSLog("[AgentPulse] failed to start HTTP: \(error)")
        }
    }

    private func handle(_ event: HookEvent) {
        let before = store.sessions.first(where: { $0.id == event.sessionId })?.status
        store.apply(event)
        let after = store.sessions.first(where: { $0.id == event.sessionId })?.status

        if after == .waiting && before != .waiting {
            let now = Date()
            if let last = lastNotified[event.sessionId],
               now.timeIntervalSince(last) < notifyCooldown {
                return
            }
            lastNotified[event.sessionId] = now
            if let session = store.sessions.first(where: { $0.id == event.sessionId }) {
                Notifier.notifyWaiting(session: session)
            }
        }

        if after != .waiting {
            lastNotified[event.sessionId] = nil
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            defer { completionHandler() }
            guard let sid = userInfo["sessionId"] as? String,
                  let session = self.store.sessions.first(where: { $0.id == sid }) else { return }
            Jumper.jump(to: session)
        }
    }
}

@main
struct AgentPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Hosting view that lets every click land on its SwiftUI content even when
/// the popover window isn't the key window — avoiding the macOS "first
/// mouse swallowed" behavior.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum Notifier {
    static func notifyWaiting(session: Session) {
        guard Bundle.main.bundleIdentifier != nil else { return }

        let content = UNMutableNotificationContent()

        // ── Title ── session identifier the user recognizes first.
        // Include the dir when a custom title is set so project context
        // isn't lost.
        let dir = URL(fileURLWithPath: session.cwd).lastPathComponent
        if let title = session.customTitle, !title.isEmpty, title != dir {
            content.title = "\(title) · \(dir)"
        } else {
            content.title = session.displayName
        }

        // ── Body ── action, then agent + terminal trailing as context.
        var parts: [String] = [L10n.notificationPermissionLine, L10n.agentDisplayName(session.agent)]
        if let source = sourceLabel(for: session) { parts.append(source) }
        content.body = parts.joined(separator: " · ")

        content.sound = .default
        content.userInfo = ["sessionId": session.id]
        let req = UNNotificationRequest(identifier: "pulse.\(session.id).\(Date().timeIntervalSince1970)",
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private static func sourceLabel(for session: Session) -> String? {
        guard let t = session.terminal else { return nil }
        if let app = t.hostApp, !app.isEmpty { return app }
        if let bid = t.bundleIdentifier?.lowercased(), bid.contains("jetbrains") {
            if bid.contains("goland")   { return "GoLand" }
            if bid.contains("intellij") { return "IntelliJ" }
            if bid.contains("pycharm")  { return "PyCharm" }
            if bid.contains("webstorm") { return "WebStorm" }
            if bid.contains("rider")    { return "Rider" }
            if bid.contains("clion")    { return "CLion" }
            return "JetBrains"
        }
        if let emu = t.terminalEmulator, emu.lowercased().contains("jetbrains") {
            return "JetBrains"
        }
        if let p = t.termProgram {
            if p.contains("iTerm")          { return "iTerm" }
            if p.contains("Apple_Terminal") { return "Terminal" }
            if p == "vscode"                { return "VS Code" }
            return p
        }
        return nil
    }
}
