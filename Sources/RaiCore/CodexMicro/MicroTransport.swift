#if os(macOS)
@preconcurrency import IOKit.hid
import Foundation

public struct MicroUsagePair: Hashable, Sendable {
    public let usagePage: Int
    public let usage: Int

    public init(usagePage: Int, usage: Int) {
        self.usagePage = usagePage
        self.usage = usage
    }
}

public enum MicroTransportKind: Equatable, Sendable {
    case usb
    case bluetooth
    case other(String?)

    init(rawValue: String?) {
        guard let rawValue else {
            self = .other(nil)
            return
        }
        if rawValue.localizedCaseInsensitiveContains("bluetooth") {
            self = .bluetooth
        } else if rawValue.localizedCaseInsensitiveContains("usb") {
            self = .usb
        } else {
            self = .other(rawValue)
        }
    }

    public var displayName: String {
        switch self {
        case .usb: "USB"
        case .bluetooth: "Bluetooth Low Energy"
        case .other(let value): value ?? "<unknown>"
        }
    }
}

public struct MicroDeviceIdentity: Equatable, Sendable {
    public let vendorID: Int
    public let productID: Int
    /// The interface's PRIMARY usage page. On real Codex Micro hardware this is
    /// `0x01` (Generic Desktop / Keyboard) — NOT the vendor page. Reporting only;
    /// never match on it.
    public let usagePage: Int
    /// Every top-level collection the interface publishes. The vendor channel is
    /// one of these, not the primary — see `hasVendorCollection`.
    public let usagePairs: [MicroUsagePair]
    public let manufacturer: String?
    public let product: String?
    public let transport: MicroTransportKind
    public let maxInputReportSize: Int
    public let maxOutputReportSize: Int
    /// Stable IOKit registry-entry identifier used to make node selection
    /// independent of `Set<IOHIDDevice>` iteration order.
    public let registryEntryID: UInt64

    public init(
        vendorID: Int,
        productID: Int,
        usagePage: Int,
        usagePairs: [MicroUsagePair] = [],
        manufacturer: String?,
        product: String?,
        transport: MicroTransportKind,
        maxInputReportSize: Int,
        maxOutputReportSize: Int,
        registryEntryID: UInt64
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.usagePage = usagePage
        self.usagePairs = usagePairs
        self.manufacturer = manufacturer
        self.product = product
        self.transport = transport
        self.maxInputReportSize = maxInputReportSize
        self.maxOutputReportSize = maxOutputReportSize
        self.registryEntryID = registryEntryID
    }

    public var manufacturerMatches: Bool {
        manufacturer?.localizedCaseInsensitiveContains("Work Louder") == true
    }

    /// True when the interface exposes the vendor-defined collection that carries
    /// the report-ID-6 JSON-RPC channel.
    public var hasVendorCollection: Bool {
        usagePairs.contains(
            MicroUsagePair(
                usagePage: IOHIDMicroTransport.usagePage,
                usage: IOHIDMicroTransport.usage
            )
        )
    }

    public var hasExpectedReportSizes: Bool {
        maxInputReportSize == MicroFraming.reportSize
            && maxOutputReportSize == MicroFraming.reportSize
    }
}

public enum MicroTransportError: Error, LocalizedError {
    case noMatchingDevice
    case alreadyOpen
    case notOpen
    case invalidReport
    case ioReturn(IOReturn)

    public var errorDescription: String? {
        switch self {
        case .noMatchingDevice: "no matching Codex Micro HID interface found"
        case .alreadyOpen: "Codex Micro transport is already open"
        case .notOpen: "Codex Micro transport is not open"
        case .invalidReport: "Codex Micro reports must be exactly 64 bytes with report ID 0x06"
        case .ioReturn(let code) where code == kIOReturnExclusiveAccess:
            """
            Codex Micro is seized by another process, so it cannot be opened \
            (kIOReturnExclusiveAccess). Every one of the pad's HID nodes carries a \
            Keyboard collection, and Karabiner-Elements seizes keyboards in order to \
            remap them — exclude "Codex Micro" under Karabiner-Elements → Settings → \
            Devices. Work Louder Input can hold it too. Work Louder document this \
            conflict on their setup page.
            """
        case .ioReturn(let code): "IOKit HID operation failed (\(code))"
        }
    }

    /// True when the failure is another process holding the device, which is a
    /// configuration problem the user can fix — not a bug and not transient.
    public var isSeized: Bool {
        if case .ioReturn(let code) = self, code == kIOReturnExclusiveAccess { return true }
        return false
    }
}

