import RaiCore
import PhotosUI
import SwiftTerm
import SwiftUI
import UIKit

struct PaneTerminalView: View {
    let pane: Pane
    @ObservedObject var connection: BridgeConnection
    @State private var composedLine = ""
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isSendingImage = false
    @State private var imageError: String?
    @StateObject private var terminalSearch = TerminalSearchController()

    var body: some View {
        VStack(spacing: 0) {
            StreamingTerminalView(
                paneID: pane.paneID,
                connection: connection,
                search: terminalSearch,
                send: { connection.sendInput($0, to: pane.paneID) }
            )
            .background(Color.black)

            if isSearching {
                HStack(spacing: 8) {
                    TextField("Find in scrollback", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { terminalSearch.next(searchText) }
                        .onChange(of: searchText) { _, query in
                            terminalSearch.search(query)
                        }
                    Text(terminalSearch.summary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36)
                    Button { terminalSearch.previous(searchText) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(searchText.isEmpty)
                    Button { terminalSearch.next(searchText) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(searchText.isEmpty)
                    Button {
                        isSearching = false
                        terminalSearch.clear()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }

            HStack(spacing: 8) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    if isSendingImage {
                        ProgressView()
                    } else {
                        Image(systemName: "photo")
                    }
                }
                .disabled(isSendingImage)
                .accessibilityLabel("Send photo")
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isSearching.toggle()
                    if !isSearching { terminalSearch.clear() }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Find in terminal")
            }
        }
        .onAppear { connection.openPane(paneID: pane.paneID) }
        .onDisappear { connection.closePane(paneID: pane.paneID) }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await sendPhoto(item) }
        }
        .alert(
            "Could Not Send Photo",
            isPresented: Binding(
                get: { imageError != nil },
                set: { if !$0 { imageError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(imageError ?? "")
        }
    }

    private func sendComposedLine() {
        guard !composedLine.isEmpty else { return }
        connection.sendInput(Array(composedLine.utf8) + [0x0D], to: pane.paneID)
        composedLine = ""
    }

    private func sendPhoto(_ item: PhotosPickerItem) async {
        isSendingImage = true
        defer {
            isSendingImage = false
            selectedPhoto = nil
        }
        do {
            guard let source = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: source),
                  let data = Self.sizedPNG(from: image)
            else {
                throw PhotoSendError.invalidImage
            }
            try await connection.sendImage(
                data,
                filename: "photo-\(Int(Date().timeIntervalSince1970)).png",
                to: pane.paneID
            )
        } catch {
            imageError = error.localizedDescription
        }
    }

    private static func sizedPNG(from source: UIImage) -> Data? {
        var image = source
        let maxDimension: CGFloat = 2_048
        let longest = max(image.size.width, image.size.height)
        if longest > maxDimension {
            image = image.resized(by: maxDimension / longest)
        }
        var data = image.pngData()
        while let current = data, current.count > 4 * 1_024 * 1_024,
              min(image.size.width, image.size.height) > 512 {
            image = image.resized(by: 0.75)
            data = image.pngData()
        }
        guard let data, data.count <= 5 * 1_024 * 1_024 else { return nil }
        return data
    }
}

private struct StreamingTerminalView: UIViewRepresentable {
    let paneID: String
    let connection: BridgeConnection
    let search: TerminalSearchController
    let send: ([UInt8]) -> Void

    // Render the pane at a faithful fixed width (agent TUIs assume ~80 cols) and
    // let the user scroll horizontally, rather than reflowing to phone-width and
    // mangling the layout.
    static let columns = 80
    private static let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    func makeCoordinator() -> Coordinator {
        Coordinator(paneID: paneID, connection: connection, search: search, send: send)
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
        search.terminal = terminal

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
        coordinator.search.terminal = nil
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let paneID: String
        let connection: BridgeConnection
        var send: ([UInt8]) -> Void
        var frameHandlerID: UUID?
        weak var terminal: TerminalView?
        let search: TerminalSearchController

        init(
            paneID: String,
            connection: BridgeConnection,
            search: TerminalSearchController,
            send: @escaping ([UInt8]) -> Void
        ) {
            self.paneID = paneID
            self.connection = connection
            self.search = search
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

@MainActor
private final class TerminalSearchController: ObservableObject {
    @Published private(set) var summary = "0/0"
    weak var terminal: TerminalView?

    func search(_ query: String) {
        terminal?.clearSearch()
        if query.isEmpty {
            summary = "0/0"
        } else {
            next(query)
        }
    }

    func next(_ query: String) {
        guard !query.isEmpty else { return }
        _ = terminal?.findNext(query)
        updateSummary(query)
    }

    func previous(_ query: String) {
        guard !query.isEmpty else { return }
        _ = terminal?.findPrevious(query)
        updateSummary(query)
    }

    func clear() {
        terminal?.clearSearch()
        summary = "0/0"
    }

    private func updateSummary(_ query: String) {
        let value: (index: Int, total: Int) =
            terminal?.searchMatchSummary(query) ?? (index: 0, total: 0)
        summary = "\(value.index)/\(value.total)"
    }
}

private enum PhotoSendError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        "The selected image could not be prepared under the 5 MB limit."
    }
}

private extension UIImage {
    func resized(by scale: CGFloat) -> UIImage {
        let size = CGSize(
            width: max(1, self.size.width * scale),
            height: max(1, self.size.height * scale)
        )
        return UIGraphicsImageRenderer(size: size).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
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
