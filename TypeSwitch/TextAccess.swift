import AppKit
import ApplicationServices

enum TextAccessPath: String {
    case accessibility = "AX"
    case pasteboard = "pasteboard"
}

struct TextCapture {
    let text: String
    let path: TextAccessPath
    /// Present only on the AX path.
    let element: AXUIElement?
    /// Where `text` sits, on the AX path. The selection is only applied at
    /// write time — selecting during capture would leave the range selected
    /// while the trigger keystrokes are still in flight, and the next one to
    /// arrive would overwrite it.
    let range: NSRange?
    /// The app that was frontmost when the text was read. A rewrite takes about
    /// a second, which is long enough for the user to switch windows — writing
    /// back into whatever is focused by then would corrupt an unrelated app.
    let frontmostPID: pid_t
}

enum TextAccessError: LocalizedError {
    case noFocusedElement
    case noText
    /// Named for what was observed rather than for a guess at the cause. An
    /// unchanged pasteboard means the copy was never served; whether that is
    /// because there was nothing to copy or because the app never answered is
    /// not something this can tell apart, and both read the same to the person
    /// who triggered it. Saying "timed out" claimed to know.
    case unreadable(String)
    case axWriteFailed(AXError)
    case appChanged
    case contentChanged

    var errorDescription: String? {
        switch self {
        case .noFocusedElement: String(localized: "找不到当前输入框")
        case .noText: String(localized: "当前位置没有可转换的文字")
        case .unreadable(let app): String(localized: "读不到 \(app) 里的文字")
        case .axWriteFailed(let err): String(localized: "写回失败（AXError \(Int(err.rawValue))）")
        case .appChanged: String(localized: "焦点已经切走，没有写回")
        case .contentChanged: String(localized: "文字已经被改动，没有写回")
        }
    }
}

/// Reads the text to convert and writes the result back.
///
/// Two paths. Accessibility is preferred: it never touches the pasteboard and
/// replaces text in one call. Many Electron-based apps expose no usable AX text
/// attributes, so a synthetic-keystroke pasteboard path is required as a
/// fallback, not as an enhancement.
enum TextAccess {
    // Virtual key codes (Carbon kVK_*).
    private static let keyC: CGKeyCode = 8
    private static let keyV: CGKeyCode = 9
    private static let keyLeft: CGKeyCode = 123

    static func capture() throws -> TextCapture {
        do {
            return try captureViaAX()
        } catch {
            log.info("AX capture unavailable (\(error.localizedDescription, privacy: .public)), falling back to pasteboard")
            return try captureViaPasteboard()
        }
    }

    static func write(_ text: String, using capture: TextCapture) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == capture.frontmostPID
        else { throw TextAccessError.appChanged }

