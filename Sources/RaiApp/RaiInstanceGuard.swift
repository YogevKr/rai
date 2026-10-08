import AppKit

enum RaiInstanceGuard {
    struct Instance: Equatable {
        let bundleIdentifier: String?
        let processIdentifier: Int32
    }

    static func duplicate(
        bundleIdentifier: String?,
        currentProcessIdentifier: Int32,
        running: [Instance]
    ) -> Instance? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        return running.first {
            $0.processIdentifier != currentProcessIdentifier
                && $0.bundleIdentifier == bundleIdentifier
        }
    }

    static func enforce(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        guard let bundleIdentifier,
              let duplicate = duplicate(
                  bundleIdentifier: bundleIdentifier,
                  currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
                  running: NSRunningApplication.runningApplications(
                      withBundleIdentifier: bundleIdentifier
                  ).map { Instance(bundleIdentifier: $0.bundleIdentifier, processIdentifier: $0.processIdentifier) }
              ),
              let application = NSRunningApplication(processIdentifier: duplicate.processIdentifier)
        else { return }

        application.activate(options: [.activateAllWindows])
        exit(0)
    }
}
