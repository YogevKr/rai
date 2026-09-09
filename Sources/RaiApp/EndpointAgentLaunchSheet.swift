import RaiCore
import SwiftUI

struct EndpointAgentLaunchSheet: View {
    let snapshot: HerdrEndpointSnapshot
    let currentBootID: String?
    let owningViewID: UUID
    let currentViewID: UUID?
    let result: EndpointAgentLaunchResult?
    let busy: Bool
    let submit: (EndpointAgentLaunchRequest) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var kind = EndpointAgentLaunchRequest.Kind.codex
    @State private var name = "codex"
    @State private var pending: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Text("Start an agent in the selected pane. Herdr requires an available shell.")
                Text(snapshot.focusedPaneID ?? "No pane selected").font(.caption)
                Picker("Agent", selection: $kind) {
                    ForEach(EndpointAgentLaunchRequest.Kind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                TextField("Agent name", text: $name)
                Button("Start Agent") {
                    guard let paneID = snapshot.focusedPaneID else { return }
                    let request = EndpointAgentLaunchRequest(bootID: snapshot.bootID, owningViewID: owningViewID, paneID: paneID, name: name, kind: kind)
                    if submit(request) { pending = request.id }
                }.disabled(busy || pending != nil || currentBootID != snapshot.bootID || currentViewID != owningViewID || snapshot.focusedPaneID == nil || !EndpointAgentLaunchRequest.isValidName(name))
                if let pending {
                    if let result, result.requestID == pending {
                        Text(result.message).textSelection(.enabled)
                    } else { ProgressView("Starting agent…") }
                }
                Text("Review any login or folder approval in the terminal. Rai never sends an automatic approval.").font(.caption)
            }
            .formStyle(.grouped)
            .navigationTitle("Start Agent")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 430, height: 340)
        #endif
    }
}
