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
            fetchRelease: { try await service.latestRelease() },
            installRelease: { release in
                let installation = try await service.prepare(release)
                try await service.launchInstaller(installation)
                NSApp.terminate(nil)
            }
        )
    }()

    static let skippedVersionKey = "skippedAppUpdateVersion"
    let currentVersion: String
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var release: AppRelease?
    @Published private(set) var isPresented = false
    @Published private(set) var isChecking = false
    private let defaults: UserDefaults
    private let fetchRelease: () async throws -> AppRelease
    private let installRelease: (AppRelease) async throws -> Void
    private var periodicTask: Task<Void, Never>?
    private var manualCheckRequested = false
    private var checkDismissed = false

    init(
        currentVersion: String, defaults: UserDefaults = .standard,
        fetchRelease: @escaping () async throws -> AppRelease,
        installRelease: @escaping (AppRelease) async throws -> Void
    ) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.fetchRelease = fetchRelease
        self.installRelease = installRelease
    }

    var isInstalling: Bool { phase == .installing }

    func start() {
        guard periodicTask == nil, AppReleaseVersion(currentVersion) != nil else { return }
        periodicTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(15))
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
        guard let release, !isInstalling else { return }
        phase = .installing
        do {
            try await installRelease(release)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
