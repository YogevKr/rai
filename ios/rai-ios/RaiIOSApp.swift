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

    static func shouldRegisterAfterRefresh(
        wasGranted: Bool,
        isGranted: Bool
    ) -> Bool {
        !wasGranted && isGranted
    }
}

protocol PhoneNotificationAuthorizationReading: Sendable {
    func readAuthorizationStatus(
        _ completion: @escaping @Sendable (UNAuthorizationStatus) -> Void
    )
}

struct SystemPhoneNotificationAuthorizationReader: PhoneNotificationAuthorizationReading {
    func readAuthorizationStatus(
        _ completion: @escaping @Sendable (UNAuthorizationStatus) -> Void
    ) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            completion(settings.authorizationStatus)
        }
    }
}

enum PhoneNotificationAuthorization {
    static func isGranted(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            true
        default:
            false
        }
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
            if let pendingComposedDraft {
                Task { @MainActor in
                    appModel?.connection.keepPendingComposedDraft(
                        pendingComposedDraft.text,
                        for: pendingComposedDraft.paneID
                    )
                    self.pendingComposedDraft = nil
                }
            }
            if let pendingPaneID {
                Task { @MainActor in
                    appModel?.pendingOpenPaneID = pendingPaneID
                    self.pendingPaneID = nil
                }
            }
            if let pendingHostPane {
                Task { @MainActor in
                    self.pendingHostPane = nil
                    guard let appModel, let pairing = appModel.pairing,
                          await appModel.connection.validateNotificationHost(pendingHostPane.connectionID, pairing: pairing) else {
                        await self.showActionError("The notification host changed. Open Machines to review the agent.")
                        return
                    }
                    await self.openPane(pendingHostPane.paneID)
                }
            }
            if let pendingMachineResource {
                Task { @MainActor in
                    appModel?.pendingOpenMachineResource = pendingMachineResource
                    self.pendingMachineResource = nil
                }
            }
            if pendingTriage {
                Task { @MainActor in
                    appModel?.openTriage()
                    self.pendingTriage = false
                }
            }
            if let pendingActionError {
                Task { @MainActor in
                    appModel?.showActionError(pendingActionError)
                    self.pendingActionError = nil
                }
            }
        }
    }

    private var deviceToken: String?
    private var pendingPaneID: String?
    private var pendingHostPane: (paneID: String, connectionID: String)?
    private var pendingMachineResource: MachineResource?
    private var pendingComposedDraft: (paneID: String, text: String)?
    private var pendingTriage = false
    private var pendingActionError: String?
    private(set) var notificationAuthorizationGranted = false
    private var appIsForeground = false
    private let notificationAuthorizationReader: any PhoneNotificationAuthorizationReading
    private let registerForRemoteNotifications: @Sendable () -> Void
    private lazy var retractionHandler = PhoneNotificationRetractionHandler(
        center: SystemPhoneNotificationCenter(),
        readStateStore: UserDefaultsPhoneNotificationReadStateStore()
    )

    override init() {
        notificationAuthorizationReader = SystemPhoneNotificationAuthorizationReader()
        registerForRemoteNotifications = {
            UIApplication.shared.registerForRemoteNotifications()
        }
        super.init()
    }

    init(
        notificationAuthorizationReader: any PhoneNotificationAuthorizationReading,
        registerForRemoteNotifications: @escaping @Sendable () -> Void = {}
    ) {
        self.notificationAuthorizationReader = notificationAuthorizationReader
        self.registerForRemoteNotifications = registerForRemoteNotifications
        super.init()
    }

    func markDeliveredNotificationsSeen() {
        Task { await retractionHandler.markDeliveredNotificationsSeen() }
    }

    func updateScenePhase(_ phase: ScenePhase) {
        appIsForeground = phase == .active
        if phase == .active {
            notificationAuthorizationReader.readAuthorizationStatus { [weak self] status in
                DispatchQueue.main.async {
                    self?.applyNotificationAuthorization(
                        PhoneNotificationAuthorization.isGranted(status)
                    )
                }
            }
            return
        }
        publishDecisionAvailability()
    }

    private func applyNotificationAuthorization(_ granted: Bool) {
        let wasGranted = notificationAuthorizationGranted
        notificationAuthorizationGranted = granted
        publishDecisionAvailability()
        if PhoneNotificationRegistrationPolicy.shouldRegisterAfterRefresh(
            wasGranted: wasGranted,
            isGranted: granted
        ) {
            registerForRemoteNotifications()
        }
    }

    private func publishDecisionAvailability() {
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
                self.applyNotificationAuthorization(granted)
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
        switch MachineNotificationRoute.decode(userInfo) {
        case .invalid:
            await showActionError("This machine notification has an invalid target. Open Machines to choose the agent.")
            return
        case .machine(let resource):
            pendingMachineResource = resource
            await MainActor.run {
                appModel?.pendingOpenMachineResource = resource
                if appModel != nil { pendingMachineResource = nil }
            }
            if response.actionIdentifier != UNNotificationDefaultActionIdentifier {
                await showActionError("Review this machine's terminal before responding. No permission response or text was sent.")
            }
            return
        case .legacy: break
        }
        guard let paneID = userInfo["paneID"] as? String else {
            if userInfo["triage"] as? Bool == true {
                await openTriage()
            }
            return
        }
        guard let expectedHost = userInfo["hostConnectionID"] as? String, !expectedHost.isEmpty else {
            await showActionError("This notification has no verified host. Open Machines to review the agent.")
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
                    paneID: paneID,
                    expectedConnectionID: expectedHost
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
                    pairing: pairing,
                    expectedConnectionID: expectedHost
                )
            } else {
                delivered = false
            }
            if delivered { return }
        case let .input(bytes):
            let delivered: Bool
            if let appModel {
                if response.actionIdentifier == PhoneNotificationAction.reply {
                    delivered = await appModel.sendNotificationReply(bytes, to: paneID, expectedConnectionID: expectedHost)
                } else {
                    delivered = await appModel.sendNotificationInput(bytes, to: paneID, expectedConnectionID: expectedHost)
                }
            } else if let pairing = PairingStore().load() {
                let connection = await MainActor.run { BridgeConnection() }
                if response.actionIdentifier == PhoneNotificationAction.reply {
                    delivered = await connection.connectAndSendComposedLine(
                        bytes, to: paneID, pairing: pairing, expectedConnectionID: expectedHost
                    )
                    if !delivered {
                        let (message, draft) = await MainActor.run {
                            (
                                connection.actionError,
                                connection.takePendingComposedDraft(for: paneID)
                            )
                        }
                        if let draft {
                            await keepPendingComposedDraft(draft, for: paneID)
                        }
                        if let message { await showActionError(message) }
                    }
                } else {
                    delivered = await connection.connectAndSendInput(
                        bytes, to: paneID, pairing: pairing, expectedConnectionID: expectedHost
                    )
                }
            } else {
                delivered = false
            }
            if delivered { return }
        case .open:
            break
        }
        if appModel == nil {
            pendingHostPane = (paneID, expectedHost)
            return
        }
        if let appModel, let pairing = appModel.pairing,
           await appModel.connection.validateNotificationHost(expectedHost, pairing: pairing) {
            await openPane(paneID)
        } else {
            await showActionError("The notification host changed. Open Machines to review the agent.")
        }
    }

    private func openPane(_ paneID: String) async {
        pendingPaneID = paneID
        await MainActor.run {
            appModel?.pendingOpenPaneID = paneID
            if appModel != nil { pendingPaneID = nil }
        }
    }

    private func keepPendingComposedDraft(_ text: String, for paneID: String) async {
        await MainActor.run {
            if let appModel {
                appModel.connection.keepPendingComposedDraft(text, for: paneID)
            } else {
                pendingComposedDraft = (paneID, text)
            }
        }
    }

    private func openTriage() async {
        pendingTriage = true
        await MainActor.run {
            appModel?.openTriage()
            if appModel != nil { pendingTriage = false }
        }
    }

    private func showActionError(_ message: String) async {
        pendingActionError = message
        await MainActor.run {
            appModel?.showActionError(message)
            if appModel != nil { pendingActionError = nil }
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
