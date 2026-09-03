import SwiftUI
import UIKit
import UserNotifications
import RaiCore

enum PhoneNotificationAction {
    static let category = "agent-attention"
    static let decisionCategory = "permission-decision"
    static let approve = "Approve"
    static let deny = "Deny"
    static let reply = "Reply"
}

enum PhoneNotificationRegistrationPolicy {
    static func shouldRegister(authorizationGranted: Bool) -> Bool {
        authorizationGranted
    }
}

enum PhoneNotificationResponsePlan: Equatable {
    case decide(RemotePermissionDecision, requestID: String)
    case input([UInt8])
    case open

    static func make(
        actionIdentifier: String,
        requestID: String?,
        replyText: String? = nil
    ) -> PhoneNotificationResponsePlan {
        switch actionIdentifier {
        case PhoneNotificationAction.approve:
            if let requestID { return .decide(.allow, requestID: requestID) }
            return .input([0x0D])
        case PhoneNotificationAction.deny:
            if let requestID { return .decide(.deny, requestID: requestID) }
            return .input([0x1B])
        case PhoneNotificationAction.reply:
            guard let replyText else { return .open }
            return .input(Array(replyText.utf8) + [0x0D])
        default:
            return .open
        }
    }
}

final class IOSAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var appModel: AppModel? {
        didSet {
            Task { @MainActor in
                appModel?.updateDecisionAvailability(
                    notificationAuthorized: notificationAuthorizationGranted,
                    isForeground: appIsForeground
                )
            }
            if let deviceToken {
                Task { @MainActor in appModel?.setPushDeviceToken(deviceToken) }
            }
            if let pendingPaneID {
                Task { @MainActor in
                    appModel?.pendingOpenPaneID = pendingPaneID
                    self.pendingPaneID = nil
                }
            }
            if pendingTriage {
                Task { @MainActor in
                    appModel?.openTriage()
                    self.pendingTriage = false
                }
            }
        }
    }

    private var deviceToken: String?
    private var pendingPaneID: String?
    private var pendingTriage = false
    private var notificationAuthorizationGranted = false
    private var appIsForeground = false
    private lazy var retractionHandler = PhoneNotificationRetractionHandler(
        center: SystemPhoneNotificationCenter(),
        readStateStore: UserDefaultsPhoneNotificationReadStateStore()
    )

    func markDeliveredNotificationsSeen() {
        Task { await retractionHandler.markDeliveredNotificationsSeen() }
    }

    func updateScenePhase(_ phase: ScenePhase) {
        appIsForeground = phase == .active
        Task { @MainActor in
            appModel?.updateDecisionAvailability(
                notificationAuthorized: notificationAuthorizationGranted,
                isForeground: appIsForeground
            )
        }
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: PhoneNotificationAction.decisionCategory,
                actions: [
                    UNNotificationAction(
                        identifier: PhoneNotificationAction.approve,
                        title: "Approve",
                        options: [.authenticationRequired]
                    ),
                    UNNotificationAction(
                        identifier: PhoneNotificationAction.deny,
                        title: "Deny",
                        options: [.authenticationRequired, .destructive]
                    ),
                ],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: PhoneNotificationAction.category,
                actions: [
                    UNNotificationAction(
                        identifier: PhoneNotificationAction.approve,
                        title: "Approve",
                        options: [.authenticationRequired]
                    ),
                    UNNotificationAction(
                        identifier: PhoneNotificationAction.deny,
                        title: "Deny",
                        options: [.authenticationRequired, .destructive]
                    ),
                    UNTextInputNotificationAction(
                        identifier: PhoneNotificationAction.reply,
                        title: "Reply",
                        options: [.authenticationRequired],
                        textInputButtonTitle: "Send",
                        textInputPlaceholder: "Message"
                    ),
                ],
                intentIdentifiers: []
            ),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                NSLog("rai-ios: Notification authorization failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                self.notificationAuthorizationGranted = granted
                self.appModel?.updateDecisionAvailability(
                    notificationAuthorized: granted,
                    isForeground: self.appIsForeground
                )
                if PhoneNotificationRegistrationPolicy.shouldRegister(
                    authorizationGranted: granted
                ) {
                    application.registerForRemoteNotifications()
                }
            }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            let handled = await retractionHandler.handle(userInfo: userInfo)
            completionHandler(handled ? .newData : .noData)
        }
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
        let userInfo = response.notification.request.content.userInfo
        guard let paneID = userInfo["paneID"] as? String else {
            if userInfo["triage"] as? Bool == true {
                await openTriage()
            }
            return
        }
        let plan = PhoneNotificationResponsePlan.make(
            actionIdentifier: response.actionIdentifier,
            requestID: userInfo["request_id"] as? String,
            replyText: (response as? UNTextInputNotificationResponse)?.userText
        )

        switch plan {
        case let .decide(decision, requestID):
            notificationAuthorizationGranted = true
            let delivered: Bool
            if let appModel {
                appModel.updateDecisionAvailability(
                    notificationAuthorized: true,
                    isForeground: appIsForeground
                )
                delivered = await appModel.sendNotificationDecision(
                    decision,
                    requestID: requestID,
                    paneID: paneID
                )
            } else if let pairing = PairingStore().load() {
                let connection = await MainActor.run { BridgeConnection() }
                await connection.updateDecisionAvailability(
                    notificationAuthorized: true,
                    isForeground: false
                )
                delivered = await connection.connectAndDecide(
                    decision,
                    requestID: requestID,
                    paneID: paneID,
                    pairing: pairing
                )
            } else {
                delivered = false
            }
            if delivered { return }
        case let .input(bytes):
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
        case .open:
            break
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

    private func openTriage() async {
        pendingTriage = true
        await MainActor.run {
            appModel?.openTriage()
            if appModel != nil { pendingTriage = false }
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
                    if let invitation = try? PairingInvitation(urlString: url.absoluteString) {
                        appModel.pair(invitation)
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            appDelegate.updateScenePhase(phase)
            // The badge counts pushes that arrived while away; opening the
            // app is "I looked" — clear it. This must hang off scenePhase:
            // SwiftUI apps run the scene lifecycle, so UIKit never calls the
            // app delegate's applicationDidBecomeActive (the first version
            // of this fix silently did nothing).
            if phase == .active {
                appDelegate.markDeliveredNotificationsSeen()
            }
        }
    }
}
