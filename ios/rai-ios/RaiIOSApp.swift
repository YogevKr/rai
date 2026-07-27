import SwiftUI
import UIKit
import UserNotifications

final class IOSAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
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
        pendingPaneID = paneID
        await MainActor.run {
            appModel?.pendingOpenPaneID = paneID
            if appModel != nil {
                pendingPaneID = nil
            }
        }
    }
}

@main
struct RaiIOSApp: App {
    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()

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
    }
}
