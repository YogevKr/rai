import UIKit

struct TerminalCacheKey: Hashable {
    let scope: UUID
    let paneID: String
    let terminalID: String
    let agentSessionID: String?
}

@MainActor
final class TerminalSurface {
    let scroll: UIScrollView
    let terminal: GridReadableTerminalView
    let widthFloor: NSLayoutConstraint
    let baseWidthFloor: CGFloat
    let charWidth: CGFloat

    init(
        scroll: UIScrollView, terminal: GridReadableTerminalView,
        widthFloor: NSLayoutConstraint, baseWidthFloor: CGFloat, charWidth: CGFloat
    ) {
        self.scroll = scroll
        self.terminal = terminal
        self.widthFloor = widthFloor
        self.baseWidthFloor = baseWidthFloor
        self.charWidth = charWidth
    }

    deinit {
        // SwiftTerm's display link retains the terminal even while paused.
        // Taking a cached surface transfers ownership without closing that link.
        let terminal = terminal
        Task { @MainActor in
            terminal.suspendHistoryRefresh()
            terminal.terminalDelegate = nil
            terminal.updateUiClosed()
        }
    }
}

/// Own only detached views. The visible view belongs to its SwiftUI coordinator.
@MainActor
final class TerminalViewCache {
    private let capacity: Int
    private var entries: [TerminalCacheKey: TerminalSurface] = [:]
    private var order: [TerminalCacheKey] = []
    private let notificationCenter: NotificationCenter
    private var memoryObserver: NSObjectProtocol?

    var count: Int { entries.count }

    init(capacity: Int = 3, notificationCenter: NotificationCenter = .default) {
        self.capacity = max(0, capacity)
        self.notificationCenter = notificationCenter
        memoryObserver = notificationCenter.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.removeAll() }
        }
    }

    deinit {
        if let memoryObserver { notificationCenter.removeObserver(memoryObserver) }
    }

    func take(_ key: TerminalCacheKey) -> TerminalSurface? {
        order.removeAll { $0 == key }
        return entries.removeValue(forKey: key)
    }

    func store(_ surface: TerminalSurface, for key: TerminalCacheKey) {
        guard capacity > 0 else { return }
        entries[key] = surface
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity { entries.removeValue(forKey: order.removeFirst()) }
    }

    func retain(_ keys: Set<TerminalCacheKey>) {
        entries = entries.filter { keys.contains($0.key) }
        order.removeAll { !keys.contains($0) }
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
    }
}
