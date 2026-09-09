import RaiCore
import SwiftUI

struct EndpointWorktreesSheet: View {
    let snapshot: HerdrEndpointSnapshot
    let currentBootID: String?
    let result: EndpointWorktreeResult?
    let busy: Bool
    let methods: Set<String>
    let submit: (EndpointWorktreeRequest) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var workspaceID = ""
    @State private var branch = ""
    @State private var base = ""
    @State private var path = ""
    @State private var label = ""
    @State private var trust = false
    @State private var worktrees: [HerdrWorktree] = []
    @State private var pendingID: UUID?
    @State private var status: String?
    @State private var removal: HerdrWorktree?
    @State private var force = false

    private var unavailable: Bool { busy || currentBootID != snapshot.bootID || workspaceID.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("Target") {
                    Picker("Workspace", selection: $workspaceID) {
                        Text("Select Workspace").tag("")
                        ForEach(snapshot.workspaces.indices, id: \.self) { index in
                            let workspace = snapshot.workspaces[index].objectValue ?? [:]
                            if let id = workspace["workspace_id"]?.stringValue {
                                Text("\(workspace["label"]?.stringValue ?? "Workspace") · \(id)").tag(id)
                            }
                        }
                    }.disabled(busy)
                    Text("Server: \(snapshot.bootID)").font(.caption).textSelection(.enabled)
                    Toggle("Trust Repository for Next Action", isOn: $trust)
                        .disabled(unavailable)
                    Text("Trust applies to one action. Creation and opening select the worktree in this view.")
                        .font(.caption).foregroundStyle(.secondary)
                    if currentBootID != snapshot.bootID {
                        Text("The server changed. Close this sheet and open it again.").foregroundStyle(.red)
                    }
                }
                Section("Worktrees") {
                    Button("Load Worktrees") { send(.list(workspaceID: workspaceID, trust: trust)) }
                        .disabled(unavailable || !methods.contains("worktree.list"))
                    ForEach(worktrees) { worktree in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(worktree.label).font(.headline)
                            Text(worktree.path).font(.caption).textSelection(.enabled)
                            if let branch = worktree.branch { Text(branch).font(.caption) }
                            HStack {
                                Button("Open") { send(.open(workspaceID: workspaceID, path: worktree.path, trust: trust)) }
                                    .disabled(unavailable || worktree.isBare || !methods.contains("worktree.open"))
                                if worktree.isLinkedWorktree, worktree.openWorkspaceID != nil {
                                    Button("Remove…", role: .destructive) { removal = worktree; force = false }
                                        .disabled(unavailable || !methods.contains("worktree.remove"))
                                }
                            }
                            if worktree.isLinkedWorktree && worktree.openWorkspaceID == nil {
                                Text("Open this worktree before removal.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Create Worktree") {
                    TextField("New Branch", text: $branch)
                    TextField("Base Branch (optional)", text: $base)
                    TextField("Absolute Path (optional)", text: $path)
                    TextField("Label (optional)", text: $label)
                    Button("Create Worktree") {
                        send(.create(workspaceID: workspaceID, branch: branch.trimmingCharacters(in: .whitespaces),
                            base: base, path: path, label: label, trust: trust))
                    }.disabled(unavailable || branch.trimmingCharacters(in: .whitespaces).isEmpty || !methods.contains("worktree.create"))
                }
                if let status { Section("Result") { Text(status).textSelection(.enabled) } }
            }
            .formStyle(.grouped)
            .navigationTitle("Worktrees")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 620, height: 720)
        #endif
        .onAppear { workspaceID = snapshot.focusedWorkspaceID ?? "" }
        .onChange(of: workspaceID) { _, _ in worktrees = []; trust = false; pendingID = nil; status = nil }
        .onChange(of: result) { _, result in receive(result) }
        .sheet(item: $removal) { worktree in
            NavigationStack {
                Form {
                    Text("Remove \(worktree.label)?").font(.headline)
                    Text(worktree.path).textSelection(.enabled)
                    Text("This removes the worktree directory and closes its workspace.")
                    Toggle("Force Removal of Uncommitted Changes", isOn: $force)
                    Text("Force removal can delete uncommitted files.").font(.caption).foregroundStyle(.secondary)
                }
                .navigationTitle("Remove Worktree")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { removal = nil; force = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Remove", role: .destructive) {
                            guard let id = worktree.openWorkspaceID else { return }
                            removal = nil
                            send(.remove(workspaceID: id, force: force, trust: trust))
                        }.disabled(unavailable)
                    }
                }
            }
            #if os(macOS)
            .frame(width: 480, height: 300)
            #endif
        }
    }

    private func send(_ operation: EndpointWorktreeOperation) {
        let request = EndpointWorktreeRequest(bootID: snapshot.bootID, operation: operation)
        guard submit(request) else {
            status = "The target changed or the action is unavailable. Reload this sheet."
            return
        }
        trust = false
        pendingID = request.id
        status = "Working…"
    }

    private func receive(_ result: EndpointWorktreeResult?) {
        guard let result, result.request.id == pendingID else { return }
        pendingID = nil
        if let error = result.error { status = error; return }
        switch result.request.operation {
        case .list:
            worktrees = result.worktrees
            status = worktrees.isEmpty ? "No worktrees found." : "Loaded \(worktrees.count) worktrees."
        case .create: status = "Worktree created. Load worktrees to refresh the list."
        case .open: status = "Worktree opened. Load worktrees to refresh the list."
        case .remove:
            worktrees = []
            status = "Worktree removed. Load worktrees to refresh the list."
        }
    }
}
