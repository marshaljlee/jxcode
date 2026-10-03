import AppKit
import SwiftTerm
import SwiftUI

/// Hosts a SwiftTerm `TerminalView` and wires it to a `TerminalController`.
///
/// Only the view is borrowed from SwiftTerm — the process behind it is
/// `JXCodeCore.PTYSession`, so the sandbox environment is applied in exactly one
/// place and the CLI exercises the same path.
struct TerminalPane: NSViewRepresentable {
    let controller: TerminalController

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

        // Dark in **both** appearances, deliberately — not a leftover from when
        // the app was pinned dark, which is what this comment used to claim.
        //
        // The terminal is the illustration's ground: the near-black charcoal the
        // whole design is lit against. A light terminal would also be the wrong
        // surface for ANSI content — the palette's bright yellow and cyan are
        // close to unreadable on white, so following the appearance here would
        // break the output of every tool that colours its logs.
        //
        // The colours come from `Theme.Terminal`, which holds the dark stops
        // unconditionally for exactly this reason — `TerminalView` wants plain
        // `NSColor`s at construction and would not re-resolve a dynamic provider
        // when the appearance changes anyway.
        view.nativeBackgroundColor = Theme.Terminal.background
        view.nativeForegroundColor = Theme.Terminal.foreground
        view.caretColor = Theme.Terminal.cursor
        view.selectedTextBackgroundColor = Theme.Terminal.selection

        // SwiftTerm's `nativeForegroundColor` only sets the default ink; the
        // ANSI-16 comes separately, and `installColors` takes SwiftTerm's own
        // `Color` class rather than `NSColor` — hence this mapping.
        view.installColors(Theme.Terminal.ansi.map { hex in
            SwiftTerm.Color(
                red8: UInt16((hex >> 16) & 0xFF),
                green8: UInt16((hex >> 8) & 0xFF),
                blue8: UInt16(hex & 0xFF)
            )
        })

        controller.attach(view)
        controller.start()

        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: TerminalView, coordinator: ()) {
        // The pty is owned by the controller, which outlives the view when tabs
        // are switched. Nothing to tear down here.
    }
}
