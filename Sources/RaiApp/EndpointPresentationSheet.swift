import RaiCore
import SwiftUI

struct EndpointPresentationSnapshot: Identifiable {
    enum Page { case commands, news }
    let id = UUID()
    let snapshot: HerdrEndpointSnapshot
    let page: Page
}

struct EndpointPresentationSheet: View {
    let captured: EndpointPresentationSnapshot
    let invoke: (EndpointCommandInvocation) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if captured.page == .commands { commands }
                else { news }
            }
            .navigationTitle(captured.page == .commands ? "Commands" : "Herdr News")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 300, minHeight: 300)
    }

    private var commands: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            let items = captured.snapshot.commands.compactMap(EndpointCommand.init)
            if items.isEmpty { Text("This view has no commands.") }
            ForEach(items.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { command in
                Button {
                    if invoke(EndpointCommandInvocation(command: command, snapshot: captured.snapshot)) { dismiss() }
                    else { error = "This command changed or is unavailable. Open Commands again." }
                } label: {
                    HStack {
                        Text(command.title)
                        Spacer()
                        Text(command.binding).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.searchable(text: $search, prompt: "Search commands")
    }

    private var news: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let snapshot = captured.snapshot
                if snapshot.releaseNotes?.objectValue == nil && snapshot.productAnnouncement?.objectValue == nil {
                    Text("This server has no news.")
                }
                newsItem(snapshot.releaseNotes, fallback: "Release Notes")
                newsItem(snapshot.productAnnouncement, fallback: "Announcement")
            }.textSelection(.enabled).padding()
        }
    }

    @ViewBuilder
    private func newsItem(_ value: JSONValue?, fallback: String) -> some View {
        if let item = value?.objectValue {
            Text(item["title"]?.stringValue ?? fallback).font(.headline)
            if let version = item["version"]?.stringValue { Text(version).font(.caption) }
            if item["preview"] == .bool(true) { Text("Preview").font(.caption) }
            if let body = item["body"]?.stringValue { Text(body) }
        }
    }
}
