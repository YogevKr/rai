import AppKit
import Foundation
import RaiCore

// This executable starts before Rai quits. It never controls the Herdr server.
// It waits for the exact Rai process, then replaces only that app bundle.
var activeInstallation: AppUpdateInstallation?
var parentExited = false

func openApplication(at url: URL) throws {
    let opener = Process()
    opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    opener.arguments = [url.path]
    try opener.run()
    opener.waitUntilExit()
    guard opener.terminationStatus == 0 else { throw AppUpdateError.restartFailed }
}

do {
    guard CommandLine.arguments.count == 2 else { throw AppUpdateError.cannotInstall }
    let manifest = URL(fileURLWithPath: CommandLine.arguments[1])
    let installation = try JSONDecoder().decode(AppUpdateInstallation.self, from: Data(contentsOf: manifest))
    guard manifest.deletingLastPathComponent().standardizedFileURL == installation.staging.standardizedFileURL
    else { throw AppUpdateError.cannotInstall }
    try installation.validatePaths()
    activeInstallation = installation
    try AppUpdateVerification.verifyApplication(at: installation.candidate, version: installation.version)
    guard let application = NSRunningApplication(processIdentifier: installation.parentPID),
          application.bundleURL?.standardizedFileURL == installation.target.standardizedFileURL
    else { throw AppUpdateError.cannotInstall }
    try Data().write(to: installation.staging.appendingPathComponent("ready"), options: .atomic)

    let deadline = ProcessInfo.processInfo.systemUptime + 120
    while !application.isTerminated && ProcessInfo.processInfo.systemUptime < deadline {
        // RunLoop lets NSRunningApplication refresh its termination state.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    guard application.isTerminated else { throw AppUpdateError.applicationStillRunning }
    parentExited = true
    try AppUpdateVerification.verifyApplication(at: installation.candidate, version: installation.version)
    try installation.replaceApplication()

    try openApplication(at: installation.target)
    try Data("Installed Rai \(installation.version).\n".utf8)
        .write(to: installation.staging.appendingPathComponent("result.txt"), options: .atomic)
} catch {
    // Keep the staging directory and backup for recovery. Report the failure
    // after the main app exits instead of silently abandoning the update.
    if parentExited, let installation = activeInstallation,
       FileManager.default.fileExists(atPath: installation.target.path) {
        try? openApplication(at: installation.target)
    }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let alert = NSAlert()
    alert.messageText = "Rai could not finish the update"
    alert.informativeText = error.localizedDescription
    if let installation = activeInstallation {
        alert.informativeText += "\n\nUpdate folder: \(installation.staging.path)"
    }
    alert.addButton(withTitle: "OK")
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
    exit(1)
}
