import RaiCore
import SwiftUI

/// Shared native presentation; the iOS project includes this source directly.
struct EndpointScrollOverlay: View {
    let surface: HerdrEndpointSurface?
    let activity: [String: UInt64]

    var body: some View {
        GeometryReader { proxy in
            if let surface, surface.popup == nil {
                ForEach(surface.panes, id: \.paneID) { pane in
                    if let thumb = EndpointScroll.thumb(pane: pane, grid: surface.grid) {
                        EndpointScrollThumb(activity: activity[pane.paneID])
                            .frame(width: 5, height: max(8, thumb.height * proxy.size.height))
                            .offset(x: max(0, thumb.minX * proxy.size.width - 7), y: thumb.minY * proxy.size.height)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct EndpointScrollThumb: View {
    let activity: UInt64?
    @State private var visible = false

    var body: some View {
        Capsule().fill(.primary.opacity(0.65))
            .opacity(visible ? 1 : 0)
            .task(id: activity) {
                guard activity != nil else { visible = false; return }
                visible = true
                do { try await Task.sleep(for: .milliseconds(700)) }
                catch { return }
                visible = false
            }
    }
}
