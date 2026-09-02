import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Group {
            if appModel.pairing == nil, appModel.pendingPairing == nil {
                PairingView()
            } else {
                MonitorView(appModel: appModel, connection: appModel.connection) {
                    appModel.forgetPairing()
                }
            }
        }
    }
}
