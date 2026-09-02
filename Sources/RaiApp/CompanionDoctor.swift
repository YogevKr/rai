import Foundation

enum DoctorSeverity: Int, Equatable, Sendable {
    case green
    case amber
    case red
}

struct DoctorFinding: Identifiable, Equatable, Sendable {
    let id: String
    let severity: DoctorSeverity
    let title: String
    let detail: String
    let fix: String
}

struct CompanionDoctorState: Equatable, Sendable {
    let bridgeEnabled: Bool
    let bridgeListening: Bool
    let bonjourAdvertised: Bool
    let bridgePort: UInt16
    let tailscaleState: TailscaleServeState
    let tailscaleURL: String?
    let apnsKeyState: APNsKeyReadState
    let apnsEnvironment: String
    let registeredDeviceCount: Int
    let presenceGateEnabled: Bool
    let presenceGateIsAway: Bool
    let pendingPushCount: Int
    let lastPushResult: String?
    let lastPushSucceeded: Bool?
}

enum CompanionDoctor {
    static func findings(for state: CompanionDoctorState) -> [DoctorFinding] {
        [
            bridgeFinding(state),
            tailscaleFinding(state),
            keyFinding(state),
            environmentFinding(state),
            devicesFinding(state),
            presenceFinding(state),
            lastPushFinding(state),
        ]
    }

    private static func bridgeFinding(_ state: CompanionDoctorState) -> DoctorFinding {
        if state.bridgeListening && state.bonjourAdvertised {
            return .init(
                id: "bridge", severity: .green, title: "Bridge listening",
                detail: "Port \(state.bridgePort); Bonjour _rai._tcp advertised.",
                fix: "No action needed."
            )
        }
        if !state.bridgeEnabled {
            return .init(
                id: "bridge", severity: .amber, title: "Bridge disabled",
                detail: "Port \(state.bridgePort) is not listening.",
                fix: "Enable Allow iPhone connections."
            )
        }
        return .init(
            id: "bridge", severity: .red, title: "Bridge not ready",
            detail: "Port \(state.bridgePort) or Bonjour is unavailable.",
            fix: "Disable and enable the companion bridge, then check the port."
        )
    }

    private static func tailscaleFinding(_ state: CompanionDoctorState) -> DoctorFinding {
        switch state.tailscaleState {
        case let .active(host):
            return .init(
                id: "tailscale", severity: .green, title: "Tailscale Serve active",
                detail: state.tailscaleURL ?? "wss://\(host)",
                fix: "No action needed."
            )
        case let .failed(message):
            return .init(
                id: "tailscale", severity: .red, title: "Tailscale Serve failed",
                detail: message,
                fix: "Free port 8443, then restart the companion bridge."
            )
        case .checking:
            return .init(
                id: "tailscale", severity: .amber, title: "Tailscale Serve checking",
                detail: "rai is checking Tailscale Serve.",
                fix: "Wait for the check to finish."
            )
        case .unavailable:
            return .init(
                id: "tailscale", severity: .amber, title: "Tailscale Serve unavailable",
                detail: "No Tailscale URL is available.",
                fix: "Install Tailscale, sign in, and restart the companion bridge."
            )
        case .stopped:
            return .init(
                id: "tailscale", severity: .amber, title: "Tailscale Serve stopped",
                detail: "No Tailscale URL is active.",
                fix: "Enable the companion bridge to start Tailscale Serve."
            )
        }
    }

    private static func keyFinding(_ state: CompanionDoctorState) -> DoctorFinding {
        switch state.apnsKeyState {
        case .readable:
            return .init(
                id: "apns-key", severity: .green, title: "APNs key readable",
                detail: "The stored APNs key is valid PEM.",
                fix: "No action needed."
            )
        case .missing:
            return .init(
                id: "apns-key", severity: .amber, title: "APNs key missing",
                detail: "rai has no stored APNs auth key.",
                fix: "Paste and save an APNs .p8 key."
            )
        case .unreadable:
            return .init(
                id: "apns-key", severity: .red, title: "APNs key unreadable",
                detail: "The stored key is empty, denied, or invalid PEM.",
                fix: "Save the APNs .p8 key again."
            )
        }
    }

    private static func environmentFinding(_ state: CompanionDoctorState) -> DoctorFinding {
        let valid = state.apnsEnvironment == "sandbox" || state.apnsEnvironment == "production"
        return .init(
            id: "apns-environment",
            severity: valid ? .green : .red,
            title: "APNs environment",
            detail: state.apnsEnvironment.capitalized,
            fix: valid ? "No action needed." : "Select Sandbox or Production."
        )
    }

    private static func devicesFinding(_ state: CompanionDoctorState) -> DoctorFinding {
        let count = state.registeredDeviceCount
        return .init(
            id: "devices",
            severity: count > 0 ? .green : .amber,
            title: "Registered devices",
            detail: "\(count) device\(count == 1 ? "" : "s") registered.",
            fix: count > 0 ? "No action needed." : "Open the paired iPhone app once."
        )
    }

    private static func presenceFinding(_ state: CompanionDoctorState) -> DoctorFinding {
        let mode: String
        if !state.presenceGateEnabled {
            mode = "Disabled; pushes send after the burst window."
        } else if state.presenceGateIsAway {
            mode = "Away; \(state.pendingPushCount) push event(s) pending."
        } else {
            mode = "At Mac; \(state.pendingPushCount) push event(s) held."
        }
        return .init(
            id: "presence",
            severity: state.presenceGateEnabled ? .green : .amber,
            title: "Presence gate",
            detail: mode,
            fix: state.presenceGateEnabled
                ? "No action needed."
                : "Enable Hold phone pushes while you're at this Mac."
        )
    }

    private static func lastPushFinding(_ state: CompanionDoctorState) -> DoctorFinding {
        guard let result = state.lastPushResult else {
            return .init(
                id: "last-push", severity: .amber, title: "Last push result",
                detail: "No push has run in this app session.",
                fix: "Use Send test push."
            )
        }
        return .init(
            id: "last-push",
            severity: state.lastPushSucceeded == true ? .green : .red,
            title: "Last push result",
            detail: result,
            fix: state.lastPushSucceeded == true
                ? "No action needed."
                : "Check the APNs key, environment, bundle ID, and device token."
        )
    }
}
