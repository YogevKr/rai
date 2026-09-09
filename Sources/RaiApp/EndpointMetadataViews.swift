import RaiCore
import SwiftUI

struct EndpointMetadataRows: View {
    let record: JSONValue
    let kind: EndpointMetadataKind
    let snapshot: HerdrEndpointSnapshot
    var machine: String? = nil
    var foreground: Color = .primary
    @AppStorage("endpointMetadata") private var saved = ""

    var body: some View {
        let configuration = (try? EndpointMetadataConfiguration.decode(saved)) ?? .init()
        EndpointMetadataPreview(record: record, kind: kind, snapshot: snapshot,
                                configuration: configuration, machine: machine, foreground: foreground)
    }
}

struct EndpointMetadataPreview: View {
    let record: JSONValue
    let kind: EndpointMetadataKind
    let snapshot: HerdrEndpointSnapshot
    let configuration: EndpointMetadataConfiguration
    var machine: String? = nil
    var foreground: Color = .primary

    var body: some View {
        let rows = EndpointMetadataResolver.rows(record: record, kind: kind, snapshot: snapshot,
                                                 configuration: configuration, machine: machine)
        VStack(alignment: .leading, spacing: CGFloat(configuration[kind].rowGap) * 12) {
            ForEach(rows.indices, id: \.self) { index in
                rows[index].reduce(Text("")) { result, fragment in
                    result + Text(fragment.separator).foregroundColor(foreground)
                        + metadataText(fragment.text, style: fragment.style, foreground: foreground)
                }.lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(EndpointMetadataResolver.accessibilityLabel(record: record, rows: rows)))
    }
}

private func metadataText(_ value: String, style: EndpointMetadataStyle, foreground: Color = .primary) -> Text {
    var color = foreground
    if let hex = style.fg, let rgb = EndpointMetadataStyle.rgb(hex) {
        let red = Double((rgb >> 16) & 255) / 255
        let green = Double((rgb >> 8) & 255) / 255
        let blue = Double(rgb & 255) / 255
        color = Color(red: red, green: green, blue: blue)
    }
    var text = Text(value).foregroundColor(color.opacity(style.dim == true ? 0.5 : 1))
    if let bold = style.bold { text = text.fontWeight(bold ? .bold : .regular) }
    return text
}

struct EndpointMetadataSettings: View {
    let snapshot: HerdrEndpointSnapshot
    @Environment(\.dismiss) private var dismiss
    @AppStorage("endpointMetadata") private var saved = ""
    @State private var draft = EndpointMetadataConfiguration()
    @State private var kind = EndpointMetadataKind.workspace
    @State private var agent = ""
    @State private var error: String?

