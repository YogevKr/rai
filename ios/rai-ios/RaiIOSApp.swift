import SwiftUI
import UIKit
import UserNotifications

final class IOSAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private enum NotificationAction {
        static let category = "agent-attention"
        static let approve = "Approve"
        static let deny = "Deny"
        static let reply = "Reply"
    }

    weak var appModel: AppModel? {
        didSet {
            if let deviceToken {
                Task { @MainActor in appModel?.setPushDeviceToken(deviceToken) }
            }
            if let pendingPaneID {
                Task { @MainActor in
                    appModel?.pendingOpenPaneID = pendingPaneID
                    self.pendingPaneID = nil
                }
            }
        }
    }

    private var deviceToken: String?
    private var pendingPaneID: String?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: NotificationAction.category,
                actions: [
                    UNNotificationAction(
                        identifier: NotificationAction.approve,
                        title: "Approve",
                        options: [.authenticationRequired]
                    ),
                    UNNotificationAction(
                        identifier: NotificationAction.deny,
                        title: "Deny",
                        options: [.authenticationRequired, .destructive]
                    ),
                    UNTextInputNotificationAction(
                        identifier: NotificationAction.reply,
                        title: "Reply",
                        options: [.authenticationRequired],
                        textInputButtonTitle: "Send",
                        textInputPlaceholder: "Message"
                    ),
                ],
                intentIdentifiers: []
            ),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error {
                NSLog("rai-ios: Notification authorization failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        self.deviceToken = token
        Task { @MainActor in appModel?.setPushDeviceToken(token) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("rai-ios: Remote notification registration failed: \(error.localizedDescription)")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let paneID = response.notification.request.content.userInfo["paneID"] as? String else {
            return
        }
        let bytes: [UInt8]?
        switch response.actionIdentifier {
        case NotificationAction.approve:
            bytes = [0x0D]
        case NotificationAction.deny:
            bytes = [0x1B]
        case NotificationAction.reply:
            guard let response = response as? UNTextInputNotificationResponse else { return }
            bytes = Array(response.userText.utf8) + [0x0D]
        default:
            bytes = nil
        }

        if let bytes {
            let delivered: Bool
            if let appModel {
                delivered = await appModel.sendNotificationInput(bytes, to: paneID)
            } else if let pairing = PairingStore().load() {
                let connection = await MainActor.run { BridgeConnection() }
                delivered = await connection.connectAndSendInput(
                    bytes,
                    to: paneID,
                    pairing: pairing
                )
            } else {
                delivered = false
            }
            if delivered { return }
        }
        await openPane(paneID)
    }

    private func openPane(_ paneID: String) async {
        pendingPaneID = paneID
        await MainActor.run {
            appModel?.pendingOpenPaneID = paneID
            if appModel != nil { pendingPaneID = nil }
        }
    }
}

@main
struct RaiIOSApp: App {
    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .onAppear { appDelegate.appModel = appModel }
                .onOpenURL { url in
                    // Deep-link pairing: tapping (or opening) a rai://pair link
                    // pairs and connects, same path as scanning the QR.
                    if let pairing = try? Pairing(urlString: url.absoluteString) {
                        appModel.pair(pairing)
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // The badge counts pushes that arrived while away; opening the
            // app is "I looked" — clear it. This must hang off scenePhase:
            // SwiftUI apps run the scene lifecycle, so UIKit never calls the
            // app delegate's applicationDidBecomeActive (the first version
            // of this fix silently did nothing).
            if phase == .active {
                UNUserNotificationCenter.current().setBadgeCount(0)
            }
        }
    }
}