public protocol MicroTransport: AnyObject, Sendable {
    var onReport: (@Sendable ([UInt8]) -> Void)? { get set }
    func open() throws
    func close()
    func send(report: [UInt8]) throws
}

/// IOHID callbacks arrive on the run loop used by `open()`. Mutable state and
/// callback replacement are lock-protected; user callbacks execute outside the lock.
public final class IOHIDMicroTransport: MicroTransport, @unchecked Sendable {
    public static let vendorID = 0x303A
    public static let productIDs = [0x8360, 0x8297, 0x8298]
    /// The vendor-defined collection carrying the report-ID-6 JSON-RPC channel.
    /// This is a SECONDARY collection on the interface, never the primary one.
    public static let usagePage = 0xFF00
    public static let usage = 0x01

    private let lock = NSLock()
    private let manager: IOHIDManager
    private var device: IOHIDDevice?
    private var inputBuffer: UnsafeMutablePointer<UInt8>?
    private var scheduledRunLoop: CFRunLoop?
    private var monitoring = false
    private var monitoringRunLoop: CFRunLoop?
    private var selectedIdentity: MicroDeviceIdentity?

    /// Optional trace of why an attach did or did not happen. Attach failures in
    /// the monitoring path are otherwise invisible, which makes "nothing
    /// happened" indistinguishable from "the callback never fired".
    public var onDiagnostic: (@Sendable (String) -> Void)?

    /// Called with `true` on attach and `false` on drop while monitoring.
    /// Invoked outside the internal lock, on the monitoring run loop.
    public var onConnectionChange: (@Sendable (Bool) -> Void)?
    private var callback: (@Sendable ([UInt8]) -> Void)?

    public var onReport: (@Sendable ([UInt8]) -> Void)? {
        get { lock.withLock { callback } }
        set { lock.withLock { callback = newValue } }
    }

    public var currentDeviceIdentity: MicroDeviceIdentity? {
        lock.withLock { selectedIdentity }
    }