    private var rows: Binding<[[EndpointMetadataToken]]> {
        Binding(get: {
            if kind == .agent, !agent.isEmpty { return draft.agents.rowsByAgent[agent] ?? draft.agents.rows }
            return draft[kind].rows
        }, set: { value in
            if kind == .agent, !agent.isEmpty { draft.agents.rowsByAgent[agent] = value }
            else { draft[kind].rows = value }
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("These layouts apply to this app. Each token can have its own style and ordered rules.")
                    Picker("Layout", selection: $kind) {
                        Text("Workspaces").tag(EndpointMetadataKind.workspace)
                        Text("Agents").tag(EndpointMetadataKind.agent)
                    }
                    if kind == .agent { agentPicker }
                    Stepper("Row gap: \(draft[kind].rowGap)", value: Binding(
                        get: { Int(draft[kind].rowGap) },
                        set: { draft[kind].rowGap = UInt16($0) }), in: 0...65535)
                }
                Section("Preview") {
                    if let record = previewRecord {
                        EndpointMetadataPreview(record: record, kind: kind, snapshot: snapshot, configuration: draft)
                    } else { Text("No matching item is available. Token editors include a sample preview.").foregroundStyle(.secondary) }
                }
                Section("Rows") {
                    ForEach(rows.wrappedValue.indices, id: \.self) { index in
                        NavigationLink {
                            EndpointMetadataRowEditor(tokens: rows[index], kind: kind)
                        } label: {
                            VStack(alignment: .leading) {
                                Text("Row \(index + 1)")
                                Text(rows.wrappedValue[index].map(\.token).joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu { EndpointMetadataOrderMenu(items: rows, index: index) }
                    }
                    .onDelete { rows.wrappedValue.remove(atOffsets: $0) }
                    .onMove { rows.wrappedValue.move(fromOffsets: $0, toOffset: $1) }
                    Button("Add Row") { rows.wrappedValue.append([.init("workspace")]) }
                        .disabled(rows.wrappedValue.count >= 16)
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button("Restore Default Layouts") { draft = .init(); agent = ""; error = nil }
            }
            .formStyle(.grouped)
            .navigationTitle("Metadata")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
                #if os(iOS)
                ToolbarItem { EditButton() }
                #endif
            }
        }
        .onAppear {
            guard !saved.isEmpty else { return }
            do { draft = try EndpointMetadataConfiguration.decode(saved) }
            catch { self.error = error.localizedDescription }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 500, idealHeight: 660)
        #endif
    }

    private var agentPicker: some View {
        Group {
            Picker("Agent layout", selection: $agent) {
                Text("All agents").tag("")
                ForEach(EndpointMetadataLayout.canonicalAgents.filter { $0 != "muse" }, id: \.self) { Text($0).tag($0) }
            }
            if !agent.isEmpty {
                Text("Changes replace the complete layout for this agent.").font(.caption)
                Button("Use Default Agent Layout") { draft.agents.rowsByAgent.removeValue(forKey: agent) }
                    .disabled(draft.agents.rowsByAgent[agent] == nil)
            }
        }
    }

    private var previewRecord: JSONValue? {
        if kind == .workspace { return snapshot.workspaces.first }
        if agent.isEmpty { return snapshot.agents.first }
        return snapshot.agents.first { $0.objectValue?["agent"]?.stringValue == agent }
    }

    private func save() {
        do { saved = try draft.encoded(); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

private struct EndpointMetadataRowEditor: View {
    @Binding var tokens: [EndpointMetadataToken]
    let kind: EndpointMetadataKind

    var body: some View {
        List {
            ForEach(tokens.indices, id: \.self) { index in
                NavigationLink(tokens[index].token) {
                    EndpointMetadataTokenEditor(token: $tokens[index], kind: kind)
                }
                .contextMenu { EndpointMetadataOrderMenu(items: $tokens, index: index) }
            }
            .onDelete { tokens.remove(atOffsets: $0) }
            .onMove { tokens.move(fromOffsets: $0, toOffset: $1) }
            Button("Add Token") { tokens.append(.init("workspace")) }.disabled(tokens.count >= 16)
        }
        .navigationTitle("Row Tokens")
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
    }
}

private struct EndpointMetadataTokenEditor: View {
    @Binding var token: EndpointMetadataToken
    let kind: EndpointMetadataKind
    @State private var sample = "Sample"

    private var validation: String? {
        do { try token.validate(kind: kind); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        Form {
            Section("Token") {
                Picker("Built-in token", selection: Binding(
                    get: { kind.tokens.contains(token.token) ? token.token : "$" },
                    set: { token.token = $0 })) {
                    ForEach(kind.tokens, id: \.self) { Text($0).tag($0) }
                    Text("Custom token").tag("$")
                }
                if !kind.tokens.contains(token.token) {
                    TextField("Custom token, for example $model", text: $token.token)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                EndpointMetadataStyleEditor(style: $token.style)
            }
            Section("Rules — first match wins") {
                ForEach(token.rules.indices, id: \.self) { index in
                    NavigationLink("\(index + 1). \(token.rules[index].condition.label) \(token.rules[index].value)") {
                        EndpointMetadataRuleEditor(rule: $token.rules[index])
                    }
                    .contextMenu { EndpointMetadataOrderMenu(items: $token.rules, index: index) }
                }
                .onDelete { token.rules.remove(atOffsets: $0) }
                .onMove { token.rules.move(fromOffsets: $0, toOffset: $1) }
                Button("Add Rule") { token.rules.append(.init()) }
                    .disabled(token.rules.count >= 16 || ["state_icon", "git_status"].contains(token.token))
                Text("A matching rule stops evaluation, even when it has no style changes.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Section("Preview") {
                TextField("Sample value", text: $sample)
                metadataText(sample, style: token.resolvedStyle(for: sample))
                if let validation { Text(validation).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Token")
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
    }
}

private struct EndpointMetadataRuleEditor: View {
    @Binding var rule: EndpointMetadataRule

    var body: some View {
        Form {
            Picker("Condition", selection: $rule.condition) {
                ForEach(EndpointMetadataRule.Condition.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            TextField(rule.condition.numeric ? "Number" : "Text", text: $rule.value)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            if !rule.condition.numeric {
                Toggle("Ignore ASCII letter case", isOn: Binding(get: { rule.ignoreCase ?? false }, set: { rule.ignoreCase = $0 }))
            }
            EndpointMetadataStyleEditor(style: $rule.style)
            Text("Unchanged fields keep the token style. Off removes bold or dim styling.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .navigationTitle("Rule")
        .onChange(of: rule.condition) { _, value in if value.numeric { rule.ignoreCase = nil } }
    }
}

private struct EndpointMetadataStyleEditor: View {
    @Binding var style: EndpointMetadataStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Color")
            TextField("#RGB or #RRGGBB", text: Binding(
                get: { style.fg ?? "" }, set: { style.fg = $0.isEmpty ? nil : $0 }))
                .labelsHidden()
                .accessibilityLabel("Color")
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Text("Leave empty to keep the default color.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        modifierPicker("Bold", value: $style.bold)
        modifierPicker("Dim", value: $style.dim)
    }

    private func modifierPicker(_ label: String, value: Binding<Bool?>) -> some View {
        Picker(label, selection: Binding(get: { value.wrappedValue.map { $0 ? 1 : 0 } ?? -1 },
                                        set: { value.wrappedValue = $0 == -1 ? nil : $0 == 1 })) {
            Text("Unchanged").tag(-1)
            Text("On").tag(1)
            Text("Off").tag(0)
        }
    }
}

private struct EndpointMetadataOrderMenu<Item>: View {
    @Binding var items: [Item]
    let index: Int

    var body: some View {
        Button("Move Up") { items.swapAt(index, index - 1) }.disabled(index == 0)
        Button("Move Down") { items.swapAt(index, index + 1) }.disabled(index + 1 >= items.count)
        Button("Remove", role: .destructive) { items.remove(at: index) }
    }
}
