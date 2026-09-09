import RaiCore
import SwiftUI

struct HerdrManagementSheet: View {
    @ObservedObject var connection: BridgeConnection
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation: Confirmation?

    private struct Confirmation: Identifiable {
        let request: HerdrManagementRequest
        let target: String
        var id: String { request.id }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Target") {
                    LabeledContent("Mac", value: connection.host)
                    LabeledContent("Session", value: connection.sessionName ?? "Unavailable")
                    LabeledContent("Server", value: connection.hostCapabilities?.server?.version ?? "Unavailable")
                }
                Section {
                    ForEach(HerdrManagementAction.allCases, id: \.self) { action in
                        Button(action.title, role: action == .stopServer ? .destructive : nil) {
                            guard let identity = connection.hostCapabilities?.connectionID else { return }
                            confirmation = Confirmation(
                                request: HerdrManagementRequest(action: action, connectionID: identity),
                                target: "Mac: \(connection.host)\nSession: \(connection.sessionName ?? "Unknown")"
                            )
                        }
                        .disabled(!connection.status.isConnected || connection.herdrManagementRequest != nil
                                  || connection.hostCapabilities?.supports(action) != true)
                    }
                } footer: {
                    if connection.hostCapabilities?.operations.contains(BridgeCapability.herdrManagement) != true {
                        Text("The Mac does not offer these controls. Update Rai on the Mac and select a local Herdr session.")
                    } else {
                        Text("Live handoff requires support from the selected server. Client updates preserve compatible attachments.")
                    }
                }
                if let text = connection.herdrManagementText {
                    Section("Result") {
                        Text(text).textSelection(.enabled)
                        if connection.herdrManagementRequest != nil {
                            ProgressView("Waiting for the Mac…")
                        }
                    }
                }
            }
            .navigationTitle("Herdr Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert(item: $confirmation) { target in
                Alert(
                    title: Text(target.request.action.title),
                    message: Text("\(target.target)\n\n\(target.request.action.effects)"),
                    primaryButton: target.request.action == .stopServer
                        ? .destructive(Text("Stop Server")) { connection.manageHerdr(target.request) }
                        : .default(Text("Continue")) { connection.manageHerdr(target.request) },
                    secondaryButton: .cancel()
                )
            }
        }
    }
}
