import Foundation
import Network

/// Keep the transport injectable so loss and delayed replies need no system network changes.
@MainActor
protocol BridgeSocket: AnyObject {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void)
}

extension URLSessionWebSocketTask: BridgeSocket {}

struct BridgeNetworkTiming {
    var handshakeTimeout: TimeInterval = 30
    var pingInterval: TimeInterval = 15
    var pongTimeout: TimeInterval = 30
    var reconnectBase: TimeInterval = 1
}

struct BridgeNetworkPath: Equatable, Sendable {
    let status: NWPath.Status
    let isExpensive: Bool
    let isConstrained: Bool
    let interfaces: Set<String>

    // A connection attempt can activate a path in requiresConnection state.
    var allowsConnectionAttempts: Bool { status != .unsatisfied }

    init(
        status: NWPath.Status, isExpensive: Bool = false,
        isConstrained: Bool = false, interfaces: Set<String> = []
    ) {
        self.status = status
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.interfaces = interfaces
    }

    init(_ path: NWPath) {
        status = path.status
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        interfaces = Set(path.availableInterfaces.filter {
            path.usesInterfaceType($0.type)
        }.map(\.name))
    }
}

struct BridgeHistoryPacing {
    var path: BridgeNetworkPath?
    var roundTrip: TimeInterval = 0
    var historyReadDuration: TimeInterval = 0

    var interval: TimeInterval {
        let reducedTraffic = path?.isExpensive == true || path?.isConstrained == true
        let slow = roundTrip >= 0.75 || historyReadDuration >= 1
        return reducedTraffic || slow ? min(5, max(2, historyReadDuration)) : 0.25
    }
}
