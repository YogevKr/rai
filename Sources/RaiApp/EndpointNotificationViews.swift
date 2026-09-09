import RaiCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import AudioToolbox
#endif

struct EndpointNotificationPresentation: ViewModifier {
    let notifications: [EndpointNotification]
    @AppStorage("endpointNotificationBanners") private var banners = true
    @AppStorage("endpointNotificationSounds") private var sounds = false
    @State private var current: EndpointNotification?

    func body(content: Content) -> some View {
        content.overlay(alignment: alignment) {
            if let current {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(current.title).font(.headline)
                        if let body = current.body { Text(body).font(.callout) }
                    }.textSelection(.enabled)
                    Button { self.current = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Dismiss notification")
                }
                .padding().frame(maxWidth: 360, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(8)
                .accessibilityIdentifier("endpoint-notification")
            }
        }
        .onChange(of: notifications.last?.id) { _, _ in
            guard let latest = notifications.last else { current = nil; return }
            if latest.kind == .error || banners { current = latest }
            if sounds, latest.sound != nil { playSound() }
        }
        .task(id: current?.id) {
            guard current != nil, current?.kind != .error else { return }
            do { try await Task.sleep(for: .seconds(8)); current = nil } catch { }
        }
    }

    private var alignment: Alignment {
        switch current?.position ?? .bottomRight {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }

    private func playSound() {
        #if os(macOS)
        NSSound.beep()
        #else
        AudioServicesPlaySystemSound(1057)
        #endif
    }
}

struct EndpointNotificationSettings: View {
    let notifications: [EndpointNotification]
    @Environment(\.dismiss) private var dismiss
    @AppStorage("endpointNotificationBanners") private var banners = true
    @AppStorage("endpointNotificationSounds") private var sounds = false

    var body: some View {
        NavigationStack {
            Form {
                Section("This app") {
                    Toggle("Show notification banners", isOn: $banners)
                    Toggle("Play notification sounds", isOn: $sounds)
                    Text("Endpoint errors always appear. Notifications arrive while this workspace view is connected.")
                        .font(.caption)
                }
                Section("Recent notifications") {
                    if notifications.isEmpty { Text("No notifications in this connection.") }
                    ForEach(notifications.reversed()) { notice in
                        VStack(alignment: .leading) {
                            Text(notice.title).font(.headline)
                            if let body = notice.body { Text(body) }
                            if let agent = notice.agent { Text(agent).font(.caption).foregroundStyle(.secondary) }
                        }.textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Notifications")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 400)
        #endif
    }
}
