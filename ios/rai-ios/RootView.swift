import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        RootContent(appModel: appModel, connection: appModel.connection)
    }
}

private struct RootContent: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var connection: BridgeConnection

    var body: some View {
        Group {
            if appModel.pairing == nil {
                PairingView()
            } else {
                MonitorView(appModel: appModel, connection: connection) {
                    appModel.forgetPairing()
                }
            }
        }
    }
}
