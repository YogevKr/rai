import Foundation

public enum EndpointGraphicsPolicy: Equatable, Sendable {
    case enabled, disabled, unknown(String)

    public var warning: String? {
        if case .unknown(let reason) = self { return "Image settings are unknown. \(reason)" }
        return nil
    }

    public func apply(to surface: HerdrEndpointSurface) -> HerdrEndpointSurface {
        guard self != .enabled else { return surface }
        var result = surface
        result.graphics = EndpointGraphicsScene(assets: [], placements: [], retained: [])
        return result
    }
}

/// Local policy can change graphics without advancing the server's surface revision.
public struct EndpointSurfaceRenderKey: Equatable, Sendable {
    public let bootID: String
    private let revision: UInt64
    private let graphics: EndpointGraphicsScene

    public init(_ surface: HerdrEndpointSurface) {
        bootID = surface.bootID
        revision = surface.revision
        graphics = surface.graphics
    }
}
