import Foundation

/// Pure lock-screen text filtering. Keep this type separate from push transport.
public enum PushTextRedactor {
    public static func standard(_ value: String, isCompletion: Bool = false) -> String {
        if value.range(
            of: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
            options: .regularExpression
        ) != nil {
            return "Sensitive request details redacted"
        }
        let patterns = [
            #"(?i)(\b(?:proxy-)?authorization\s*:\s*(?:basic|bearer)\s+)[A-Za-z0-9._~+/=-]{4,}"#,
            #"(?i)(\bbearer\s+)[A-Za-z0-9._~+/=-]{8,}"#,
            #"(?i)(\b(?:sk-(?:proj-)?|gh[pousr]_))[A-Za-z0-9_-]{8,}"#,
            #"([?&][^=&#\s]+\s*=\s*)[^&#\s]+"#,
            #"(?i)(https?://[^\s#]+#)[^\s]+"#,
            #"(?i)(://)[^/@\s]+:[^/@\s]+@"#,
            #"(?i)(\b(?:cookie|set-cookie)\s*:\s*)[^'\"\s]+"#,
            #"(?i)(\b[A-Z0-9_]*(?:token|secret|password|passwd|session|cookie|api[_-]?key|private[_-]?key|credential)[A-Z0-9_]*\b\s*[:=]\s*)[^\s,;&]+"#,
            #"(?i)(\s(?:-H|--header)\s+['\"]?[^:'\"\s]+:\s*)[^'\"\s]+"#,
            #"(?i)(--?(?:password|token|secret|api[_-]?key)\s+)[^\s]+"#,
            #"(?i)(\s(?:-u|--user)\s+)[^\s]+"#,
            #"(?i)(\s(?:-b|--cookie)\s+)[^\s]+"#,
            #"(?i)(\s(?:-d|--data(?:-raw|-binary|-urlencode)?)\s+)[^\s]+"#,
            #"((?:^|\s)[A-Za-z_][A-Za-z0-9_]*=)[^\s]+"#,
            #"(?i)\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#,
            #"\b(?:AKIA|ASIA|AIDA|AROA|AIPA|ANPA|ANVA|ASCA)[A-Z0-9]{16}\b"#,
            #"\bAIza[A-Za-z0-9_-]{20,}\b"#,
            #"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#,
            #"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{10,}\b"#,
        ]
        let redacted = patterns.reduce(value) { result, pattern in
            replace(
                pattern,
                in: result,
                with: isWholeSecretPattern(pattern) ? "<redacted>" : "$1<redacted>"
            )
        }
        guard isCompletion else { return redacted }
        if matches(
            #"(?i)\b(?:password|passwd|passcode|credential|cookie|secret|private[ _-]?key|api[ _-]?key|access[ _-]?key|auth(?:entication)?[ _-]?(?:key|token)|session[ _-]?(?:key|token))\b"#,
            in: redacted
        ) || matches(
            #"(?=[A-Za-z0-9_+/=-]{24,}\b)(?=[A-Za-z0-9_+/=-]*[A-Za-z])(?=[A-Za-z0-9_+/=-]*[0-9])[A-Za-z0-9_+/=-]{24,}"#,
            in: redacted
        ) {
            return "Sensitive completion details redacted"
        }
        return redacted
    }

    public static func permission(_ value: String, agent: String?) -> String {
        let sensitivePatterns = [
            #"(?i)\b(?:password|passphrase|secret|token|key|bearer|pin|otp|code)\b.{0,12}(?:[:=]\s*)?[A-Za-z0-9_+/=-]{3,}"#,
            #"\b\d{4,}\b"#,
            #"\b[A-Fa-f0-9]{16,}\b"#,
            #"\b[A-Za-z0-9_+/=-]{16,}\b"#,
            #"(?i)(?:authorization|proxy-authorization)\s*:"#,
        ]
        if sensitivePatterns.contains(where: { matches($0, in: value) }) {
            return "Permission request from \(agent ?? "agent")"
        }
        return standard(value).replacingOccurrences(of: "<redacted>", with: "•••")
    }

    private static func isWholeSecretPattern(_ pattern: String) -> Bool {
        pattern.hasPrefix(#"(?i)\beyJ"#)
            || pattern.hasPrefix(#"\b(?:AKIA"#)
            || pattern.hasPrefix(#"\bAIza"#)
            || pattern.hasPrefix(#"\bxox"#)
            || pattern.hasPrefix(#"\b(?:sk|rk)"#)
    }

    private static func matches(_ pattern: String, in value: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return true }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range) != nil
    }

    private static func replace(
        _ pattern: String,
        in value: String,
        with template: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: template
        )
    }
}
