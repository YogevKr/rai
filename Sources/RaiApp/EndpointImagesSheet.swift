import RaiCore
import SwiftUI

struct EndpointImageSnapshot: Identifiable {
    let id = UUID()
    let scene: EndpointGraphicsScene?
}

/// Capture image ownership when the sheet opens, like captured text selection.
struct EndpointImagesSheet: View {
    let scene: EndpointGraphicsScene?
    @Environment(\.dismiss) private var dismiss
    @State private var images: [EndpointGraphicsKey: CGImage] = [:]

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 16) {
                    if let scene {
                        ForEach(scene.assets.indices, id: \.self) { index in
                            let asset = scene.assets[index]
                            Text(label(asset.key)).font(.headline).textSelection(.enabled)
                            if let image = images[asset.key] {
                                Image(decorative: image, scale: 1)
                                    .accessibilityLabel(label(asset.key))
                            } else {
                                Text("Image unavailable.").foregroundStyle(.secondary)
                            }
                        }
                        let missing = Set(scene.placements.map(\.asset)).subtracting(scene.assets.map(\.key)).count
                        if missing > 0 { Text("Some images exceed display limits or are unavailable.") }
                        if scene.placements.isEmpty { Text("No images in this view.") }
                    }
                }.padding()
            }
            .navigationTitle("Images")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 300, minHeight: 300)
        .task {
            for asset in scene?.assets ?? [] { images[asset.key] = EndpointGraphicsEncoder.image(asset) }
        }
    }

    private func label(_ key: EndpointGraphicsKey) -> String {
        switch key.source {
        case .pane(let pane, let image): return "\(pane) · Image \(image) · \(key.width) × \(key.height)"
        case .popup(let popup, let image): return "\(popup) · Image \(image)"
        case .layer(let pane, let layer): return "\(pane) · \(layer)"
        }
    }
}
