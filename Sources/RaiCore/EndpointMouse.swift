import Foundation

/// Coordinates address the captured terminal, not the window or another pane.
public struct EndpointMouse: Codable, Sendable, Equatable {
    public enum Kind: UInt8, Codable, Sendable {
        case down, up, drag, moved, scrollUp, scrollDown, scrollLeft, scrollRight
    }
    public enum Button: UInt8, Codable, Sendable, Hashable { case left, right, middle }
    public let kind: Kind
    public let button: Button?
    public let column, row, columns, rows: UInt16
    public let pixelX, pixelY, pixelWidth, pixelHeight: UInt32?
    public let modifiers: UInt8
    public let lines: UInt16

    public init(kind: Kind, button: Button? = nil, column: UInt16, row: UInt16,
                columns: UInt16, rows: UInt16, pixelX: UInt32? = nil, pixelY: UInt32? = nil,
                pixelWidth: UInt32? = nil, pixelHeight: UInt32? = nil,
                modifiers: UInt8 = 0, lines: UInt16 = 1) {
        self.kind = kind; self.button = button
        self.column = column; self.row = row; self.columns = columns; self.rows = rows
        self.pixelX = pixelX; self.pixelY = pixelY
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.modifiers = modifiers; self.lines = lines
    }

    public var isValid: Bool {
        guard columns > 0, rows > 0, column < columns, row < rows,
              modifiers & 0xf0 == 0, (1...120).contains(lines),
              (kind.rawValue <= Kind.drag.rawValue) == (button != nil) else { return false }
        let values = [pixelX, pixelY, pixelWidth, pixelHeight]
        if values.allSatisfy({ $0 == nil }) { return true }
        guard let x = pixelX, let y = pixelY, let width = pixelWidth, let height = pixelHeight,
              width > 0, height > 0, x > 0, y > 0, x <= width, y <= height else { return false }
        return UInt64(x - 1) * UInt64(columns) / UInt64(width) == UInt64(column)
            && UInt64(y - 1) * UInt64(rows) / UInt64(height) == UInt64(row)
    }

    func encode(to data: inout Data) {
        data.append(2) // ClientPaneInputEvent::Mouse
        data.append(kind.rawValue)
        if let button { data.append(button.rawValue) }
        data.append(pixelX == nil ? 0 : 1)
        if let x = pixelX, let y = pixelY {
            HerdrEndpointWire.appendInteger(UInt64(x), to: &data)
            HerdrEndpointWire.appendInteger(UInt64(y), to: &data)
        }
        HerdrEndpointWire.appendInteger(UInt64(column), to: &data)
        HerdrEndpointWire.appendInteger(UInt64(row), to: &data)
        data.append(pixelWidth == nil ? 0 : 1)
        if let width = pixelWidth, let height = pixelHeight {
            for value in [UInt64(columns), UInt64(rows), UInt64(width), UInt64(height)] {
                HerdrEndpointWire.appendInteger(value, to: &data)
            }
        }
        data.append(modifiers)
        HerdrEndpointWire.appendInteger(UInt64(lines), to: &data)
    }
}

public struct EndpointMouseTarget: Sendable {
    public let paneID: String
    public let input: EndpointMouse

    public var released: Self? {
        guard let button = input.button else { return nil }
        let release = EndpointMouse(kind: .up, button: button, column: input.column, row: input.row,
            columns: input.columns, rows: input.rows, pixelX: input.pixelX, pixelY: input.pixelY,
            pixelWidth: input.pixelWidth, pixelHeight: input.pixelHeight, modifiers: input.modifiers)
        return Self(paneID: paneID, input: release)
    }
}

