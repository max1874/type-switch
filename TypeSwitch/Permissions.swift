import AppKit
import ApplicationServices
import IOKit.hid

/// The two TCC grants TypeSwitch needs. Both are per-bundle-id, so the app must
/// run as a signed .app bundle — running the bare executable will never work.
enum Permissions {
    /// Accessibility: required to read and write text in other apps via AXUIElement.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Input Monitoring: required for CGEvent.tapCreate to return a live tap.
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
