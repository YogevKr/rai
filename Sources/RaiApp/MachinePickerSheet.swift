import RaiCore
import SwiftUI

struct MachinePickerSheet: View {
    private let injectedState: MachineDirectoryState?
    let select: ((MachineEntry) -> Void)?
    let openAgent: ((MachineAgent) -> Void)?
    let perform: (MachineOperation) -> Void
#if os(macOS)
    @ObservedObject private var machines = MachineDirectory.shared
#endif
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var status = "All"
    @State private var addPresented = false
    @State private var rename: MachineEntry?
    @State private var remove: MachineEntry?
    @State private var label = ""
    @State private var target = ""
    @State private var session = "default"

    init(
        state: MachineDirectoryState? = nil,
        select: ((MachineEntry) -> Void)? = nil,
        openAgent: ((MachineAgent) -> Void)? = nil,
        perform: @escaping (MachineOperation) -> Void
    ) {
        injectedState = state
        self.select = select
        self.openAgent = openAgent
        self.perform = perform
    }

    private var state: MachineDirectoryState {
#if os(macOS)
        injectedState ?? machines.state
#else
        injectedState!
#endif
    }

    var body: some View {
        Group {
#if os(macOS)
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Machines").font(.title2.bold())
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(searchPrompt, text: $query)
                            .textFieldStyle(.plain)
                            .accessibilityLabel(searchPrompt)
                    }
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
                .padding(20)
                Divider()
                machineList.listStyle(.inset)
                Divider()
                HStack(spacing: 12) {
                    Button("Refresh") { perform(.refresh) }.disabled(state.busy)
                    Button("Add Machine…", action: showAddForm).disabled(state.busy)
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(20)
            }
            .frame(width: 600, height: 480)
#else
            NavigationStack {
                machineList
                    .searchable(text: $query, prompt: searchPrompt)
                    .navigationTitle("Machines")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                        ToolbarItem(placement: .primaryAction) {
                            HStack {
                                Button("Refresh") { perform(.refresh) }.disabled(state.busy)
                                Button("Add", action: showAddForm).disabled(state.busy)
                            }
                        }
                    }
            }
#endif
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

    private var searchPrompt: String { openAgent == nil ? "Search machines" : "Search machines and agents" }

    private var matchingMachines: [MachineEntry] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.entries.filter { entry in
            search.isEmpty || [entry.label, entry.addressLabel].contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    private func showAddForm() {
        label = ""; target = ""; session = "default"; addPresented = true
    }

    private var machineList: some View {
        List {
            if let error = state.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let setup = state.setup { setupSection(setup) }
            Section {
                if matchingMachines.isEmpty { Text("No matching machines").foregroundStyle(.secondary) }
                ForEach(matchingMachines) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            if let select {
                                Button { select(entry); dismiss() } label: {
                                    machineLabel(entry)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(entry.health != .online || state.busy)
                            } else {
                                machineLabel(entry)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Text(entry.health.rawValue.capitalized)
                                .font(.caption).foregroundStyle(.secondary).fixedSize()
                            machineMenu(entry)
                                .disabled(state.busy)
                        }
                        if let error = entry.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 6)
                }
            } header: {
#if os(macOS)
                if openAgent != nil { Text("Machines") }
#else
                Text("Machines")
#endif
            }
            if let openAgent {
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
                            }
                            .buttonStyle(.plain)
                            .disabled(entry.health != .online || state.busy)
                        }
                    }
                }
            }
        }
    }

    private func machineLabel(_ entry: MachineEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.endpoint.profileID == nil ? "desktopcomputer" : "network")
                .foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.label).lineLimit(1).truncationMode(.middle)
                if entry.addressLabel != entry.label {
                    Text(entry.addressLabel).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
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
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 28, height: 28)
        #endif
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
