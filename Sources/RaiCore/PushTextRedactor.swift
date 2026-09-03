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
            #"(?i)\b(?:password|passphrase|secret|token|key|bearer|pin|otp|code)\b(?:(?:\s+|[:=]\s*)[A-Za-z][A-Za-z-]*){0,2}(?:\s+|[:=]\s*)[A-Za-z0-9_+/=-]{3,}"#,
            #"(?i)(?:authorization|proxy-authorization)\s*:"#,
        ]
        if sensitivePatterns.contains(where: { matches($0, in: value) }) {
            return "Permission request from \(agent ?? "agent")"
        }
        let standardized = standard(value).replacingOccurrences(of: "<redacted>", with: "•••")
        return redactPermissionTokens(in: standardized)
    }

    private static let permissionEdgePunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "(", ")", "[", "]", "{", "}",
        "\"", "'", "`", "<", ">",
    ]

    private static func redactPermissionTokens(in value: String) -> String {
        var output = ""
        var token = ""
        for character in value {
            if character.isWhitespace {
                output += redactPermissionToken(token)
                output.append(character)
                token = ""
            } else {
                token.append(character)
            }
        }
        output += redactPermissionToken(token)
        return output
    }

    private static func redactPermissionToken(_ token: String) -> String {
        guard !token.isEmpty else { return token }
        let characters = Array(token)
        var lower = 0
        while lower < characters.count,
              permissionEdgePunctuation.contains(characters[lower]) {
            lower += 1
        }
        var upper = characters.count
        while upper > lower,
              permissionEdgePunctuation.contains(characters[upper - 1]) {
            upper -= 1
        }
        let core = String(characters[lower..<upper])
        guard shouldRedactPermissionCore(core) else { return token }
        return String(characters[..<lower]) + "•••" + String(characters[upper...])
    }

    private static func shouldRedactPermissionCore(_ core: String) -> Bool {
        guard !core.isEmpty,
              !isSafePermissionPath(core),
              !core.hasPrefix("https://"),
              !core.hasPrefix("http://")
        else { return false }
        let scalars = core.unicodeScalars
        if core.count >= 6, scalars.allSatisfy({ isASCIIDigit($0) }) {
            return true
        }
        if core.count >= 16, scalars.allSatisfy({ isASCIIHexDigit($0) }) {
            return true
        }
        if core.hasSuffix("=") { return true }
        guard core.count >= 20 else { return false }

        let classes = [
            scalars.contains(where: { (97...122).contains($0.value) }),
            scalars.contains(where: { (65...90).contains($0.value) }),
            scalars.contains(where: isASCIIDigit),
            scalars.contains(where: { "_+/=-".unicodeScalars.contains($0) }),
        ]
        return classes.filter { $0 }.count >= 2
    }

    private static func isSafePermissionPath(_ value: String) -> Bool {
        let remainder: Substring
        if value.hasPrefix("../") {
            remainder = value.dropFirst(3)
        } else if value.hasPrefix("~/") || value.hasPrefix("./") {
            remainder = value.dropFirst(2)
        } else if value.hasPrefix("/") {
            remainder = value.dropFirst()
        } else {
            return false
        }
        let segments = remainder.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.count <= 64 && segment.unicodeScalars.allSatisfy {
                isASCIIAlphaNumeric($0) || ".-_".unicodeScalars.contains($0)
            }
        }
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
    }

    private static func isASCIIHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIDigit(scalar)
            || (65...70).contains(scalar.value)
            || (97...102).contains(scalar.value)
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIDigit(scalar)
            || (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
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