extension HerdrEndpointSurface {
    /// The view supplies fractional grid coordinates. Popup content owns all input while visible.
    public func mouse(atColumn column: Double, row: Double, kind: EndpointMouse.Kind,
                      button: EndpointMouse.Button? = nil, modifiers: UInt8 = 0,
                      lines: UInt16 = 1) -> EndpointMouseTarget? {
        guard column.isFinite, row.isFinite, column >= 0, row >= 0,
              column < Double(grid.width), row < Double(grid.height),
              let focused = panes.first(where: \.focused) else { return nil }
        let originX, originY, width, height: Double
        let pixelWidth, pixelHeight: UInt32
        let pixels: Bool
        if let popup, let origin = popupOrigin {
            guard popup.mouseReporting else { return nil }
            originX = Double(origin.x); originY = Double(origin.y)
            width = Double(popup.grid.width); height = Double(popup.grid.height)
            pixelWidth = popup.pixelWidth; pixelHeight = popup.pixelHeight; pixels = popup.pixelMouse
        } else {
            guard focused.mouseReporting else { return nil }
            originX = Double(focused.innerRect.x); originY = Double(focused.innerRect.y)
            width = Double(focused.innerRect.width); height = Double(focused.innerRect.height)
            pixelWidth = focused.pixelWidth; pixelHeight = focused.pixelHeight; pixels = focused.pixelMouse
        }
        let x = column - originX, y = row - originY
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let px = pixels ? Self.mousePixel(x, cells: UInt16(width), pixels: pixelWidth) : nil
        let py = pixels ? Self.mousePixel(y, cells: UInt16(height), pixels: pixelHeight) : nil
        let usePixels = px != nil && py != nil
        let input = EndpointMouse(kind: kind, button: button, column: UInt16(x), row: UInt16(y),
            columns: UInt16(width), rows: UInt16(height),
            pixelX: usePixels ? px : nil,
            pixelY: usePixels ? py : nil,
            pixelWidth: usePixels ? pixelWidth : nil, pixelHeight: usePixels ? pixelHeight : nil,
            modifiers: modifiers, lines: lines)
        guard input.isValid else { return nil }
        return EndpointMouseTarget(paneID: focused.paneID, input: input)
    }

    private static func mousePixel(_ coordinate: Double, cells: UInt16, pixels: UInt32) -> UInt32? {
        guard cells > 0, pixels > 0 else { return nil }
        let cell = UInt64(coordinate), count = UInt64(cells), size = UInt64(pixels)
        let lower = (cell * size + count - 1) / count
        let upper = ((cell + 1) * size + count - 1) / count
        guard lower < upper else { return nil }
        let proposed = UInt64(coordinate * Double(pixels) / Double(cells))
        return UInt32(min(upper - 1, max(lower, proposed)) + 1)
    }
}

/// A press keeps its target until release. Observed identity changes cancel it permanently.
public struct EndpointMouseCapture: Sendable {
    private let bootID: String
    private let popupID: String?
    public private(set) var target: EndpointMouseTarget
    public private(set) var isValid = true

    public init(target: EndpointMouseTarget, surface: HerdrEndpointSurface) {
        self.target = target
        bootID = surface.bootID
        popupID = surface.popup?.terminalID
        isValid = target.input.kind == .down && target.input.isValid
            && surface.panes.first(where: \.focused)?.paneID == target.paneID
    }

    public mutating func observe(_ surface: HerdrEndpointSurface?) {
        guard let surface else { isValid = false; return }
        isValid = isValid && surface.bootID == bootID && surface.popup?.terminalID == popupID
            && surface.panes.first(where: \.focused)?.paneID == target.paneID
    }

    public mutating func drag(_ next: EndpointMouseTarget, in surface: HerdrEndpointSurface) -> EndpointMouseTarget? {
        observe(surface)
        guard isValid, next.paneID == target.paneID, next.input.kind == .drag,
              next.input.button == target.input.button, next.input.isValid else { return nil }
        target = next
        return next
    }

    public mutating func release(in surface: HerdrEndpointSurface) -> EndpointMouseTarget? {
        observe(surface)
        defer { isValid = false }
        guard isValid, let pane = surface.panes.first(where: { $0.paneID == target.paneID }) else { return nil }
        let width = surface.popup?.grid.width ?? pane.innerRect.width
        let height = surface.popup?.grid.height ?? pane.innerRect.height
        guard width > 0, height > 0 else { return nil }
        let pixels = surface.popup?.pixelMouse ?? pane.pixelMouse
        let pixelWidth = surface.popup?.pixelWidth ?? pane.pixelWidth
        let pixelHeight = surface.popup?.pixelHeight ?? pane.pixelHeight
        if pixels, target.input.columns == width, target.input.rows == height,
           target.input.pixelWidth == pixelWidth, target.input.pixelHeight == pixelHeight {
            return target.released
        }
        // Cell coordinates remain valid after a resize; old pixel geometry does not.
        let input = EndpointMouse(kind: .up, button: target.input.button,
            column: min(target.input.column, width - 1), row: min(target.input.row, height - 1),
            columns: width, rows: height, modifiers: target.input.modifiers)
        return EndpointMouseTarget(paneID: target.paneID, input: input)
    }
}
