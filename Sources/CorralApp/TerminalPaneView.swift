import AppKit
import CorralCore
import SwiftTerm
import SwiftUI

struct TerminalPaneView: NSViewRepresentable {
    let paneID: String
    let frame: TerminalFrame?
    let client: HerdrClient

    func makeCoordinator() -> Coordinator {
        Coordinator(client: client)
    }

    func makeNSView(context: Context) -> TerminalView {
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let view = TerminalView(frame: .zero, font: font)
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = NSColor(
            calibratedRed: 0.055,
            green: 0.063,
            blue: 0.078,
            alpha: 1
        )
        view.nativeForegroundColor = NSColor(
            calibratedRed: 0.84,
            green: 0.86,
            blue: 0.9,
            alpha: 1
        )
        view.changeScrollback(5_000)
        context.coordinator.paneID = paneID
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.paneID != paneID {
            coordinator.paneID = paneID
            coordinator.lastSequence = nil
            view.getTerminal().resetToInitialState()
        }
        guard let frame,
              frame.paneID == paneID,
              coordinator.lastSequence != frame.sequence else {
            return
        }
        coordinator.lastSequence = frame.sequence

        // pane.read returns a complete rendered viewport, not an incremental byte stream.
        // Replacing the emulated screen prevents repeated snapshots from duplicating output.
        view.getTerminal().resetToInitialState()
        view.feed(text: "\u{001B}[2J\u{001B}[H" + frame.text)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let client: HerdrClient
        var paneID: String?
        var lastSequence: UInt64?

        init(client: HerdrClient) {
            self.client = client
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard let paneID else { return }
            let bytes = Array(data)
            Task {
                try? await client.sendInput(paneID: paneID, bytes: bytes)
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // Herdr protocol 16's pane.resize is directional split resizing.
            // Sending terminal dimensions here would mutate the layout or fail validation.
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
