import AppKit
import CoreGraphics

/// Watches for three quick taps on the space bar.
///
/// Every space is passed through untouched. A session tap sees keystrokes
/// before the input method does, so swallowing a space would break candidate
/// selection for anyone typing Chinese — which is exactly this app's user. The
/// spaces the trigger leaves behind (including the ". " that
/// `NSAutomaticPeriodSubstitutionEnabled` produces from the first two) sit at
/// the end of the line we are about to replace wholesale, so they disappear
/// with the rewrite.
final class HotkeyMonitor {
    /// Raised while we post our own synthetic keystrokes (the pasteboard
    /// fallback in TextAccess) so the tap does not react to its own output.
    /// Only ever touched on the main thread, where the tap callback runs.
    nonisolated(unsafe) static var suppressed = false

    private let onTrigger: () -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lastSpaceAt: CFAbsoluteTime = 0
    private var spaceCount = 0

    private let spaceKeyCode: Int64 = 49
    private let tapWindow: CFAbsoluteTime = 0.3
    private let tapsToTrigger = 3

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    deinit { stop() }

    /// Returns false when the tap could not be created, which in practice means
    /// Input Monitoring has not been granted.
    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,          // we never modify or drop a key event
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyTapCallback,
            userInfo: refcon
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)

        // The system disables a tap that takes too long in its callback. Do the
        // real work asynchronously below, and re-arm here if it happens anyway.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return passthrough
        }

        guard type == .keyDown, !Self.suppressed else { return passthrough }

        guard event.getIntegerValueField(.keyboardEventKeycode) == spaceKeyCode else {
            spaceCount = 0
            return passthrough
        }

        // A modified space (⌘Space, ⌥Space, ⌃Space) belongs to someone else.
        let disqualifying: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        guard event.flags.isDisjoint(with: disqualifying) else {
            spaceCount = 0
            return passthrough
        }

        let now = CFAbsoluteTimeGetCurrent()
        spaceCount = (now - lastSpaceAt < tapWindow) ? spaceCount + 1 : 1
        lastSpaceAt = now

        if spaceCount >= tapsToTrigger {
            spaceCount = 0
            lastSpaceAt = 0
            DispatchQueue.main.async { [weak self] in self?.onTrigger() }
        }
        return passthrough
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
