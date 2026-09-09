import AppKit
import SwiftUI

/// A short-lived panel that says what went wrong, where the user is already
/// looking.
///
/// The menu bar cannot do this job — the icon can be hidden, and a glyph cannot
/// name a failure. Nor can writing the message into the user's own text: the
/// failures worth reporting include the ones where the text could not be read,
/// and writing back runs through the same machinery that just failed, so that
/// channel goes silent exactly when it is needed. It would also mean editing a
/// document to report an error, which the user then has to undo.
///
/// So this touches nothing. It never takes focus or a keystroke, it ignores
/// clicks, it changes no document, and it takes itself away.
@MainActor
enum Notice {
    private static var panel: NSPanel?
    private static var host: NSHostingView<NoticeView>?
    private static var dismissal: Timer?

    private static let visibleFor: TimeInterval = 4
    private static let fade: TimeInterval = 0.18

    static func show(_ message: String) {
        let panel = panel ?? make()
        Self.panel = panel

        host?.rootView = NoticeView(message: message)
        host?.layoutSubtreeIfNeeded()
        if let fitting = host?.fittingSize {
            panel.setContentSize(fitting)
        }
        place(panel)

        dismissal?.invalidate()

        // orderFrontRegardless, never makeKey: an accessory app that activated
        // itself to show an error would take the keyboard away mid-sentence,
        // which is worse than the error.
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            panel.animator().alphaValue = 1
        }

        dismissal = Timer.scheduledTimer(withTimeInterval: visibleFor, repeats: false) { _ in
            MainActor.assumeIsolated { hide() }
        }
    }

    private static func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private static func make() -> NSPanel {
        let host = NSHostingView(rootView: NoticeView(message: ""))
        Self.host = host

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
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }

    /// On whichever screen the pointer is on, since that is the one being
    /// worked on, and low enough not to sit over what is being typed.
    private static func place(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }

        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: area.midX - size.width / 2,
            y: area.minY + area.height * 0.12
        ))
    }
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
