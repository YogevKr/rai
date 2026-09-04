import Foundation

/// Where a ⌘-clicked terminal link goes.
enum LinkOpenTarget: Equatable {
    /// A URL with a scheme: hand it to the default handler for that scheme.
    case url(URL)
    /// A file or directory that exists on this Mac.
    case file(URL)
    /// Nothing on this Mac matches the text. Do nothing, and never show an alert.
    case unresolved
}

/// Turns SwiftTerm's link text into something `NSWorkspace` can open.
///
/// SwiftTerm's Ghostty-style detector matches bare paths (`~/x.html`,
/// `./src/a.swift:12`, `/tmp`) as well as URLs, and its default handler passes
/// each one straight to `NSWorkspace.open` as a scheme-less URL. LaunchServices
/// rejects those with paramErr and Finder shows "The application can't be
/// opened. -50". This resolver expands `~` and `$VAR`, resolves relative paths
/// against the pane's working directory, drops a trailing `:line:col` or stray
/// punctuation the detector swallowed, and only yields a target that exists.
enum LinkOpenResolver {
    /// `file:` URLs go through the path branch so a missing file stays silent.
    private static let trailingPunctuation: Set<Character> = [";", ",", ".", ":", "!", "?", ")", "]", "}", "'", "\"", ">"]

    /// Schemes that mean "this is a URL, not a path". `URL(string:)` reports a
    /// scheme for any `token:rest`, so a bare citation like `README:12` parses
    /// as scheme `README`; without this gate it would be sent to a nonexistent
    /// handler and beep instead of opening the file. The set mirrors what
    /// SwiftTerm's own detector recognizes, plus `sms`. An authority URL
    /// (`vscode://…`) is admitted by its `scheme://` shape even when unlisted.
    private static let urlSchemes: Set<String> = [
        "http", "https", "mailto", "ftp", "file", "ssh", "git",
        "tel", "magnet", "ipfs", "ipns", "gemini", "gopher", "news", "sms",
    ]

    static func resolve(
        _ link: String,
        cwd: String?,
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> LinkOpenTarget {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .unresolved }

        var pathText = text
        if let url = URL(string: text), let rawScheme = url.scheme, !rawScheme.isEmpty {
            let scheme = rawScheme.lowercased()
            let isURL = urlSchemes.contains(scheme)
                || text.lowercased().hasPrefix("\(scheme)://")
            if isURL {
                guard scheme == "file" else { return .url(url) }
                pathText = url.path.isEmpty ? String(text.dropFirst("file:".count)) : url.path
            }
        }

        for candidate in candidates(for: pathText) {
            guard let path = absolutePath(
                for: candidate,
                cwd: cwd,
                home: home,
                environment: environment
            ) else { continue }
            if fileExists(path) {
                return .file(URL(fileURLWithPath: path))
            }
        }
        return .unresolved
    }

    /// The raw text first, then progressively shorter variants: without a
    /// `:line[:col]` suffix, and without trailing punctuation the detector
    /// included (`~/a.html;`, `(see ./b.swift)`). First existing path wins.
    static func candidates(for text: String) -> [String] {
        var seen: [String] = []
        var current = text
        for _ in 0..<4 {
            append(current, to: &seen)
            if let stripped = strippingLineColumnSuffix(current) {
                append(stripped, to: &seen)
            }
            guard let last = current.last, trailingPunctuation.contains(last) else { break }
            current = String(current.dropLast())
            guard !current.isEmpty else { break }
        }
        return seen
    }

    private static func append(_ value: String, to list: inout [String]) {
        guard !value.isEmpty, !list.contains(value) else { return }
        list.append(value)
    }

    /// `path:12` and `path:12:3` are how compilers and Claude cite locations.
    static func strippingLineColumnSuffix(_ text: String) -> String? {
        let pattern = #":\d+(?::\d+)?$"#
        guard let range = text.range(of: pattern, options: .regularExpression),
              range.lowerBound > text.startIndex else { return nil }
        return String(text[..<range.lowerBound])
    }

    static func absolutePath(
        for candidate: String,
        cwd: String?,
        home: String,
        environment: [String: String]
    ) -> String? {
        let expanded: String
        if candidate.hasPrefix("~") {
            expanded = expandingTilde(candidate, home: home)
        } else if candidate.hasPrefix("$") {
            guard let value = expandingVariable(candidate, environment: environment) else { return nil }
            expanded = value
        } else if candidate.hasPrefix("/") {
            expanded = candidate
        } else {
            guard let cwd, !cwd.isEmpty else { return nil }
            expanded = expandingTilde(cwd, home: home) + "/" + candidate
        }
        let standardized = (expanded as NSString).standardizingPath
        guard standardized.hasPrefix("/") else { return nil }
        return standardized
    }

    private static func expandingTilde(_ path: String, home: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else {
            // `~user/...`: let Foundation look the account up.
            return (path as NSString).expandingTildeInPath
        }
        return home + path.dropFirst()
    }

    /// `$HOME/x` or `${HOME}/x`; an unknown variable yields nil rather than a
    /// guess, so the click stays silent instead of opening the wrong thing.
    private static func expandingVariable(_ path: String, environment: [String: String]) -> String? {
        let body = path.dropFirst()
        let name: Substring
        let rest: Substring
        if body.hasPrefix("{") {
            guard let close = body.firstIndex(of: "}") else { return nil }
            name = body[body.index(after: body.startIndex)..<close]
            rest = body[body.index(after: close)...]
        } else {
            let end = body.firstIndex { !($0.isLetter || $0.isNumber || $0 == "_") } ?? body.endIndex
            name = body[..<end]
            rest = body[end...]
        }
        guard !name.isEmpty, let value = environment[String(name)], !value.isEmpty else { return nil }
        return value + rest
    }
}
