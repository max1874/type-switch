#if DEBUG
import AppKit
import SwiftUI

/// Draws the settings window into a PNG, for the README.
///
/// A screen capture is the wrong tool for this. It needs a screen recording
/// grant, it photographs whatever else happens to be on the display at the
/// time, and two runs never produce the same file. Asking the window to draw
/// itself into a bitmap avoids all three: nothing but this window can be in
/// the image, no permission is involved, and the same build always renders the
/// same pixels.
///
///     TypeSwitch --capture docs/settings.png [--pane provider] [--height 620] [--dark]
///
/// It comes to the front for about a second while it does this, because an
/// inactive window draws every control in its grey shade.
///
/// Anything of the form `-key value` on the same command line lands in
/// UserDefaults' argument domain, which outranks everything stored, so the
/// picture can show chosen settings without writing over the real ones:
///
///     TypeSwitch --capture out.png -providerBaseURL https://api.deepseek.com
///
/// Debug-only. A shipped app has no reason to be able to do this.
@MainActor
enum WindowCapture {
    /// Whether this launch was a capture request. The window is put up here and
    /// read back once the app is running: SwiftUI commits its drawing on the
    /// event loop, which has not started yet while the app is still launching,
    /// so anything read during launch comes back as bare window chrome.
    static func runIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--capture") else { return false }
        guard arguments.indices.contains(flag + 1) else {
            fail("--capture needs a path to write to")
        }
        let path = arguments[flag + 1]
        let dark = arguments.contains("--dark")

        var pane = SettingsView.Pane.trigger
        if let chosen = arguments.firstIndex(of: "--pane"),
           arguments.indices.contains(chosen + 1) {
            guard let named = SettingsView.Pane(rawValue: arguments[chosen + 1]) else {
                fail("no pane named \(arguments[chosen + 1])")
            }
            pane = named
        }

        var height = 540.0
        if let given = arguments.firstIndex(of: "--height"),
           arguments.indices.contains(given + 1) {
            guard let number = Double(arguments[given + 1]), number > 0 else {
                fail("--height wants a number, not \(arguments[given + 1])")
            }
            height = number
        }

        let window = SettingsWindow.make(showing: pane)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: 660, height: height))
        window.center()

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)

        // This takes over the screen for about a second, which is the one cost
        // of the approach: a window belonging to an app that is not frontmost
        // draws every control in its inactive shade, so the picture has to be
        // taken with the app in front. Two waits — one for SwiftUI to come up,
        // one for the activation to land — and then it exits.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // A text field takes first responder when the window opens, and
                // it draws a focus ring and holds whatever an input method left
                // in it. Nothing focused is what the window looks like at rest.
                window.makeFirstResponder(nil)
                write(window: window, to: path)
                exit(0)
            }
        }
        return true
    }

    private static func write(window: NSWindow, to path: String) {
        // Asking the window server for this one window by its id, rather than
        // drawing the view tree: SwiftUI's content lives in layers the window
        // server composites, so `cacheDisplay` and `CALayer.render` both come
        // back with the chrome and an empty middle, and `ImageRenderer` refuses
        // NavigationSplitView and Form altogether. Naming the window id is what
        // keeps this from being a screenshot — nothing else on the display can
        // be in the result, whatever is in front of it.
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            fail("the window server returned no image for window \(window.windowNumber)")
        }
        let bitmap = NSBitmapImageRep(cgImage: image)

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fail("could not encode the bitmap as PNG")
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            fail("could not write \(path): \(error.localizedDescription)")
        }

        print("\(path)  \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)")
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("capture: \(message)\n".utf8))
        exit(1)
    }
}
#endif
