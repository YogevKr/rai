import XCTest

@testable import RaiApp

final class CompanionDoctorTests: XCTestCase {
    func testHealthyInjectedStateProducesGreenFindings() {
        let findings = CompanionDoctor.findings(for: state())

        XCTAssertEqual(findings.count, 8)
        XCTAssertTrue(findings.allSatisfy { $0.severity == .green })
        XCTAssertEqual(findings.first { $0.id == "bridge" }?.detail,
                       "Port 47837; Bonjour _rai._tcp advertised.")
    }

    func testFailuresNameTheirFixes() {
        let findings = CompanionDoctor.findings(for: state(
            bridgeListening: false,
            bonjourAdvertised: false,
            tailscaleState: .failed(message: "Port conflict"),
            apnsKeyState: .unreadable,
            deviceCount: 0,
            lastPushResult: "400 BadDeviceToken",
            lastPushSucceeded: false
        ))

        XCTAssertEqual(findings.first { $0.id == "bridge" }?.severity, .red)
        XCTAssertEqual(findings.first { $0.id == "tailscale" }?.severity, .red)
        XCTAssertTrue(findings.first { $0.id == "tailscale" }?.fix.contains("8443") == true)
        XCTAssertEqual(findings.first { $0.id == "apns-key" }?.severity, .red)
        XCTAssertTrue(findings.first { $0.id == "last-push" }?.fix.contains("bundle ID") == true)
    }

    private func state(
        bridgeListening: Bool = true,
        bonjourAdvertised: Bool = true,
        tailscaleState: TailscaleServeState = .active(host: "mac.example.ts.net"),
        apnsKeyState: APNsKeyReadState = .readable,
        deviceCount: Int = 1,
        lastPushResult: String? = "1 of 1 delivered",
        lastPushSucceeded: Bool? = true
    ) -> CompanionDoctorState {
        CompanionDoctorState(
            bridgeEnabled: true,
            bridgeListening: bridgeListening,
            bonjourAdvertised: bonjourAdvertised,
            bridgePort: 47_837,
            tailscaleState: tailscaleState,
            tailscaleURL: "wss://mac.example.ts.net:8443/",
            apnsKeyState: apnsKeyState,
            apnsEnvironment: "sandbox",
            registeredDeviceCount: deviceCount,
            presenceGateEnabled: true,
            presenceGateIsAway: true,
            pendingPushCount: 0,
            lastPushResult: lastPushResult,
            lastPushSucceeded: lastPushSucceeded,
            devicePreferences: [
                DoctorDevicePreferences(
                    id: "phone-1",
                    label: "Phone",
                    preferences: .default
                ),
            ]
        )
    }
}
