import Foundation

public enum EndpointBorderMode: String, Codable, CaseIterable, Sendable {
    case always, auto, off

    /// Preserve Herdr's earlier boolean configuration when importing a border setting.
    public init?(configuration: JSONValue) {
        switch configuration {
        case .bool(let enabled): self = enabled ? .always : .off
        case .string(let value):
            guard let mode = Self(rawValue: value) else { return nil }
            self = mode
        default: return nil
        }
    }

    public func isVisible(paneCount: Int) -> Bool {
        self == .always || (self == .auto && paneCount > 1)
    }
}
