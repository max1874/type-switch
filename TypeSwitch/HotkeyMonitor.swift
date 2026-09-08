import AppKit
import CoreGraphics

/// Watches for the configured key being tapped N times in quick succession.
///
/// Every event is passed through untouched. A session tap sees keystrokes
/// before the input method does, so swallowing a space would break candidate
/// selection for anyone typing Chinese — which is exactly this app's user.
/// Anything the trigger leaves in the line (including the ". " that
/// `NSAutomaticPeriodSubstitutionEnabled` makes out of two spaces) sits at the
/// end of the range we are about to replace, so it goes away with the rewrite.
///
/// Modifier keys arrive as `.flagsChanged` rather than `.keyDown`, and are
/// counted only on press, not on release.
final class HotkeyMonitor {
    /// Raised while we post our own synthetic keystrokes (the pasteboard
    /// fallback in TextAccess) so the tap does not react to its own output.
    /// Only ever touched on the main thread, where the tap callback runs.
    nonisolated(unsafe) static var suppressed = false

    private let onTrigger: () -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lastTapAt: CFAbsoluteTime = 0
    private var tapCount = 0

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    deinit { stop() }

    /// Returns false when the tap could not be created, which in practice means
    /// Input Monitoring has not been granted.
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
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

        // The system disables a tap that takes too long in its callback. The
        // real work is dispatched asynchronously, but re-arm anyway.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return passthrough
        }

        guard !Self.suppressed else { return passthrough }

        let trigger = Prefs.trigger
        guard isTap(of: trigger, type: type, event: event) else {
            // Only reset on events that could have been the trigger. A modifier
            // release, or an unrelated keystroke, should not clear a run in
            // progress for a modifier trigger.
            if type == .keyDown || event.getIntegerValueField(.keyboardEventKeycode) == trigger.keyCode {
                tapCount = 0
            }
            return passthrough
        }

        let now = CFAbsoluteTimeGetCurrent()
        tapCount = (now - lastTapAt < Prefs.triggerWindow) ? tapCount + 1 : 1
        lastTapAt = now

        if tapCount >= Prefs.triggerCount {
            tapCount = 0
            lastTapAt = 0
            DispatchQueue.main.async { [weak self] in self?.onTrigger() }
        }
        return passthrough
    }

    private func isTap(of trigger: TriggerBinding, type: CGEventType, event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.keyboardEventKeycode) == trigger.keyCode else { return false }

        // Holding a key down produces repeats that look exactly like fresh
        // presses. At the system defaults they arrive every ~90ms after a
        // ~375ms delay, so holding the key would always reach the tap count and
        // fire a rewrite the user never asked for.
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }

        if let flag = trigger.modifierFlag {
            // flagsChanged fires on both press and release; the flag is set only
            // on press.
            return type == .flagsChanged && event.flags.contains(flag)
        }

        guard type == .keyDown else { return false }
        // A modified space (⌘Space, ⌥Space, ⌃Space) belongs to someone else.
        let disqualifying: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        return event.flags.isDisjoint(with: disqualifying)
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