        switch capture.path {
        case .accessibility:
            guard let element = capture.element, let range = capture.range else {
                throw TextAccessError.noFocusedElement
            }
            // The captured range is only meaningful if that text is still sitting
            // there. If the user kept typing during the request, leave it alone.
            guard let value = copyString(element, kAXValueAttribute) else {
                throw TextAccessError.contentChanged
            }
            let current = value as NSString
            guard range.location + range.length <= current.length,
                  current.substring(with: range) == capture.text
            else { throw TextAccessError.contentChanged }

            try setRange(element, range)
            let err = AXUIElementSetAttributeValue(
                element, kAXSelectedTextAttribute as CFString, text as CFString
            )
            // TextEdit returns success here without applying anything, so the
            // return value is not evidence. Only the document is.
            if err == .success, didApply(text, to: element, at: range.location) { return }

            log.info("AX write did not take (AXError \(err.rawValue, privacy: .public)), pasting instead")
            try writeViaPasteboard(text)
        case .pasteboard:
            try writeViaPasteboard(text)
        }
    }

    /// Re-reads the element and checks the new text actually landed.
    private static func didApply(_ text: String, to element: AXUIElement, at location: Int) -> Bool {
        guard let value = copyString(element, kAXValueAttribute) else { return false }
        let current = value as NSString
        let length = (text as NSString).length
        guard location >= 0, location + length <= current.length else { return false }
        return current.substring(with: NSRange(location: location, length: length)) == text
    }

    // MARK: - Accessibility path

    /// Reads only — the document is left exactly as it was found.
    private static func captureViaAX() throws -> TextCapture {
        guard let element = focusedElement() else { throw TextAccessError.noFocusedElement }
        guard let value = copyString(element, kAXValueAttribute),
              let caret = copyRange(element, kAXSelectedTextRangeAttribute)
        else { throw TextAccessError.noText }

        let full = value as NSString
        // A live selection is the range the user pointed at; otherwise the
        // caret's line.
        let range = caret.length > 0 ? caret : lineRange(in: full, containing: caret.location)
        guard range.length > 0, range.location + range.length <= full.length else {
            throw TextAccessError.noText
        }

        let text = full.substring(with: range)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TextAccessError.noText
        }
        return TextCapture(text: text, path: .accessibility, element: element,
                           range: range, frontmostPID: frontmostPID())
    }

    private static func frontmostPID() -> pid_t {
        NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    }

    /// The name a person would use for the app in front. An error about
    /// reading text is only actionable if it says where the reading failed.
    private static func frontmostName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName
            ?? String(localized: "当前 app")
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &value
        ) == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func copyRange(_ element: AXUIElement, _ attribute: String) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }

        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func setRange(_ element: AXUIElement, _ range: NSRange) throws {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else {
            throw TextAccessError.noText
        }
        let err = AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, value
        )
        guard err == .success else { throw TextAccessError.axWriteFailed(err) }
    }

    /// The caret's line, without its trailing newline. AX ranges are UTF-16
    /// offsets, which is exactly what NSString works in.
    private static func lineRange(in text: NSString, containing location: Int) -> NSRange {
        let clamped = min(max(location, 0), text.length)
        var range = text.lineRange(for: NSRange(location: clamped, length: 0))
        while range.length > 0 {
            let last = text.character(at: range.location + range.length - 1)
            guard last == 0x0A || last == 0x0D || last == 0x2028 || last == 0x2029 else { break }
            range.length -= 1
        }
        return range
    }

    // MARK: - Pasteboard fallback

    private static func captureViaPasteboard() throws -> TextCapture {
        let pasteboard = NSPasteboard.general
        let saved = savedItems(of: pasteboard)
        defer { restore(saved, to: pasteboard) }

        HotkeyMonitor.suppressed = true
        defer { HotkeyMonitor.suppressed = false }

        // Is anything already selected? Only a short wait here: if nothing is,
        // the pasteboard is never going to move, and that is the ordinary case
        // — every trigger would pay for a longer one.
        if let copied = copyOnce(pasteboard, waiting: 0.25), !copied.isEmpty {
            return capture(copied)
        }

        // Select the line, then copy it. This one is worth both waiting for and
        // asking twice. The selection keystroke is handled by the target app on
        // its own schedule, and a copy that arrives before the selection does
        // copies nothing — an Electron app routinely needs longer than the few
        // milliseconds a native one does. Rather than guess at that interval,
        // ask again until the app answers.
        synthesize(keyLeft, flags: [.maskCommand, .maskShift])
        for attempt in 0..<3 {
            if let copied = copyOnce(pasteboard, waiting: 0.4 + Double(attempt) * 0.3),
               !copied.isEmpty {
                return capture(copied)
            }
        }
        throw TextAccessError.unreadable(frontmostName())
    }

    private static func capture(_ text: String) -> TextCapture {
        TextCapture(text: text, path: .pasteboard, element: nil,
                    range: nil, frontmostPID: frontmostPID())
    }

    /// One ⌘C, and a wait for the app to serve it. Returns as soon as the
    /// pasteboard moves, so patience costs nothing when the copy works.
    private static func copyOnce(_ pasteboard: NSPasteboard, waiting: TimeInterval) -> String? {
        let before = pasteboard.changeCount
        synthesize(keyC, flags: .maskCommand)

        let deadline = Date().addingTimeInterval(waiting)
        while Date() < deadline {
            if pasteboard.changeCount != before {
                return pasteboard.string(forType: .string)
            }
            usleep(10_000)
        }
        return nil
    }

    private static func writeViaPasteboard(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        let saved = savedItems(of: pasteboard)

        HotkeyMonitor.suppressed = true
        defer { HotkeyMonitor.suppressed = false }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        synthesize(keyV, flags: .maskCommand)

        // The paste is asynchronous in the target app; restoring the pasteboard
        // immediately would race it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            restore(saved, to: pasteboard)
        }
    }

    private static func savedItems(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }

    private static func synthesize(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cgAnnotatedSessionEventTap)
        }
        usleep(15_000)  // give the target app a moment to act on the keystroke
    }
}
