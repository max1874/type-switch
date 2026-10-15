import SwiftUI
import os

let log = Logger(subsystem: "dev.typeswitch.app", category: "core")

@main
struct TypeSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(PrefKey.showMenuBarIcon) private var showMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView(state: delegate.state)
        } label: {
            // One icon, always the same one. A glyph that changes with status
            // turns the menu bar into a display the user has to keep reading;
            // what went wrong belongs in the menu, where it can say so in
            // words.
            Image("MenuBarIcon")
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.menu)
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

    /// Opens on the pane being asked about. The menu's permission entries and
    /// the setup window both land here, and neither is a request to look at the
    /// trigger key.
    static func open(pane: SettingsView.Pane = .trigger) {
        let window = window ?? make()
        Self.window = window

        if let hosting = window.contentView as? NSHostingView<SettingsView> {
            // Built once and shown again, so the pane it was made with is not
            // necessarily the pane this caller wants.
            hosting.rootView = SettingsView(pane: pane)
        }

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
        window.delegate = sharedCloser   // delegate is weak; `sharedCloser` is held here

        window.center()
        return window
    }
}

/// What a first launch shows, before anything is expected of the app.
///
/// Without it the app installs, asks for two permissions, and then does nothing
/// visible: the trigger is a keystroke, the result is a silent edit, and a
/// missing grant produces neither. The window says what is needed, offers the
/// switch for each, and stays honest about whether the grants have arrived
/// yet — which is what turns "it doesn't work" into "one more click".
@MainActor
enum SetupWindow {
    private static var window: NSWindow?

    static func open() {
        let window = window ?? make()
        Self.window = window

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Dismissed by the user having finished with it. Closing the window is
    /// also what drops the activation policy back to accessory, since both
    /// windows share the one delegate.
    static func close() {
        window?.close()
    }

    private static func make() -> NSWindow {
        let hosting = NSHostingView(rootView: SetupView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "TypeSwitch 设置")
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.delegate = sharedCloser
        window.center()
        return window
    }
}

/// Drops back to a menu bar–only app when the window closes. One instance for
/// every window this app owns: the policy is the app's, not a window's, and two
/// delegates would fight over it when the second window closed first.
@MainActor
let sharedCloser = WindowCloser()

final class WindowCloser: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let state = AppState()

    private var monitor: HotkeyMonitor?
    private var permissionPoll: Timer?
    /// Whether the poll has already said, once, which grant is missing. A poll
    /// that logs every second is a poll nobody can read afterwards.
    private var loggedMissing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()

        #if DEBUG
        // Launched to draw a picture of itself, or to send one line to an
        // endpoint — not to run. Nothing below here should happen in either
        // case: no permission prompts, no event tap.
        if WindowCapture.runIfRequested() { return }
        if RewriteCheck.runIfRequested() { return }
        if UpdateCheck.runIfRequested() { return }
        #endif

        Permissions.requestAccessibility()
        Permissions.requestInputMonitoring()

        // Two ways to arrive at the setup window: it has never been seen, or the
        // menu bar icon is hidden so a launch has nothing else to show for
        // itself. Either way it is the same window.
        if Prefs.needsSetup {
            SetupWindow.open()
        } else if !UserDefaults.standard.bool(forKey: PrefKey.showMenuBarIcon) {
            SettingsWindow.open(pane: .general)
        }

        monitor = HotkeyMonitor { [weak self] in
            self?.handleTrigger()
        }

        // After the app is up and working, not during launch: an update is
        // never the reason someone opened this, and a check that fails on its
        // own says nothing.
        if UserDefaults.standard.bool(forKey: PrefKey.checkForUpdates) {
            Task {
                try? await Task.sleep(for: .seconds(3))
                await Updater.shared.check(asked: false)
            }
        }

        if !startMonitoring() {
            state.status = .needsPermission
            // TCC grants land while the app is already running, and the tap can
            // only be created after both are in place. Poll instead of making
            // the user relaunch.
            permissionPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.startMonitoring(logging: true) }
            }
        }
    }

    /// The way back in once the menu bar icon is hidden: opening the app again
    /// brings up the window it would have shown at launch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if Prefs.needsSetup {
            SetupWindow.open()
        } else {
            SettingsWindow.open(pane: .general)
        }
        return true
    }

    @discardableResult
    private func startMonitoring(logging: Bool = false) -> Bool {
        guard Permissions.hasAccessibility, Permissions.hasInputMonitoring else {
            if logging, !loggedMissing {
                loggedMissing = true
                log.info("""
                    waiting on permissions — accessibility \
                    \(Permissions.hasAccessibility, privacy: .public), \
                    input monitoring \(Permissions.hasInputMonitoring, privacy: .public)
                    """)
            }
            return false
        }
        guard let monitor, monitor.start() else {
            log.error("permissions granted but event tap still could not be created")
            return false
        }
        permissionPoll?.invalidate()
        permissionPoll = nil
        // The menu has been saying "missing permission" for as long as that was
        // true, and it is no longer true.
        if case .needsPermission = state.status { state.status = .idle }
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
            // Both of these land before the wait, not after: they are the
            // answer to "did that keystroke do anything", and an answer that
            // arrives with the rewrite is no answer at all.
            Notice.onTrigger()
            Progress.show(String(localized: "改写中…"))
            // The tap is listen-only, so the trigger keystrokes are still on
            // their way to the target app. Read after they have landed,
            // otherwise we capture a line that is about to change under us.
            try? await Task.sleep(for: .milliseconds(120))
            await rewriteAtCaret()
        }
    }

    private func rewriteAtCaret() async {
        defer { Progress.hide() }

        let capture: TextCapture
        do {
            capture = try TextAccess.capture()
        } catch {
            fail(error, at: "capture")
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
            fail(error, at: "rewrite")
        }
    }

    /// A failure has to reach the user without being read for: the trigger was
    /// a keystroke, so the only thing to see otherwise is that nothing changed.
    /// The menu carries the same message for anyone who goes looking.
    ///
    /// The log names the app that was in front. Which app it was decides what
    /// a read failure means, and without it in the log the only way to find
    /// out afterwards is to go digging through WindowServer's own records.
    private func fail(_ error: Error, at stage: String) {
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        log.error("""
            \(stage, privacy: .public) failed in \(app, privacy: .public): \
            \(error.localizedDescription, privacy: .public)
            """)
        state.status = .error(error.localizedDescription)
        Notice.show(error.localizedDescription)
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
