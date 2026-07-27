import RaiCore
import SwiftTerm
import SwiftUI
import UIKit

struct PaneTerminalView: View {
    let pane: Pane
    @ObservedObject var connection: BridgeConnection
    @State private var composedLine = ""

    var body: some View {
        VStack(spacing: 0) {
            SnapshotTerminalView(
                snapshot: connection.paneOutputs[pane.paneID],
                send: { connection.sendInput($0, to: pane.paneID) }
            )
            .background(Color.black)

            HStack(spacing: 8) {
                TextField("Send a line…", text: $composedLine)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit(sendComposedLine)
                Button("Send", action: sendComposedLine)
                    .buttonStyle(.borderedProminent)
                    .disabled(composedLine.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            TerminalControlToolbar { connection.sendInput($0, to: pane.paneID) }
        }
        .navigationTitle(pane.terminalTitleStripped ?? pane.agent ?? "Pane")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { connection.openPane(paneID: pane.paneID) }
    }

    private func sendComposedLine() {
        guard !composedLine.isEmpty else { return }
        connection.sendInput(Array(composedLine.utf8) + [0x0D], to: pane.paneID)
        composedLine = ""
    }
}

private struct SnapshotTerminalView: UIViewRepresentable {
    let snapshot: Data?
    let send: ([UInt8]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(send: send)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(
            frame: .zero,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        view.caretColor = .white
        view.indicatorStyle = .white
        return view
    }

    func updateUIView(_ terminal: TerminalView, context: Context) {
        context.coordinator.send = send
        guard let snapshot, snapshot != context.coordinator.lastSnapshot else { return }
        context.coordinator.lastSnapshot = snapshot

        // Bridge paneOutput frames are full visible-screen snapshots, not stream
        // chunks. V1 clears and homes before feeding each ANSI snapshot so the
        // phone mirrors herdr. A future raw-output relay can render incrementally
        // and preserve real terminal scrollback.
        let clearAndHome: [UInt8] = [0x1B, 0x5B, 0x32, 0x4A, 0x1B, 0x5B, 0x48]
        terminal.feed(byteArray: clearAndHome[...])
        let snapshotBytes = [UInt8](snapshot)
        terminal.feed(byteArray: snapshotBytes[...])
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var send: ([UInt8]) -> Void
        var lastSnapshot: Data?

        init(send: @escaping ([UInt8]) -> Void) {
            self.send = send
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            send(Array(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

private struct TerminalControlToolbar: View {
    let send: ([UInt8]) -> Void

    private let controls: [(String, [UInt8])] = [
        ("Return", [0x0D]),
        ("Esc", [0x1B]),
        ("Tab", [0x09]),
        ("Ctrl-C", [0x03]),
        ("↑", [0x1B, 0x5B, 0x41]),
        ("↓", [0x1B, 0x5B, 0x42]),
        ("←", [0x1B, 0x5B, 0x44]),
        ("→", [0x1B, 0x5B, 0x43]),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(controls, id: \.0) { label, bytes in
                    Button(label) { send(bytes) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}
