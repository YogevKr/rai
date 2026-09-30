import RaiCore
import SwiftUI

/// Adds Herdr workspaces to the local Rai composition.
struct RaiMixedSourcePicker: View {
    @ObservedObject var controller: RaiMixedController
    @ObservedObject private var machines = MachineDirectory.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose a Herdr workspace. Rai will add its panes to the sidebar.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }

                ForEach(machines.state.entries) { entry in
                    Section(entry.label) {
                        let workspaces = controller.workspaces(for: entry.endpoint)
                        if workspaces.isEmpty {
                            if let error = controller.sessions[entry.endpoint]?.error {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(entry.health == .online ? "No workspaces found" : "Connecting…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(workspaces) { workspace in
                            let added = controller.model.composition.spaces.contains {
                                $0.source == workspace.reference
                            }
                            HStack {
                                Button {
                                    controller.addWorkspace(workspace, endpoint: entry.endpoint)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(workspace.label)
                                        Text(entry.addressLabel)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(added)
                                Spacer()
                                if added {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                if controller.selectedTabID != nil {
                                    Button {
                                        controller.addPanesToSelectedTab(workspace, endpoint: entry.endpoint)
                                    } label: {
                                        Image(systemName: "rectangle.stack.badge.plus")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Add panes to the selected Rai tab")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Herdr workspace")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { controller.sourcePickerPresented = false }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }
}
