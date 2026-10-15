import AppKit
import SwiftUI

/// The floating panels this app shows without ever taking focus.
///
/// A failure and a rewrite in progress are the same shape of problem: the
/// trigger was a keystroke, so there is no window the answer could belong to,
/// and an accessory app that activated itself to say something would take the
/// keyboard away mid-sentence. Both are therefore borderless panels that float,
/// follow the pointer to whichever screen is being worked on, and go away on
/// their own.
///
/// The panel is built once and its content replaced, so showing the second
/// message does not cost a window.
@MainActor
private final class FloatingPanel<Content: View> {
    private var panel: NSPanel?
    private var host: NSHostingView<Content>?
    private var dismissal: Timer?

    private let visibleFor: TimeInterval
    private let fade: TimeInterval
    private let makeContent: (String) -> Content
    private let ignoresMouse: Bool
    /// Where the panel sits, as a fraction of the screen's height above its
    /// bottom edge.
    private let heightFraction: CGFloat

    init(
        visibleFor: TimeInterval,
        fade: TimeInterval,
        ignoresMouse: Bool,
        heightFraction: CGFloat,
        content: @escaping (String) -> Content
    ) {
        self.visibleFor = visibleFor
        self.fade = fade
        self.ignoresMouse = ignoresMouse
        self.heightFraction = heightFraction
        self.makeContent = content
    }

    func show(_ message: String) {
        let panel = panel ?? make()
        self.panel = panel

        host?.rootView = makeContent(message)
        host?.layoutSubtreeIfNeeded()
        if let fitting = host?.fittingSize {
            panel.setContentSize(fitting)
        }
        place(panel)

        dismissal?.invalidate()
        dismissal = nil

        // orderFrontRegardless, never makeKey: an accessory app that activated
        // itself to show a message would take the keyboard away mid-sentence,
        // which is worse than whatever it has to say.
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            panel.animator().alphaValue = 1
        }

        guard visibleFor > 0 else { return }
        dismissal = Timer.scheduledTimer(withTimeInterval: visibleFor, repeats: false) { _ in
            MainActor.assumeIsolated { self.hide() }
        }
    }

    /// Takes it away now rather than letting the timer do it. Used for the
    /// progress panel, which is on screen for exactly as long as the thing it
    /// describes is happening.
    func hide() {
        dismissal?.invalidate()
        dismissal = nil
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func make() -> NSPanel {
        let host = NSHostingView(rootView: makeContent(""))
        self.host = host

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = host
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = ignoresMouse
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }

    /// On whichever screen the pointer is on, since that is the one being
    /// worked on, and low enough not to sit over what is being typed.
    private func place(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }

        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: area.midX - size.width / 2,
            y: area.minY + area.height * heightFraction
        ))
    }
}

/// A short-lived panel that says what went wrong, where the user is already
/// looking.
///
/// Neither of the obvious channels works. The menu bar cannot do it — the icon
/// can be hidden, and a glyph cannot name a failure. Nor can writing the message
/// into the user's own text: the failures worth reporting include the ones where
/// the text could not be read, and writing back runs through the same machinery
/// that just failed, so that channel goes silent exactly when it is needed. It
/// would also mean editing a document to report an error, which the user then
/// has to undo.
///
/// So this touches nothing. It never takes focus or a keystroke, it ignores
/// clicks, it changes no document, and it takes itself away.
@MainActor
enum Notice {
    private static let shared = FloatingPanel(
        visibleFor: 4,
        fade: 0.18,
        ignoresMouse: true,
        heightFraction: 0.12
    ) { NoticeView(message: $0) }

    static func show(_ message: String) {
        shared.show(message)
    }

    /// That the trigger landed, as a tap rather than as text.
    ///
    /// The user's eyes are on the words they were writing, so the one thing
    /// worth saying the moment they are not is said to a sense that is not
    /// busy. On a machine with nothing to tap — an external keyboard on a Mac
    /// mini — this does nothing at all, which costs nothing to ask for.
    static func onTrigger() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

/// The same panel, saying that a rewrite is happening rather than that one
/// failed.
///
/// Without it, the only thing a trigger produces is a wait: the tap is
/// listen-only and the rewrite takes about a second, so nothing on screen
/// changes until the text does. A second is long enough to doubt the trigger
/// fired, press it again, and end up with two rewrites of the same line racing
/// each other.
///
/// It never times out on its own. The rewrite either finishes or fails, and
/// both of those take the panel away — a progress indicator that vanishes while
/// the work continues is worse than none.
@MainActor
enum Progress {
    private static let shared = FloatingPanel(
        visibleFor: 0,
        fade: 0.12,
        ignoresMouse: true,
        heightFraction: 0.12
    ) { WorkingView(message: $0) }

    static func show(_ message: String) { shared.show(message) }
    static func hide() { shared.hide() }
}

private struct NoticeView: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }
}

private struct WorkingView: View {
    let message: String

    var body: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }
}
