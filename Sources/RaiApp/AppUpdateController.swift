import AppKit
import Combine
import RaiCore

@MainActor
final class AppUpdateController: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, available, installing, upToDate, failed(String)
    }

    static let shared: AppUpdateController = {
        let service = AppUpdateService(applicationURL: Bundle.main.bundleURL)
        return AppUpdateController(
            currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            supportsUpdates: Bundle.main.bundleIdentifier == AppUpdateVerification.bundleIdentifier,
            fetchRelease: { try await service.latestRelease() },
            installRelease: { release in
                let installation = try await service.prepare(release)
                try await service.launchInstaller(installation)
                AppTermination.schedule()
            },
            pruneCompletedUpdates: {
                AppUpdateInstallation.pruneCompletedStaging(besideApplication: Bundle.main.bundleURL)
            }
        )
    }()

    static let skippedVersionKey = "skippedAppUpdateVersion"
    let currentVersion: String
    let supportsUpdates: Bool
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var release: AppRelease?
    @Published private(set) var isPresented = false
    @Published private(set) var isChecking = false
    private let defaults: UserDefaults
    private let fetchRelease: () async throws -> AppRelease
    private let installRelease: (AppRelease) async throws -> Void
    private let pruneCompletedUpdates: @Sendable () -> Void
    private var periodicTask: Task<Void, Never>?
    private var manualCheckRequested = false
    private var checkDismissed = false

    init(
        currentVersion: String, supportsUpdates: Bool = true, defaults: UserDefaults = .standard,
        fetchRelease: @escaping () async throws -> AppRelease,
        installRelease: @escaping (AppRelease) async throws -> Void,
        pruneCompletedUpdates: @escaping @Sendable () -> Void = {}
    ) {
        self.currentVersion = currentVersion
        self.supportsUpdates = supportsUpdates
        self.defaults = defaults
        self.fetchRelease = fetchRelease
        self.installRelease = installRelease
        self.pruneCompletedUpdates = pruneCompletedUpdates
    }

    var isInstalling: Bool { phase == .installing }

    func start() {
        guard supportsUpdates, periodicTask == nil, AppReleaseVersion(currentVersion) != nil else { return }
        periodicTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(15))
                // Fifteen seconds up means this build launches. The previous
                // version's backup has served its purpose, and leaving it
                // registered under Rai's bundle identifier misnames the app
                // in Finder and permission prompts.
                if let prune = self?.pruneCompletedUpdates {
                    await Task.detached(priority: .utility) { prune() }.value
                }
                while !Task.isCancelled {
                    await self?.check()
                    try await Task.sleep(for: .seconds(6 * 60 * 60))
                }
            } catch { /* App shutdown cancels the periodic check. */ }
        }
    }

    func stop() {
        periodicTask?.cancel()
        periodicTask = nil
    }

    func check(manual: Bool = false) async {
        guard supportsUpdates else {
            if manual {
                phase = .failed("Development builds do not install release updates. Use the Rai release app for updates.")
                isPresented = true
            }
            return
        }
        guard !isInstalling else { return }
        if isChecking {
            if manual {
                manualCheckRequested = true
                presentCheckingState()
            }
            return
        }
        guard manual || !isPresented else { return }
        if AppReleaseVersion(currentVersion) == nil {
            if manual {
                phase = .failed("This build has no release version. Install a release build to check for updates.")
                isPresented = true
            }
            return
        }
        isChecking = true
        manualCheckRequested = manual
        checkDismissed = false
        defer {
            isChecking = false
            manualCheckRequested = false
        }
        if manual { presentCheckingState() }
        do {
            let latest = try await fetchRelease()
            guard !Task.isCancelled else { return }
            if latest.shouldOffer(
                currentVersion: currentVersion,
                skippedVersion: defaults.string(forKey: Self.skippedVersionKey), manual: manualCheckRequested
            ) {
                release = latest
                phase = .available
                if !checkDismissed { isPresented = true }
            } else if manualCheckRequested {
                phase = .upToDate
            }
        } catch {
            // Offline startup stays quiet. An explicit check reports its failure.
            if manualCheckRequested { phase = .failed(error.localizedDescription) }
        }
    }

    private func presentCheckingState() {
        checkDismissed = false
        release = nil
        phase = .checking
        isPresented = true
    }

    func skip() {
        guard !isInstalling else { return }
        if let release { defaults.set(release.version.description, forKey: Self.skippedVersionKey) }
        dismiss()
    }

    func dismiss() {
        guard !isInstalling else { return }
        if isChecking { checkDismissed = true }
        isPresented = false
    }

    func update() async {
        guard supportsUpdates, let release, !isInstalling else { return }
        phase = .installing
        do {
            try await installRelease(release)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
