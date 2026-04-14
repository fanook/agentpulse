import SwiftUI
import AppKit
import ServiceManagement
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let store = SessionStore()
    private var server: HTTPServer?

    private var statusItem: NSStatusItem!
    private var storeObserver: AnyCancellable?
    private var eventMonitor: Any?
    private var keyMonitor: Any?
    private var localKeyMonitor: Any?
    private var notchPresenter: NotchPresenter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        startServer()
        notchPresenter = NotchPresenter(store: store)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Runtime.clearPortFile()
    }

    // MARK: - Menu bar item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshIcon()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

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
        // The capsule is always the menu-bar action target; autoPop only
        // gates whether *new* waiting events pop it unprompted.
        guard let presenter = notchPresenter else { return }
        if presenter.isSummoned {
            presenter.dismiss()
            removeOutsideMonitor()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            presenter.summon()
            installOutsideMonitor()
        }
    }

    private func installOutsideMonitor() {
        if eventMonitor == nil {
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.dismissNotch() }
            }
        }
        // Esc anywhere — global catches focus in another app, local catches it
        // when something inside our process happens to be key.
        if keyMonitor == nil {
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                if event.keyCode == 53 {
                    Task { @MainActor in self?.dismissNotch() }
                }
            }
        }
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                if event.keyCode == 53 {
                    Task { @MainActor in self?.dismissNotch() }
                    return nil
                }
                return event
            }
        }
    }

    private func removeOutsideMonitor() {
        if let mon = eventMonitor    { NSEvent.removeMonitor(mon); eventMonitor = nil }
        if let mon = keyMonitor      { NSEvent.removeMonitor(mon); keyMonitor = nil }
        if let mon = localKeyMonitor { NSEvent.removeMonitor(mon); localKeyMonitor = nil }
    }

    private func dismissNotch() {
        notchPresenter?.dismiss()
        removeOutsideMonitor()
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let settings = NSMenuItem(title: L10n.settings, action: #selector(openPreferences), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let about = NSMenuItem(title: L10n.about, action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.quit, action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openPreferences() {
        summonCapsule(on: .preferences)
    }

    @objc private func openAbout() {
        summonCapsule(on: .about)
    }

    private func summonCapsule(on screen: NotchScreen) {
        guard let presenter = notchPresenter else { return }
        NSApp.activate(ignoringOtherApps: true)
        presenter.summon(on: screen)
        installOutsideMonitor()
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
        store.apply(event)
    }
}

@main
struct AgentPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // We open Preferences through our own NSWindow (see AppDelegate);
        // the Settings scene stays here only to keep the SwiftUI lifecycle
        // quiet — we deliberately don't route through it.
        Settings { EmptyView() }
    }
}

