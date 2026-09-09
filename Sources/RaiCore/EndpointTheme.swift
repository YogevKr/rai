import Foundation

/// Client-local theme preferences. An empty name preserves Rai's native defaults.
public struct EndpointTheme: Codable, Equatable, Sendable {
    public var name = ""
    public var autoSwitch = true
    public var lightName = ""
    public var darkName = ""
    public var shared: [String: String] = [:]
    public var light: [String: String] = [:]
    public var dark: [String: String] = [:]

    public init() {}

    public static func stored(_ value: String) -> Self {
        guard let data = value.data(using: .utf8), let theme = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self()
        }
        return theme
    }

    public func encoded() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    public func palette(dark isDark: Bool) -> [String: EndpointThemeColor] {
        let base = EndpointThemeCatalog.canonicalName(name) ?? ""
        let explicit = isDark ? darkName : lightName
        let selected = autoSwitch ? (EndpointThemeCatalog.canonicalName(explicit) ?? EndpointThemeCatalog.sibling(base, dark: isDark)) : base
        var colors = Dictionary(uniqueKeysWithValues: zip(EndpointThemeCatalog.tokens, EndpointThemeCatalog.values[selected] ?? []))
        colors.merge(shared) { _, new in new }
        if autoSwitch { colors.merge(isDark ? dark : light) { _, new in new } }
        return colors.compactMapValues { try? EndpointThemeColor.parse($0) }
    }

    public func validate() throws {
        for value in [name, lightName, darkName] where !value.isEmpty {
            guard EndpointThemeCatalog.canonicalName(value) != nil else { throw EndpointThemeError("Unknown theme: \(value).") }
        }
        for layer in [shared, light, dark] {
            for (token, value) in layer {
                guard EndpointThemeCatalog.tokens.contains(token) else { throw EndpointThemeError("Unknown color token: \(token).") }
                _ = try EndpointThemeColor.parse(value)
            }
        }
    }
}

public struct EndpointThemeError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum EndpointThemeColor: Equatable, Sendable {
    case reset
    case rgb(UInt32)
    case named(Int)

    public func rgbValue(ansi: [UInt32]) -> UInt32? {
        switch self {
        case .reset: return nil
        case .rgb(let value): return value
        case .named(let index): return ansi.indices.contains(index) ? ansi[index] : nil
        }
    }

    public static func parse(_ input: String) throws -> Self {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["reset", "default", "none", "transparent"].contains(value) { return .reset }
        if value.hasPrefix("#") {
            let hex = String(value.dropFirst())
            guard [3, 6].contains(hex.count), hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw EndpointThemeError("Invalid hex color: \(input).")
            }
            let expanded = hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : hex
            return .rgb(UInt32(expanded, radix: 16)!)
        }
        if value.hasPrefix("rgb("), value.hasSuffix(")") {
            let parts = value.dropFirst(4).dropLast().split(separator: ",", omittingEmptySubsequences: false)
            let numbers = parts.compactMap { UInt8($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 3, numbers.count == 3 else { throw EndpointThemeError("Invalid RGB color: \(input).") }
            return .rgb(UInt32(numbers[0]) << 16 | UInt32(numbers[1]) << 8 | UInt32(numbers[2]))
        }
        let names = ["black": 0, "red": 1, "green": 2, "yellow": 3, "blue": 4, "magenta": 5, "purple": 5,
                     "cyan": 6, "gray": 7, "grey": 7, "darkgray": 8, "darkgrey": 8, "lightred": 9,
                     "lightgreen": 10, "lightyellow": 11, "lightblue": 12, "lightmagenta": 13, "lightcyan": 14, "white": 15]
        guard let index = names[value] else { throw EndpointThemeError("Unknown color: \(input).") }
        return .named(index)
    }
}
