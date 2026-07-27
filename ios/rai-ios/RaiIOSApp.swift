import SwiftUI

@main
struct RaiIOSApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .onOpenURL { url in
                    // Deep-link pairing: tapping (or opening) a rai://pair link
                    // pairs and connects, same path as scanning the QR.
                    if let pairing = try? Pairing(urlString: url.absoluteString) {
                        try? appModel.pair(pairing)
                    }
                }
        }
    }
}