    public init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, Self.matchingDictionaries() as CFArray)
    }

    deinit {
        close()
    }

    public static func enumerate() -> [MicroDeviceIdentity] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingDictionaries() as CFArray)
        // Populate the manager, but inspect its devices even when opening reports
        // exclusive-access for one BLE node; that node must not hide its siblings.
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        return ranked(devices.compactMap(identity(for:)).filter(matchesVIDPID))
    }

    /// Pure, deterministic selection policy shared by USB and multi-node BLE.
    public static func ranked(_ identities: [MicroDeviceIdentity]) -> [MicroDeviceIdentity] {
        identities.sorted {
            let lhs = ($0.hasVendorCollection ? 0 : 1, $0.hasExpectedReportSizes ? 0 : 1)
            let rhs = ($1.hasVendorCollection ? 0 : 1, $1.hasExpectedReportSizes ? 0 : 1)
            if lhs != rhs { return lhs < rhs }
            return $0.registryEntryID < $1.registryEntryID
        }
    }

    public func open() throws {
        try lock.withLock {
            guard device == nil else { throw MicroTransportError.alreadyOpen }
            let managerResult = IOHIDManagerOpen(
                manager, IOOptionBits(kIOHIDOptionsTypeNone)
            )
            let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
            let candidates = Self.rankedDevices(devices)
            guard !candidates.isEmpty else {
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                throw managerResult == kIOReturnSuccess
                    ? MicroTransportError.noMatchingDevice
                    : MicroTransportError.ioReturn(managerResult)
            }
            var lastError: IOReturn = managerResult
            for candidate in candidates {
                let deviceResult = IOHIDDeviceOpen(
                    candidate.device, IOOptionBits(kIOHIDOptionsTypeNone)
                )
                guard deviceResult == kIOReturnSuccess else {
                    lastError = deviceResult
                    continue
                }
                attachOpenedLocked(candidate.device, identity: candidate.identity)
                return
            }
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw MicroTransportError.ioReturn(lastError)
        }
    }

    /// Attaches to the pad whenever it appears, and re-attaches automatically
    /// after it drops. Real Codex Micro hardware disconnects and re-enumerates
    /// unpredictably (observed repeatedly on serial 441BF6D10968), so a one-shot
    /// `open()` is not usable for unattended capture or for a long-lived app.
    ///
    /// Fires `onConnectionChange` on attach/detach. Callbacks arrive on the run
    /// loop this is called from, so that run loop must be running.
    public func openMonitoring() throws {
        var attachedDuringOpen = false
        try lock.withLock {
            guard !monitoring else { throw MicroTransportError.alreadyOpen }
            guard let runLoop = CFRunLoopGetCurrent() else {
                throw MicroTransportError.notOpen
            }
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.matchedCallback, context)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.removedCallback, context)
            IOHIDManagerScheduleWithRunLoop(
                manager, runLoop, CFRunLoopMode.defaultMode.rawValue
            )
            let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            let candidates = Self.rankedDevices(
                (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
            )
            if result != kIOReturnSuccess && candidates.isEmpty {
                IOHIDManagerUnscheduleFromRunLoop(
                    manager, runLoop, CFRunLoopMode.defaultMode.rawValue
                )
                throw MicroTransportError.ioReturn(result)
            }
            monitoring = true
            monitoringRunLoop = runLoop
            guard device == nil, !candidates.isEmpty else { return }
            // Attaching here MUST notify: a pad that is already connected when
            // monitoring starts is the normal case, and consumers reset their
            // lighting baseline / repaint on this callback. Silently attaching
            // left the LEDs dark forever.
            defer { if device != nil { attachedDuringOpen = true } }
            var lastError: IOReturn = kIOReturnSuccess
            for candidate in candidates {
                lastError = attachLocked(candidate.device, identity: candidate.identity)
                if lastError == kIOReturnSuccess { return }
            }
            monitoring = false
            monitoringRunLoop = nil
            IOHIDManagerUnscheduleFromRunLoop(
                manager, runLoop, CFRunLoopMode.defaultMode.rawValue
            )
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw MicroTransportError.ioReturn(lastError)
        }
        // A device present at open time is attached synchronously above; later
        // arrivals come through the matching callback. Both paths notify.
        if attachedDuringOpen { onConnectionChange?(true) }
    }

    private func handleMatched(_: IOHIDDevice) {
        var diagnostics: [String] = []
        let attached: Bool = lock.withLock {
            guard monitoring else {
                diagnostics.append("matched callback ignored: not monitoring")
                return false
            }
            let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
            let candidates = Self.rankedDevices(devices)
            diagnostics.append(
                "matched callback: \(devices.count) device(s), \(candidates.count) candidate(s)"
            )
            if let current = selectedIdentity,
               candidates.first?.identity.registryEntryID == current.registryEntryID {
                return false
            }
            let candidatesToTry: ArraySlice<RankedDevice>
            if let current = selectedIdentity,
               let currentIndex = candidates.firstIndex(where: {
                   $0.identity.registryEntryID == current.registryEntryID
               }) {
                candidatesToTry = candidates[..<currentIndex]
            } else {
                candidatesToTry = candidates[...]
            }
            for candidate in candidatesToTry {
                // BLE nodes may arrive in separate callbacks. Open the newly
                // top-ranked node before dropping the current fallback node.
                let result = IOHIDDeviceOpen(
                    candidate.device, IOOptionBits(kIOHIDOptionsTypeNone)
                )
                guard result == kIOReturnSuccess else {
                    diagnostics.append(
                        String(
                            format: "open of node 0x%llX failed: 0x%08X",
                            candidate.identity.registryEntryID,
                            UInt32(bitPattern: result)
                        )
                    )
                    continue
                }
                let replacingExisting = device != nil
                if replacingExisting { detachLocked() }
                attachOpenedLocked(candidate.device, identity: candidate.identity)
                if replacingExisting { return false }
                return true
            }
            return false
        }
        for line in diagnostics { onDiagnostic?(line) }
        if attached { onConnectionChange?(true) }
    }

    private func handleRemoved(_ candidate: IOHIDDevice) {
        let detached: Bool = lock.withLock {
            guard let current = device, current == candidate else { return false }
            detachLocked()
            return true
        }
        if detached { onConnectionChange?(false) }
    }

    /// Caller must hold `lock`.
    private func attachLocked(
        _ selected: IOHIDDevice,
        identity: MicroDeviceIdentity
    ) -> IOReturn {
        let result = IOHIDDeviceOpen(selected, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { return result }
        attachOpenedLocked(selected, identity: identity)
        return kIOReturnSuccess
    }

    /// Caller must hold `lock`; `selected` must already be open.
    private func attachOpenedLocked(
        _ selected: IOHIDDevice,
        identity: MicroDeviceIdentity
    ) {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(
            capacity: MicroFraming.reportSize
        )
        buffer.initialize(repeating: 0, count: MicroFraming.reportSize)
        inputBuffer = buffer
        device = selected
        selectedIdentity = identity
        scheduledRunLoop = CFRunLoopGetCurrent()
        IOHIDDeviceRegisterInputReportCallback(
            selected,
            buffer,
            MicroFraming.reportSize,
            Self.inputCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(
            selected, scheduledRunLoop!, CFRunLoopMode.defaultMode.rawValue
        )
    }

    /// Caller must hold `lock`. Safe when the device vanished underneath us.
    private func detachLocked() {
        guard let selected = device else { return }
        if let scheduledRunLoop {
            IOHIDDeviceUnscheduleFromRunLoop(
                selected, scheduledRunLoop, CFRunLoopMode.defaultMode.rawValue
            )
        }
        IOHIDDeviceClose(selected, IOOptionBits(kIOHIDOptionsTypeNone))
        inputBuffer?.deinitialize(count: MicroFraming.reportSize)
        inputBuffer?.deallocate()
        inputBuffer = nil
        device = nil
        selectedIdentity = nil
        scheduledRunLoop = nil
    }

    public func close() {
        lock.withLock {
            if monitoring {
                detachLocked()
                if let monitoringRunLoop {
                    IOHIDManagerUnscheduleFromRunLoop(
                        manager, monitoringRunLoop, CFRunLoopMode.defaultMode.rawValue
                    )
                }
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                monitoring = false
                monitoringRunLoop = nil
                return
            }
            guard let selected = device else { return }
            if let scheduledRunLoop {
                IOHIDDeviceUnscheduleFromRunLoop(
                    selected, scheduledRunLoop, CFRunLoopMode.defaultMode.rawValue
                )
            }
            IOHIDDeviceClose(selected, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            inputBuffer?.deinitialize(count: MicroFraming.reportSize)
            inputBuffer?.deallocate()
            inputBuffer = nil
            device = nil
            selectedIdentity = nil
            scheduledRunLoop = nil
        }
    }

    public func send(report: [UInt8]) throws {
        guard report.count == MicroFraming.reportSize,
              report.first == MicroFraming.reportID else {
            throw MicroTransportError.invalidReport
        }
        try lock.withLock {
            guard let selected = device else { throw MicroTransportError.notOpen }
            let payload = Self.outputReportPayload(from: report)
            let result = payload.withUnsafeBytes { bytes in
                IOHIDDeviceSetReport(
                    selected,
                    kIOHIDReportTypeOutput,
                    CFIndex(MicroFraming.reportID),
                    bytes.bindMemory(to: UInt8.self).baseAddress!,
                    payload.count
                )
            }
            guard result == kIOReturnSuccess else {
                throw MicroTransportError.ioReturn(result)
            }
        }
    }

    private enum OutputReportPayloadConvention {
        case fullBufferIncludingReportID
        case payloadWithoutReportID
    }

    // USB is hardware-verified with the report ID both here and in CFIndex.
    // If BLE writes are rejected or the device reports JSON parse errors, flip
    // this one value to `.payloadWithoutReportID`; CFIndex remains report ID 6.
    private static let outputReportPayloadConvention:
        OutputReportPayloadConvention = .fullBufferIncludingReportID

    private static func outputReportPayload(from report: [UInt8]) -> ArraySlice<UInt8> {
        switch outputReportPayloadConvention {
        case .fullBufferIncludingReportID: report[...]
        case .payloadWithoutReportID: report.dropFirst()
        }
    }

    private func receive(reportID: UInt32, bytes: UnsafeMutablePointer<UInt8>?, length: Int) {
        guard let bytes else { return }
        var report = Array(UnsafeBufferPointer(start: bytes, count: length))
        if report.count == MicroFraming.reportSize - 1 {
            report.insert(UInt8(truncatingIfNeeded: reportID), at: 0)
        }
        guard report.count == MicroFraming.reportSize else { return }
        let handler = lock.withLock { callback }
        handler?(report)
    }

    private static let inputCallback: IOHIDReportCallback = {
        context, _, _, _, reportID, report, reportLength in
        guard let context else { return }
        Unmanaged<IOHIDMicroTransport>.fromOpaque(context).takeUnretainedValue()
            .receive(reportID: reportID, bytes: report, length: reportLength)
    }

    private static let matchedCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<IOHIDMicroTransport>.fromOpaque(context).takeUnretainedValue()
            .handleMatched(device)
    }

    private static let removedCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<IOHIDMicroTransport>.fromOpaque(context).takeUnretainedValue()
            .handleRemoved(device)
    }

    /// VID/PID only. Matching on `kIOHIDPrimaryUsagePageKey == 0xFF00` looks correct
    /// but matches NOTHING: verified on real hardware (serial 441BF6D10968), the pad
    /// publishes five top-level collections on one interface — Keyboard (report 1),
    /// Consumer (2), Mouse (3), Game Pad (4) and vendor 0xFF00 usage 1 (report 6) —
    /// so its PRIMARY usage page is 0x01. The vendor collection is filtered for in
    /// `matches` via the device's usage pairs instead.
    private static func matchingDictionaries() -> [[String: Any]] {
        productIDs.map {
            [
                kIOHIDVendorIDKey as String: vendorID,
                kIOHIDProductIDKey as String: $0,
            ]
        }
    }

    private static func identity(for device: IOHIDDevice) -> MicroDeviceIdentity? {
        guard let vendor = integerProperty(device, kIOHIDVendorIDKey),
              let product = integerProperty(device, kIOHIDProductIDKey),
              let page = integerProperty(device, kIOHIDPrimaryUsagePageKey) else {
            return nil
        }
        guard let registryEntryID = registryEntryID(for: device) else { return nil }
        return MicroDeviceIdentity(
            vendorID: vendor,
            productID: product,
            usagePage: page,
            usagePairs: usagePairs(for: device),
            manufacturer: stringProperty(device, kIOHIDManufacturerKey),
            product: stringProperty(device, kIOHIDProductKey),
            transport: MicroTransportKind(
                rawValue: stringProperty(device, kIOHIDTransportKey)
            ),
            maxInputReportSize: integerProperty(device, kIOHIDMaxInputReportSizeKey) ?? 0,
            maxOutputReportSize: integerProperty(device, kIOHIDMaxOutputReportSizeKey) ?? 0,
            registryEntryID: registryEntryID
        )
    }

    private static func matchesVIDPID(_ identity: MicroDeviceIdentity) -> Bool {
        identity.vendorID == vendorID
            && productIDs.contains(identity.productID)
    }

    private struct RankedDevice {
        let device: IOHIDDevice
        let identity: MicroDeviceIdentity
    }

    private static func rankedDevices(_ devices: Set<IOHIDDevice>) -> [RankedDevice] {
        let candidates = devices.compactMap { device -> RankedDevice? in
            guard let identity = identity(for: device), matchesVIDPID(identity) else {
                return nil
            }
            return RankedDevice(device: device, identity: identity)
        }
        let order = Dictionary(
            uniqueKeysWithValues: ranked(candidates.map(\.identity)).enumerated().map {
                ($0.element.registryEntryID, $0.offset)
            }
        )
        return candidates.sorted {
            order[$0.identity.registryEntryID, default: .max]
                < order[$1.identity.registryEntryID, default: .max]
        }
    }

    /// Reads every top-level collection the interface publishes. Falls back to the
    /// primary pair when `kIOHIDDeviceUsagePairsKey` is absent.
    private static func usagePairs(for device: IOHIDDevice) -> [MicroUsagePair] {
        let raw = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString)
        if let entries = raw as? [[String: Any]] {
            let pairs = entries.compactMap { entry -> MicroUsagePair? in
                guard let page = (entry[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue,
                      let usage = (entry[kIOHIDDeviceUsageKey] as? NSNumber)?.intValue else {
                    return nil
                }
                return MicroUsagePair(usagePage: page, usage: usage)
            }
            if !pairs.isEmpty { return pairs }
        }
        guard let page = integerProperty(device, kIOHIDPrimaryUsagePageKey),
              let usage = integerProperty(device, kIOHIDPrimaryUsageKey) else {
            return []
        }
        return [MicroUsagePair(usagePage: page, usage: usage)]
    }

    private static func integerProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private static func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private static func registryEntryID(for device: IOHIDDevice) -> UInt64? {
        var identifier: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(
            IOHIDDeviceGetService(device), &identifier
        ) == kIOReturnSuccess else {
            return nil
        }
        return identifier
    }
}

public final class MockMicroTransport: MicroTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var reports: [[UInt8]] = []
    private var callback: (@Sendable ([UInt8]) -> Void)?

    public init() {}

    public var onReport: (@Sendable ([UInt8]) -> Void)? {
        get { lock.withLock { callback } }
        set { lock.withLock { callback = newValue } }
    }

    public var sentReports: [[UInt8]] { lock.withLock { reports } }

    public func open() throws {
        try lock.withLock {
            guard !opened else { throw MicroTransportError.alreadyOpen }
            opened = true
        }
    }

    public func close() {
        lock.withLock { opened = false }
    }

    public func send(report: [UInt8]) throws {
        try lock.withLock {
            guard opened else { throw MicroTransportError.notOpen }
            guard report.count == MicroFraming.reportSize else {
                throw MicroTransportError.invalidReport
            }
            reports.append(report)
        }
    }

    public func inject(_ report: [UInt8]) {
        let handler = lock.withLock { callback }
        handler?(report)
    }
}
#endif
