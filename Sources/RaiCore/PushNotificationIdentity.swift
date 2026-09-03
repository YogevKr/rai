public enum PushNotificationIdentity {
    public static func pane(_ paneID: String) -> String {
        guard paneID.utf8.count <= 64 else {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in paneID.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 1_099_511_628_211
            }
            return "agent-hash-\(paneID.utf8.count)-\(String(hash, radix: 16))"
        }
        return "agent-\(paneID)"
    }

    public static func decision(_ paneID: String, requestID: String) -> String {
        let value = "decision-\(paneID)-\(requestID)"
        guard value.utf8.count <= 128 else {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in value.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 1_099_511_628_211
            }
            return "decision-hash-\(value.utf8.count)-\(String(hash, radix: 16))"
        }
        return value
    }
}
