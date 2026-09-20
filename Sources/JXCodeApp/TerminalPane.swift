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
        // The theme already treats a well this way: `Theme.surfaceSunken` is dark
        // in light mode too (`#1F1E1C`), because a terminal is inset rather than
        // raised. A light terminal would also be the wrong surface for ANSI
        // content — the palette's bright yellow and cyan are close to unreadable
        // on white, so following the appearance here would break the output of
        // every tool that colours its logs.
        //
        // The numbers are a near-neighbour of `surfaceSunken`'s dark stop
        // (`#0F0E13`) rather than a read of it, because `TerminalView` wants an
        // `NSColor` at construction and a dynamic provider would not re-resolve
        // when the appearance changes anyway. Keep them in step by hand.
        view.nativeBackgroundColor = NSColor(
            red: 0.075, green: 0.078, blue: 0.094, alpha: 1
        )
        view.nativeForegroundColor = NSColor(
            red: 0.95, green: 0.96, blue: 0.97, alpha: 1
        )
        view.selectedTextBackgroundColor = NSColor(
            red: 0.231, green: 0.510, blue: 0.965, alpha: 0.35
        )

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
