import RaiCore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct CapturedTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        self.text = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

enum EndpointSelectionMotion: String, CaseIterable, Identifiable {
    case characterBackward = "Previous Character", characterForward = "Next Character"
    case wordBackward = "Previous Word", wordForward = "Next Word"
    case lineStart = "Line Start", lineEnd = "Line End"
    case documentStart = "Text Start", documentEnd = "Text End"
    var id: Self { self }
}

@MainActor
final class EndpointSelectionController: ObservableObject {
    weak var view: EndpointSelectableTextView?

    func move(_ motion: EndpointSelectionMotion, extending: Bool) {
        #if os(macOS)
        view?.window?.makeFirstResponder(view)
        #else
        view?.becomeFirstResponder()
        #endif
        view?.moveSelection(motion, extending: extending)
    }

    func copy() { view?.copy(nil) }
    func selectAll() { view?.selectAll(nil) }
}

struct EndpointSelectionControls: View {
    let controller: EndpointSelectionController
    @State private var extending = true

    var body: some View {
        HStack {
            Menu("Move Selection") {
                ForEach(EndpointSelectionMotion.allCases) { motion in
                    Button(motion.rawValue) { controller.move(motion, extending: extending) }
                }
            }
            Toggle("Extend", isOn: $extending).fixedSize()
                .help("Extend the selection, or turn off to move its starting point.")
            Spacer(minLength: 0)
            Button("Select All") { controller.selectAll() }
            Button("Copy") { controller.copy() }
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Captured text selection controls")
    }
}

struct EndpointTextToolsSheet: View {
    enum Mode { case history, prompt }
    let mode: Mode
    let snapshot: HerdrEndpointSnapshot
    let surface: HerdrEndpointSurface?
    let currentBootID: String?
    let result: EndpointTextResult?
    let busy: Bool
    let submit: (EndpointTextRequest) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var query = ""
    @State private var search = CapturedTextSearch(text: "", query: "")
    @State private var matchIndex = 0
    @State private var pendingID: UUID?
    @State private var message: String?
    @State private var truncated = false
    @State private var export = false
    @State private var reviewSubmission = false
    @StateObject private var clipboard = EndpointClipboard()
    @StateObject private var selectionController = EndpointSelectionController()

    private var paneID: String { snapshot.focusedPaneID ?? "" }
    private var selection: NSRange? { search.ranges.indices.contains(matchIndex) ? search.ranges[matchIndex] : nil }
    private var unavailable: Bool { busy || pendingID != nil || currentBootID != snapshot.bootID || paneID.isEmpty }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pane: \(paneID)").font(.caption).foregroundStyle(.secondary)
                if mode == .history { historyControls }
                else {
                    Text("Herdr submits this multiline prompt once. Blocked agents require interactive input.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $text).font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Agent prompt")
                        .disabled(pendingID != nil)
                    Button("Submit Prompt") { sendPrompt() }.disabled(unavailable || text.isEmpty || reviewSubmission)
                    if reviewSubmission {
                        Button("I Checked the Agent") { reviewSubmission = false; message = nil }
                    }
                }
                if let message { Text(message).font(.caption).textSelection(.enabled) }
                if currentBootID != snapshot.bootID { Text("The connection changed. Close this sheet and review the pane again.").foregroundStyle(.red) }
            }
            .padding()
            .navigationTitle(mode == .history ? "Terminal History" : "Send Agent Prompt")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 700, height: 650)
        #endif
        .overlay(alignment: .bottom) { EndpointClipboardNotice(clipboard: clipboard) }
        .onAppear { if mode == .history { loadHistory() } }
        .onChange(of: result) { _, value in receive(value) }
        .onChange(of: currentBootID) { _, _ in
            if mode == .prompt, pendingID != nil {
                reviewSubmission = true
                message = "Submission may have completed. Check the agent before sending again. Rai will not retry."
            }
        }
        .fileExporter(isPresented: $export, document: CapturedTextDocument(text: text), contentType: .plainText,
            defaultFilename: "\(paneID.replacingOccurrences(of: ":", with: "-"))-history.txt") { result in
                if case .failure(let error) = result { message = error.localizedDescription }
            }
    }

    private var historyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search Captured History", text: $query)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onChange(of: query) { _, _ in search = CapturedTextSearch(text: text, query: query); matchIndex = 0 }
                Button("Previous") { moveMatch(-1) }.disabled(search.ranges.isEmpty)
                Button("Next") { moveMatch(1) }.disabled(search.ranges.isEmpty)
            }
            if !query.isEmpty {
                Text("\(search.ranges.isEmpty ? 0 : matchIndex + 1) of \(search.total) matches")
                    .font(.caption).foregroundStyle(.secondary)
                if search.total > search.ranges.count { Text("Navigation shows the first \(search.ranges.count) matches.").font(.caption) }
            }
            #if os(macOS)
            SelectableHistoryText(text: text, selection: selection, clipboard: clipboard, selectionController: selectionController)
            #else
            SelectableTerminalText(text: text, selection: selection, clipboard: clipboard, selectionController: selectionController)
            #endif
            EndpointSelectionControls(controller: selectionController).disabled(text.isEmpty)
            HStack {
                Button("Reload History") { loadHistory() }.disabled(unavailable)
                Button("Export Text…") { export = true }.disabled(text.isEmpty)
                ShareLink(item: text).disabled(text.isEmpty)
            }
            if truncated { Text("Earlier history was omitted to keep this capture within the memory limit.").font(.caption) }
            Text("This capture remains unchanged while the agent writes new output.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func moveMatch(_ delta: Int) {
        guard !search.ranges.isEmpty else { return }
        matchIndex = (matchIndex + delta + search.ranges.count) % search.ranges.count
    }

    private func loadHistory() {
        do {
            guard let surface else { throw HerdrEndpointError.staleIdentity }
            send(try EndpointTextRequest.history(surface: surface, paneID: paneID))
        } catch { message = error.localizedDescription }
    }

    private func sendPrompt() { send(EndpointTextRequest(bootID: snapshot.bootID, paneID: paneID, action: .prompt(text))) }

    private func send(_ request: EndpointTextRequest) {
        guard submit(request) else { message = "The target changed or the action is unavailable. Review the pane again."; return }
        pendingID = request.id
        message = mode == .history ? "Reading history…" : "Submitting prompt…"
    }

    private func receive(_ value: EndpointTextResult?) {
        guard let value, value.requestID == pendingID else { return }
        pendingID = nil
        if let error = value.error {
            message = error
            reviewSubmission = value.outcomeUnknown
            return
        }
        if mode == .history {
            text = value.text ?? ""
            truncated = value.truncated
            search = CapturedTextSearch(text: text, query: query)
            matchIndex = 0
            message = nil
        } else { text = ""; message = "Prompt submitted." }
    }
}

#if os(macOS)
private struct SelectableHistoryText: NSViewRepresentable {
    let text: String
    let selection: NSRange?
    let clipboard: EndpointClipboard
    let selectionController: EndpointSelectionController
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let view = EndpointSelectableTextView()
        view.clipboard = clipboard
        selectionController.view = view
        view.isEditable = false
        view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        if context.coordinator.selection != selection {
            context.coordinator.selection = selection
            if let selection { view.setSelectedRange(selection); view.scrollRangeToVisible(selection) }
        }
    }
    final class Coordinator { var selection: NSRange? }
}
#endif
