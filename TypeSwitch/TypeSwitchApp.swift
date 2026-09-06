import SwiftUI
import os

let log = Logger(subsystem: "com.youxianglin.TypeSwitch", category: "core")

@main
struct TypeSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(state: delegate.state)
        } label: {
            Image(systemName: delegate.state.status.symbolName)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var monitor: HotkeyMonitor?
    private var permissionPoll: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Permissions.requestAccessibility()
        Permissions.requestInputMonitoring()

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
            state.lastResult = "\(capture.text) → \(rewritten)"
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
    @Published var lastResult: String?

    enum Status {
        case idle
        case working
        case needsPermission
        case error(String)

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
            case .idle: "就绪 · 双击空格触发"
            case .working: "处理中…"
            case .needsPermission: "缺少权限"
            case .error(let message): "出错：\(message)"
            }
        }
    }
}
