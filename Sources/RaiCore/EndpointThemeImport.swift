import Foundation

/// Reads Herdr's documented theme tables. It never reads or writes host configuration.
/// Rejects unsupported TOML constructs within theme tables instead of accepting partial settings.
public struct EndpointThemeSettings: Sendable {
    public let theme: EndpointTheme
    public let borders: EndpointBorderMode?
}

public enum EndpointThemeImport {
    public static let maximumBytes = 1_048_576

    public static func parse(_ source: String) throws -> EndpointTheme {
        try parseSettings(source).theme
    }

    public static func parseSettings(_ source: String) throws -> EndpointThemeSettings {
        guard source.utf8.count <= maximumBytes else { throw EndpointThemeError("Theme file exceeds 1 MB.") }
        var theme = EndpointTheme()
        theme.name = "catppuccin"
        theme.autoSwitch = false
        var borders: EndpointBorderMode?
        var section = ""
        var sections: Set<String> = []
        var keys: Set<String> = []
        var foundTheme = false
        for (offset, raw) in source.components(separatedBy: .newlines).enumerated() {
            do {
                let line = uncomment(raw).trimmingCharacters(in: .whitespaces)
                guard !line.contains("\"\"\"") && !line.contains("'''") else {
                    throw EndpointThemeError("Multiline TOML strings are unsupported. Import the theme tables separately.")
                }
                if line.isEmpty { continue }
                if line.hasPrefix("[") {
                    section = try sectionName(line, seen: &sections)
                    foundTheme = foundTheme || section == "theme" || section.hasPrefix("theme.")
                    continue
                }
                guard section == "theme" || section.hasPrefix("theme.") || section == "ui" else { continue }
                guard let equal = line.firstIndex(of: "=") else { throw EndpointThemeError("Expected a color or theme assignment.") }
                let key = line[..<equal].trimmingCharacters(in: .whitespaces)
                if section == "ui" && key != "pane_borders" { continue }
                guard keys.insert(section + "." + key).inserted else { throw EndpointThemeError("Duplicate setting: \(key).") }
                let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
                if section == "ui" {
                    borders = try borderMode(value)
                } else {
                    try assign(key, value: value, section: section, theme: &theme)
                }
            } catch {
                throw EndpointThemeError("Line \(offset + 1): \(error.localizedDescription)")
            }
        }
        guard foundTheme else { throw EndpointThemeError("No theme table found. Import a file with [theme] or [theme.custom].") }
        try theme.validate()
        return EndpointThemeSettings(theme: theme, borders: borders)
    }

    private static func sectionName(_ line: String, seen: inout Set<String>) throws -> String {
        guard line.hasSuffix("]") else { throw EndpointThemeError("Invalid table header.") }
        let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard name == "theme" || name.hasPrefix("theme.") else { return name }
        guard ["theme", "theme.custom", "theme.custom.light", "theme.custom.dark"].contains(name) else {
            throw EndpointThemeError("Use [theme], [theme.custom], [theme.custom.light], or [theme.custom.dark].")
        }
        guard seen.insert(name).inserted else { throw EndpointThemeError("Duplicate table: \(name).") }
        return name
    }

    private static func borderMode(_ value: String) throws -> EndpointBorderMode {
        let configuration: JSONValue
        if ["true", "false"].contains(value) { configuration = .bool(value == "true") }
        else { configuration = .string(try string(value)) }
        guard let mode = EndpointBorderMode(configuration: configuration) else {
            throw EndpointThemeError("pane_borders must be true, false, always, auto, or off.")
        }
        return mode
    }

    private static func assign(_ key: String, value: String, section: String, theme: inout EndpointTheme) throws {
        if section == "theme" {
            switch key {
            case "name": theme.name = try themeName(value)
            case "light_name": theme.lightName = try themeName(value)
            case "dark_name": theme.darkName = try themeName(value)
            case "auto_switch":
                guard ["true", "false"].contains(value) else { throw EndpointThemeError("auto_switch must be true or false.") }
                theme.autoSwitch = value == "true"
            default: throw EndpointThemeError("Unsupported theme setting: \(key). Use the documented theme tables.")
            }
            return
        }
        guard EndpointThemeCatalog.tokens.contains(key) else { throw EndpointThemeError("Unknown color token: \(key).") }
        let color = try string(value)
        _ = try EndpointThemeColor.parse(color)
        switch section {
        case "theme.custom": theme.shared[key] = color
        case "theme.custom.light": theme.light[key] = color
        case "theme.custom.dark": theme.dark[key] = color
        default: break
        }
    }

    private static func themeName(_ value: String) throws -> String {
        let name = try string(value)
        guard let canonical = EndpointThemeCatalog.canonicalName(name) else {
            throw EndpointThemeError("Unknown theme: \(name).")
        }
        return canonical
    }

    private static func string(_ value: String) throws -> String {
        if value.first == "'", value.last == "'", value.count >= 2, !value.dropFirst().dropLast().contains("'") {
            return String(value.dropFirst().dropLast())
        }
        if value.first == "\"", let data = value.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        throw EndpointThemeError("Use a single-line quoted string. Multiline strings and inline tables are unsupported.")
    }

    private static func uncomment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped { escaped = false; continue }
            if quote == "\"", character == "\\" { escaped = true; continue }
            if let active = quote {
                if character == active { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(line[..<index])
            }
        }
        return line
    }
}
