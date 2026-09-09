import Combine
import SwiftUI
import os

let log = Logger(subsystem: "dev.typeswitch.app", category: "core")

@main
struct TypeSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(PrefKey.showMenuBarIcon) private var showMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra(isInserted: iconVisible) {
            MenuBarView(state: delegate.state)
        } label: {
            MenuBarLabel(state: delegate.state)
        }
        .menuBarExtraStyle(.menu)
    }

    /// Hiding the icon hides the only place status is ever shown, so a failed
    /// rewrite looked exactly like nothing happening. A problem puts the icon
    /// back until it is resolved; the user's own setting is what gets written
    /// when they toggle it, so it returns to hidden on its own.
    private var iconVisible: Binding<Bool> {
        Binding(
            get: { showMenuBarIcon || delegate.hasProblem },
            set: { showMenuBarIcon = $0 }
        )
    }
}

/// The icon tracks status, which needs something observing the state object;
/// the scene itself is not rebuilt for every change.
private struct MenuBarLabel: View {
    @ObservedObject var state: AppState

    var body: some View {
        Image(systemName: state.status.symbolName)
    }
}

/// Settings live in a window this app owns outright.
///
/// SwiftUI's `Settings` scene never created a window in this LSUIElement app —
/// neither `SettingsLink` nor `showSettingsWindow:` produced one (the window
/// list showed only the menu bar extra's). An NSWindow built here always
/// appears, and an accessory app has to activate itself to come to the front.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    private static let closer = WindowCloser()

    static func open() {
        let window = window ?? make()
        Self.window = window

        // An accessory app is absent from ⌘-Tab and the Dock, so once this
        // window fell behind another app there was no way back to it. Become a
        // regular app for as long as it is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        log.info("settings window shown: \(NSStringFromRect(window.frame), privacy: .public)")
    }

    static func make(showing pane: SettingsView.Pane = .trigger) -> NSWindow {
        let hosting = NSHostingView(rootView: SettingsView(pane: pane))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 540),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "TypeSwitch 设置")
        window.contentView = hosting
        window.isReleasedWhenClosed = false   // reopened, not rebuilt

        // Let the sidebar's material run the full height of the window, which is
        // what separates a current-looking settings window from a plain one.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.delegate = closer   // delegate is weak; `closer` is held above

        window.center()
        return window
    }
}

/// Drops back to a menu bar–only app when the settings window closes.
private final class WindowCloser: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let state = AppState()

    /// Mirrored out of `state` because the scene observes the delegate, not the
    /// state object nested inside it.
    @Published private(set) var hasProblem = false

    private var monitor: HotkeyMonitor?
    private var permissionPoll: Timer?
    private var statusObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()

        #if DEBUG
        // Launched to draw a picture of itself, not to run. Nothing below here
        // should happen in that case: no permission prompts, no event tap.
        if WindowCapture.runIfRequested() { return }
        #endif

        statusObserver = state.$status.sink { [weak self] status in
            self?.hasProblem = status.isProblem
        }
        Permissions.requestAccessibility()
        Permissions.requestInputMonitoring()

        // With the icon hidden there is nothing else to show for a launch.
        if !UserDefaults.standard.bool(forKey: PrefKey.showMenuBarIcon) {
            openSettings()
        }

        monitor = HotkeyMonitor { [weak self] in
            self?.handleTrigger()
        }

        if !startMonitoring() {
            // TCC grants land while the app is already running, and the tap can
            // only be created after both are in place. Poll instead of making
            // the user relaunch.
            state.status = .needsPermission
            permissionPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.startMonitoring() }
            }
        }
    }

    /// The way back in once the menu bar icon is hidden: opening the app again
    /// brings up settings instead of doing nothing visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return true
    }

    private func openSettings() { SettingsWindow.open() }

    @discardableResult
    private func startMonitoring() -> Bool {
        guard Permissions.hasAccessibility, Permissions.hasInputMonitoring else { return false }
        guard let monitor, monitor.start() else {
            log.error("permissions granted but event tap still could not be created")
            return false
        }
        permissionPoll?.invalidate()
        permissionPoll = nil
        state.status = .idle
        log.info("monitoring started")
        return true
    }

    private func handleTrigger() {
        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           ExcludedApps.contains(bundleID) {
            log.info("ignored in \(bundleID, privacy: .public)")
            return
        }

        state.status = .working
        Task {
            // The tap is listen-only, so the trigger keystrokes are still on
            // their way to the target app. Read after they have landed,
            // otherwise we capture a line that is about to change under us.
            try? await Task.sleep(for: .milliseconds(120))
            await rewriteAtCaret()
        }
    }

    private func rewriteAtCaret() async {
        let capture: TextCapture
        do {
            capture = try TextAccess.capture()
        } catch {
            log.error("capture failed: \(error.localizedDescription, privacy: .public)")
            state.status = .error(error.localizedDescription)
            return
        }
        log.info("captured via \(capture.path.rawValue, privacy: .public): \(capture.text, privacy: .public)")

        let started = Date()
        do {
            let rewritten = try await Rewriter.rewrite(capture.text)
            try TextAccess.write(rewritten, using: capture)

            let ms = Int(Date().timeIntervalSince(started) * 1000)
            log.info("rewrote in \(ms, privacy: .public)ms: \(rewritten, privacy: .public)")
            state.status = .idle
        } catch {
            // Capture does not modify the document, so there is nothing to roll
            // back — the user's text is untouched wherever this failed.
            log.error("rewrite failed: \(error.localizedDescription, privacy: .public)")
            state.status = .error(error.localizedDescription)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var status: Status = .idle

    enum Status {
        case idle
        case working
        case needsPermission
        case error(String)

        /// Whether the user needs to see this. Working and idle are not worth
        /// interrupting a hidden icon for; the other two are the whole reason
        /// the icon exists.
        var isProblem: Bool {
            switch self {
            case .idle, .working: false
            case .needsPermission, .error: true
            }
        }

        var symbolName: String {
            switch self {
            case .idle: "character.cursor.ibeam"
            case .working: "ellipsis.circle"
            case .needsPermission: "exclamationmark.triangle"
            case .error: "xmark.circle"
            }
        }

        var label: String {
            switch self {
            case .idle: String(localized: "就绪 · 连按 \(Prefs.triggerCount) 次「\(Prefs.trigger.label)」触发")
            case .working: String(localized: "处理中…")
            case .needsPermission: String(localized: "缺少权限")
            case .error(let message): String(localized: "出错：\(message)")
            }
        }
    }
}
