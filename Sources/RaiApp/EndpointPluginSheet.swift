import RaiCore
import SwiftUI

struct EndpointPluginSheet: View {
    let snapshot: HerdrEndpointSnapshot
    let surface: HerdrEndpointSurface?
    let result: EndpointPluginResult?
    let busy: Bool
    let methods: Set<String>
    let submit: (EndpointPluginRequest) -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var page = "Plugins"
    @State private var plugins: [EndpointInstalledPlugin] = []
    @State private var integrations: [JSONValue] = []
    @State private var pending: EndpointPluginRequest?
    @State private var message: String?
    @State private var source = ""
    @State private var reference = ""
    @State private var preview: JSONValue?
    @State private var removal: EndpointInstalledPlugin?
    @State private var label = "My agents"
    @State private var status = ""
    @State private var agent = ""
    @State private var token = ""
    @State private var tokenValue = ""
    @State private var currentWorkspace = false
    @State private var sort = AgentViewBuiltinSortField.attention
    @State private var descending = false
    @State private var fallbackURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Page", selection: $page) {
                    ForEach(["Plugins", "Integrations", "Links", "Agent View"], id: \.self) { Text($0).tag($0) }
                }
                if let message { Text(message).textSelection(.enabled) }
                if busy || pending != nil { ProgressView("Waiting for host…") }
                Group {
                    switch page {
                    case "Plugins": pluginList
                    case "Integrations": integrationList
                    case "Links": links
                    default: agentView
                    }
                }.disabled(busy || pending != nil)
            }
            .formStyle(.grouped)
            .navigationTitle("Plugins and Views")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { refresh() }
        .onDisappear { cancelReview() }
        .onChange(of: page) { _, _ in refresh() }
        .onChange(of: result?.requestID) { _, _ in receive() }
        .confirmationDialog("Remove \(removal?.name ?? "plugin")?", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            if let removal {
                Button("Unlink Plugin", role: .destructive) { send(.unlink(removal.id)); self.removal = nil }
                if removal.source?.objectValue?["kind"]?.stringValue == "github" {
                    Button("Uninstall Managed Files", role: .destructive) { send(.uninstall(removal.id)); self.removal = nil }
                }
            }
        } message: { Text("Unlink removes the registration. Uninstall also removes managed plugin files on the selected host.") }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 520)
        #endif
    }

    private var pluginList: some View {
        Group {
            Section("Installed plugins") {
                Button("Refresh Plugins") { send(.list) }
                if plugins.isEmpty { Text("No installed plugins loaded.") }
                ForEach(plugins) { plugin in
                    DisclosureGroup {
                        if let description = plugin.description { Text(description) }
                        pluginDetails(plugin)
                        pluginPanes(plugin)
                        Button(plugin.enabled ? "Disable" : "Enable") { send(plugin.enabled ? .disable(plugin.id) : .enable(plugin.id)) }
                        Button("Remove", role: .destructive) { removal = plugin }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(plugin.name + " " + plugin.version)
                            Text(plugin.enabled ? "Enabled" : "Disabled").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Install from GitHub") {
                TextField("Owner/repository or owner/repository/subdirectory", text: $source)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                TextField("Reference (optional)", text: $reference)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                Button("Review Install") { send(.prepareInstall(source: source, reference: reference)) }
                    .disabled(source.isEmpty)
                if let preview = preview?.objectValue {
                    Text(preview["output"]?.stringValue ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if preview["can_confirm"] == .bool(true), let rawID = preview["preview_id"]?.stringValue, let id = UUID(uuidString: rawID) {
                        Button("Install Reviewed Commit") { send(.confirmInstall(id)); self.preview = nil }
                        Button("Cancel Install") { send(.cancelInstall(id)); self.preview = nil }
                    }
                }
            }
        }
    }

    private func pluginDetails(_ plugin: EndpointInstalledPlugin) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(["warnings", "build", "startup", "actions", "events", "link_handlers"], id: \.self) { field in
                if case .array(let entries) = plugin.details[field], !entries.isEmpty {
                    Text(field.replacingOccurrences(of: "_", with: " ").capitalized).font(.headline)
                    ForEach(entries.indices, id: \.self) { index in
                        let entry = entries[index]
                        Text(describe(entry)).font(.caption).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func pluginPanes(_ plugin: EndpointInstalledPlugin) -> some View {
        Group {
            if !plugin.panes.isEmpty {
                Text("Panes").font(.headline)
                ForEach(plugin.panes) { pane in
                    Button("Open " + pane.title) {
                        if let invocation = EndpointPluginPaneInvocation(plugin: plugin, pane: pane, snapshot: snapshot) {
                            send(.openPane(invocation))
                        }
                    }
                    .disabled(!plugin.enabled || !methods.contains("plugin.pane.open") || snapshot.focusedPaneID == nil)
                }
                if !methods.contains("plugin.pane.open") {
                    Text("This Herdr version cannot open plugin panes in this view.").font(.caption).foregroundStyle(.secondary)
                } else if !plugin.enabled {
                    Text("Enable this plugin to open its panes.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var integrationList: some View {
        Section("Agent integrations") {
            Button("Refresh Integrations") { send(.integrations) }.disabled(!methods.contains("integration.list"))
            ForEach(integrations.indices, id: \.self) { index in
                let item = integrations[index].objectValue ?? [:]
                if let target = item["target"]?.stringValue {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item["label"]?.stringValue ?? target)
                            Text(item["state"]?.stringValue ?? "Unknown").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Install or Update") { send(.installIntegration(target)) }
                            .disabled(item["available"] != .bool(true) || !methods.contains("integration.install"))
                    }
                }
            }
        }
    }

    private var links: some View {
        Section("Links in the visible panes") {
            let links = surface.map(EndpointPluginLinkInvocation.links) ?? []
            if links.isEmpty { Text("No links in this captured view.") }
            ForEach(links) { link in
                Button { send(.activateLink(link)) } label: {
                    VStack(alignment: .leading) {
                        Text(link.url).textSelection(.enabled)
                        Text(link.paneID).font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(!methods.contains("pane.link.activate"))
            }
            if let fallbackURL {
                Text("No plugin handled this web link.")
                Button("Open Web Link") { openURL(fallbackURL) }
            }
        }
    }

    private var agentView: some View {
        Section("Filtered agent view") {
            if let active = snapshot.agentViewLabel { Text("Active view: \(active)") }
            TextField("View label", text: $label)
            Picker("Status", selection: $status) {
                Text("Any status").tag("")
                ForEach(AgentStatus.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
            }
            TextField("Agent ID (optional)", text: $agent)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Toggle("Current workspace only", isOn: $currentWorkspace)
            TextField("Custom token name (optional)", text: $token)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            TextField("Token equals (empty checks existence)", text: $tokenValue)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Picker("Sort", selection: $sort) {
                ForEach([AgentViewBuiltinSortField.attention, .status, .stateChangeSequence, .workspaceOrder, .tabOrder, .paneOrder], id: \.rawValue) {
                    Text($0.rawValue.replacingOccurrences(of: "_", with: " ").capitalized).tag($0)
                }
            }
            Toggle("Descending", isOn: $descending)
            Button("Apply Agent View") { applyAgentView() }
            Button("Clear Agent View") { send(.clearAgentView) }
            Text("This changes Herdr's agent view for this server. All conditions must match.").font(.caption)
        }
    }

    private func applyAgentView() {
        var filters: [AgentViewFilter] = []
        if !status.isEmpty { filters.append(.equal(field: .builtin(.status), value: .string(status))) }
        if !agent.isEmpty { filters.append(.equal(field: .builtin(.agent), value: .string(agent))) }
        if currentWorkspace { filters.append(.equal(field: .builtin(.workspaceID), value: .context(.currentWorkspaceID))) }
        if !token.isEmpty {
            filters.append(tokenValue.isEmpty ? .exists(.token(token)) : .equal(field: .token(token), value: .string(tokenValue)))
        }
        let spec = AgentViewSetParams(source: "rai.native", label: label, filter: filters.isEmpty ? nil : .all(filters),
                                     sort: [.init(field: .builtin(sort), order: descending ? .descending : .ascending)])
        send(.setAgentView(spec))
    }

    private func cancelReview() {
        let id: UUID?
        if let raw = preview?.objectValue?["preview_id"]?.stringValue { id = UUID(uuidString: raw) }
        else if let pending, case .prepareInstall = pending.operation { id = pending.id }
        else { id = nil }
        if let id { _ = submit(.init(bootID: snapshot.bootID, operation: .cancelInstall(id))) }
    }

    private func refresh() {
        guard pending == nil else { return }
        if page == "Plugins" { send(.list) }
        if page == "Integrations", methods.contains("integration.list") { send(.integrations) }
    }

    private func send(_ operation: EndpointPluginOperation, preservingMessage: Bool = false) {
        let request = EndpointPluginRequest(bootID: snapshot.bootID, operation: operation)
        if submit(request) { pending = request; if !preservingMessage { message = nil }; fallbackURL = nil }
        else { message = "The view changed or is busy. Open this sheet again." }
    }

    private func receive() {
        guard let result, let pending, result.requestID == pending.id else { return }
        self.pending = nil
        if let error = result.error { message = error; return }
        guard let value = result.value else { message = "The host returned no result."; return }
        do {
            switch pending.operation {
            case .list: plugins = try EndpointInstalledPlugin.list(value)
            case .integrations:
                guard case .array(let items) = value.objectValue?["integrations"] else { throw HerdrEndpointError.malformed }
                integrations = items
            case .prepareInstall: preview = value
            case .openPane: dismiss()
            case .activateLink:
                if value.objectValue?["handled"] == .bool(true) { message = "The plugin handled the link." }
                else if let raw = value.objectValue?["url"]?.stringValue, let url = URL(string: raw),
                        ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil { fallbackURL = url }
                else { message = "No plugin handled this link." }
            default:
                message = value.objectValue?["output"]?.stringValue ?? "The host completed the request."
                if page == "Plugins" { send(.list, preservingMessage: true) }
            }
        } catch { message = error.localizedDescription }
    }

    private func describe(_ value: JSONValue) -> String {
        if let text = value.stringValue { return text }
        if let object = value.objectValue {
            for key in ["title", "id", "name"] {
                if let text = object[key]?.stringValue { return text }
            }
        }
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
