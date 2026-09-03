public enum BridgeErrorCode: String, Codable, CaseIterable, Equatable, Sendable {
    case herdMissing = "herd_missing"
    case paneGone = "pane_gone"
    case paneBusy = "pane_busy"
    case auditUnavailable = "audit_unavailable"
    case repairRequired = "repair_required"
    case pairingCodeInvalid = "pairing_code_invalid"
    case protocolMismatch = "protocol_mismatch"
    case unknownMessage = "unknown_message"
    case invalidRequest = "invalid_request"
    case operationFailed = "operation_failed"
    case streamUnavailable = "stream_unavailable"
    case scrollbackUnavailable = "scrollback_unavailable"
}
