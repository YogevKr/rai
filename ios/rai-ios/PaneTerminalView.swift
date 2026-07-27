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
            StreamingTerminalView(
                paneID: pane.paneID,
                connection: connection,
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
        .onDisappear { connection.closePane(paneID: pane.paneID) }
    }

    private func sendComposedLine() {
        guard !composedLine.isEmpty else { return }
        connection.sendInput(Array(composedLine.utf8) + [0x0D], to: pane.paneID)
        composedLine = ""
    }
}

private struct StreamingTerminalView: UIViewRepresentable {
    let paneID: String
    let connection: BridgeConnection
    let send: ([UInt8]) -> Void

    // Render the pane at a faithful fixed width (agent TUIs assume ~80 cols) and
    // let the user scroll horizontally, rather than reflowing to phone-width and
    // mangling the layout.
    static let columns = 80
    private static let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    func makeCoordinator() -> Coordinator {
        Coordinator(paneID: paneID, connection: connection, send: send)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let terminal = TerminalView(frame: .zero, font: Self.font)
        terminal.terminalDelegate = context.coordinator
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = .white
        terminal.caretColor = .white
        terminal.indicatorStyle = .white
        terminal.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.terminal = terminal

        context.coordinator.frameHandlerID = connection.addPaneFrameHandler(for: paneID) {
            [weak terminal] data, full in
            // A `full` frame starts a fresh stream (initial attach, or a restart
            // after resize/reconnect). Clear the visible screen + home the cursor
            // first so stale cells/styles from the previous stream don't bleed
            // through; scrollback above is preserved.
            if full {
                terminal?.feed(byteArray: [0x1B, 0x5B, 0x48, 0x1B, 0x5B, 0x32, 0x4A][...])
            }
            terminal?.feed(byteArray: [UInt8](data)[...])
        }

        // Fix the grid to `columns` and host it in a horizontally-scrolling view.
        // The terminal keeps its own vertical scrollback; the outer scroll view
        // only moves left/right so wide output is reachable on a narrow screen.
        let charWidth = ("W" as NSString)
            .size(withAttributes: [.font: Self.font]).width
        let terminalWidth = ceil(charWidth * CGFloat(Self.columns)) + 4

        let scroll = UIScrollView()
        scroll.backgroundColor = .black
        scroll.showsHorizontalScrollIndicator = true
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            terminal.widthAnchor.constraint(equalToConstant: terminalWidth),
            terminal.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.send = send
    }

    static func dismantleUIView(_ scroll: UIScrollView, coordinator: Coordinator) {
        if let id = coordinator.frameHandlerID {
            coordinator.connection.removePaneFrameHandler(for: coordinator.paneID, id: id)
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let paneID: String
        let connection: BridgeConnection
        var send: ([UInt8]) -> Void
        var frameHandlerID: UUID?
        weak var terminal: TerminalView?

        init(
            paneID: String,
            connection: BridgeConnection,
            send: @escaping ([UInt8]) -> Void
        ) {
            self.paneID = paneID
            self.connection = connection
            self.send = send
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            send(Array(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // Width is fixed to `columns`; only the row count varies with height.
            // SwiftTerm fires this on the main thread, but it is a nonisolated
            // protocol method, so hop onto the main actor to touch the connection.
            Task { @MainActor [connection, paneID] in
                connection.resizePane(
                    paneID: paneID,
                    cols: StreamingTerminalView.columns,
                    rows: newRows
                )
            }
        }
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
