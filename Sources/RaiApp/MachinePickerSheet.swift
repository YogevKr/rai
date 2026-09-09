import RaiCore
import SwiftUI

struct MachinePickerSheet: View {
    let state: MachineDirectoryState
    let select: (MachineEntry) -> Void
    let openAgent: (MachineAgent) -> Void
    let perform: (MachineOperation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var status = "All"
    @State private var addPresented = false
    @State private var rename: MachineEntry?
    @State private var remove: MachineEntry?
    @State private var label = ""
    @State private var target = ""
    @State private var session = "default"

    var body: some View {
        NavigationStack {
            List {
                if let error = state.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if let setup = state.setup { setupSection(setup) }
                Section("Machines") {
                    ForEach(state.entries) { entry in
                        VStack(alignment: .leading) {
                            HStack {
                                Button { select(entry); dismiss() } label: {
                                    VStack(alignment: .leading) {
                                        Text(entry.label)
                                        Text(entry.addressLabel).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.disabled(entry.health != .online || state.busy)
                                Spacer()
                                Text(entry.health.rawValue.capitalized).font(.caption)
                                machineMenu(entry)
                                    .disabled(state.busy)
                            }
                            if let error = entry.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                Section("Agents") {
                    Picker("Status", selection: $status) {
                        ForEach(["All", "working", "blocked", "idle", "done", "unknown"], id: \.self) { Text($0).tag($0) }
                    }
                    ForEach(state.entries) { entry in
                        ForEach(entry.matchingAgents(query: query, status: status)) { agent in
                            Button { openAgent(agent); dismiss() } label: {
                                VStack(alignment: .leading) {
                                    Text(agent.name)
                                    Text("\(entry.label) · \(agent.agent) · \(agent.status)").font(.caption)
                                    Text("\(entry.addressLabel) · \(agent.resource.paneID)").font(.caption).foregroundStyle(.secondary)
                                    if entry.health != .online { Text("Disconnected — saved agent state").font(.caption) }
                                }
                            }.disabled(entry.health != .online || state.busy)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search machines and agents")
            .navigationTitle("Machines")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    HStack {
                        Button("Refresh") { perform(.refresh) }.disabled(state.busy)
                        Button("Add") { label = ""; target = ""; session = "default"; addPresented = true }.disabled(state.busy)
                    }
                }
            }
            .overlay { if state.busy && state.setup == nil { ProgressView("Updating machines") } }
            .sheet(isPresented: $addPresented) { addForm }
            .alert("Rename Machine", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
                TextField("Label", text: $label)
                Button("Save") { if let id = rename?.endpoint.profileID { perform(.rename(profileID: id, label: label)) }; rename = nil }
                Button("Cancel", role: .cancel) { rename = nil }
            }
            .confirmationDialog("Remove this saved machine?", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }), titleVisibility: .visible) {
                Button("Remove", role: .destructive) { if let id = remove?.endpoint.profileID { perform(.remove(profileID: id)) }; remove = nil }
            } message: { Text("\(remove?.label ?? "Machine") will leave this list. Its remote sessions will continue running.") }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 460)
        #endif
    }

    private func setupSection(_ setup: MachineSetupState) -> some View {
        Section("Setup: \(setup.label)") {
            Text("\(setup.target) · \(setup.session)")
            Text(setup.output.isEmpty ? "Connecting to the selected SSH target…" : setup.output)
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            if let promptID = setup.promptID, !setup.finished {
                Text("Review the operation above before answering.")
                HStack {
                    Button("Yes") { perform(.answerSetup(id: setup.id, promptID: promptID, approve: true)) }
                    Button("No") { perform(.answerSetup(id: setup.id, promptID: promptID, approve: false)) }
                }
            }
            if !setup.finished { Button("Cancel Setup", role: .destructive) { perform(.cancelSetup(setup.id)) } }
        }
    }

    private func machineMenu(_ entry: MachineEntry) -> some View {
        Menu {
            Button("Reconnect") { perform(.reconnect(entry.endpoint)) }.disabled(entry.health == .disabled)
            if let id = entry.endpoint.profileID {
                Button("Rename") { label = entry.label; rename = entry }
                Button(entry.health == .disabled ? "Enable" : "Disable") {
                    perform(entry.health == .disabled ? .enable(profileID: id) : .disable(profileID: id))
                }
                Button("Remove", role: .destructive) { remove = entry }
            }
        } label: { Image(systemName: "ellipsis.circle") }
        .accessibilityLabel("Manage \(entry.label)")
    }

    private var addForm: some View {
        NavigationStack {
            Form {
                TextField("Label", text: $label)
                TextField("SSH target", text: $target)
                TextField("Herdr session", text: $session)
                Text("Adding a machine connects through SSH and prepares its Herdr server. Installation may require approval on the Mac.")
                    #if os(macOS)
                    .fixedSize(horizontal: false, vertical: true)
                    #endif
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Add Machine")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { addPresented = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add Machine") { perform(.add(target: target, label: label, session: session)); addPresented = false }
                        .disabled((try? MachineOperation.add(target: target, label: label, session: session).arguments()) == nil)
                }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 360)
        #endif
    }
}
