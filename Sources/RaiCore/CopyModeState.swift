import Foundation

public enum CopyModeSearchDirection: Equatable, Sendable {
    case forward
    case backward

    public var reversed: Self {
        self == .forward ? .backward : .forward
    }
}

public struct CopyModeSearchPrompt: Equatable, Sendable {
    public var direction: CopyModeSearchDirection
    public var query: String

    public init(direction: CopyModeSearchDirection, query: String = "") {
        self.direction = direction
        self.query = query
    }
}

public struct CopyModeMatch: Equatable, Sendable {
    public var start: ScrollbackSelectionModel.Point
    public var end: ScrollbackSelectionModel.Point

    public init(
        start: ScrollbackSelectionModel.Point,
        end: ScrollbackSelectionModel.Point
    ) {
        self.start = start
        self.end = end
    }
}

public struct CopyModeSearchResult: Equatable, Sendable {
    public var query: String
    public var direction: CopyModeSearchDirection
    public var matches: [CopyModeMatch]
    public var currentIndex: Int?
    public var isComplete: Bool

    public init(
        query: String,
        direction: CopyModeSearchDirection,
        matches: [CopyModeMatch],
        currentIndex: Int?,
        isComplete: Bool
    ) {
        self.query = query
        self.direction = direction
        self.matches = matches
        self.currentIndex = currentIndex
        self.isComplete = isComplete
    }
}

public enum CopyModeKey: Equatable, Sendable {
    case character(String)
    case controlCharacter(Character)
    case left
    case right
    case up
    case down
    case pageUp
    case pageDown
    case home
    case end
    case escape
    case enter
    case backspace
    case ignored
}

public enum CopyModeEffect: Equatable, Sendable {
    case none
    case exit
    case yank
    case search(query: String, direction: CopyModeSearchDirection, repeatSearch: Bool)
}

/// Pure modal state for keyboard selection over a pane's absolute buffer rows.
public struct CopyModeState: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case navigation
        case visual
        case search(CopyModeSearchPrompt)
    }

    public var mode: Mode
    public var cursor: ScrollbackSelectionModel.Point
    public var anchor: ScrollbackSelectionModel.Point?
    public var searchResult: CopyModeSearchResult?
    public var rowBounds: ClosedRange<Int>
    public var columns: Int
    public var viewportRows: Int

    public init(
        cursor: ScrollbackSelectionModel.Point,
        rowBounds: ClosedRange<Int>,
        columns: Int,
        viewportRows: Int
    ) {
        mode = .navigation
        self.cursor = cursor
        anchor = nil
        searchResult = nil
        self.rowBounds = rowBounds
        self.columns = max(1, columns)
        self.viewportRows = max(1, viewportRows)
        clampCursor()
    }

    /// Reduces one semantic key. AppKit owns paging and other side effects.
    @discardableResult
    public mutating func reduce(
        _ key: CopyModeKey,
        lines: [Int: String]
    ) -> CopyModeEffect {
        if case .search(var prompt) = mode {
            switch key {
            case .escape:
                mode = .navigation
            case .enter:
                guard !prompt.query.isEmpty else {
                    mode = .navigation
                    return .none
                }
                mode = .navigation
                return .search(
                    query: prompt.query,
                    direction: prompt.direction,
                    repeatSearch: false
                )
            case .backspace:
                if !prompt.query.isEmpty {
                    prompt.query.removeLast()
                }
                mode = .search(prompt)
            case .controlCharacter("u"):
                prompt.query = ""
                mode = .search(prompt)
            case .character(let text):
                prompt.query += text
                mode = .search(prompt)
            default:
                break
            }
            return .none
        }

        switch key {
        case .escape:
            if anchor != nil || searchResult != nil {
                anchor = nil
                searchResult = nil
                mode = .navigation
                return .none
            }
            return .exit
        case .enter:
            return .yank
        case .left:
            moveColumn(-1)
        case .right:
            moveColumn(1)
        case .up:
            moveRow(-1)
        case .down:
            moveRow(1)
        case .pageUp:
            moveRow(-pageLineCount)
        case .pageDown:
            moveRow(pageLineCount)
        case .home:
            cursor.col = 0
        case .end:
            moveToLineEnd(lines: lines)
        case .controlCharacter("b"):
            moveRow(-pageLineCount)
        case .controlCharacter("f"):
            moveRow(pageLineCount)
        case .controlCharacter("u"):
            moveRow(-max(1, viewportRows / 2))
        case .controlCharacter("d"):
            moveRow(max(1, viewportRows / 2))
        case .character(let text):
            return reduceCommand(text, lines: lines)
        case .backspace, .controlCharacter, .ignored:
            break
        }
        clampCursor()
        return .none
    }

    public mutating func applySearch(
        query: String,
        direction: CopyModeSearchDirection,
        matches: [CopyModeMatch],
        isComplete: Bool,
        repeatSearch: Bool
    ) {
        let previous = repeatSearch ? searchResult?.currentIndex : nil
        let index: Int?
        if matches.isEmpty {
            index = nil
        } else if direction == .forward {
            let origin = previous
                .flatMap { searchResult?.matches.indices.contains($0) == true
                    ? searchResult?.matches[$0].end
                    : nil
                } ?? cursor
            index = matches.firstIndex { point($0.start, isAfter: origin) } ?? 0
        } else {
            let origin = previous
                .flatMap { searchResult?.matches.indices.contains($0) == true
                    ? searchResult?.matches[$0].start
                    : nil
                } ?? cursor
            index = matches.lastIndex { point($0.end, isBefore: origin) }
                ?? matches.indices.last
        }
        searchResult = CopyModeSearchResult(
            query: query,
            direction: repeatSearch ? (searchResult?.direction ?? direction) : direction,
            matches: matches,
            currentIndex: index,
            isComplete: isComplete
        )
        if let index {
            cursor = matches[index].start
            clampCursor()
        }
    }

    /// Literal smart-case search. An uppercase query enables case sensitivity.
    public static func matches(
        query: String,
        in lines: [Int: String]
    ) -> [CopyModeMatch] {
        guard !query.isEmpty else { return [] }
        let caseSensitive = query.unicodeScalars.contains {
            CharacterSet.uppercaseLetters.contains($0)
        }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var matches: [CopyModeMatch] = []
        for row in lines.keys.sorted() {
            guard let line = lines[row] else { continue }
            var searchRange = line.startIndex..<line.endIndex
            while let range = line.range(
                of: query,
                options: options,
                range: searchRange,
                locale: nil
            ) {
                let start = TerminalTextCells.width(of: line[..<range.lowerBound])
                let length = TerminalTextCells.width(of: line[range])
                matches.append(CopyModeMatch(
                    start: .init(row: row, col: start),
                    end: .init(row: row, col: start + max(0, length - 1))
                ))
                guard range.lowerBound < line.endIndex else { break }
                let next = line.index(after: range.lowerBound)
                searchRange = next..<line.endIndex
            }
        }
        return matches
    }

    private var pageLineCount: Int {
        viewportRows <= 2 ? 1 : viewportRows - 2
    }

    private mutating func reduceCommand(
        _ text: String,
        lines: [Int: String]
    ) -> CopyModeEffect {
        switch text {
        case "q":
            return .exit
        case "y":
            return .yank
        case "v", " ":
            anchor = cursor
            mode = .visual
        case "h":
            moveColumn(-1)
        case "j":
            moveRow(1)
        case "k":
            moveRow(-1)
        case "l":
            moveColumn(1)
        case "g":
            cursor.row = rowBounds.lowerBound
        case "G":
            cursor.row = rowBounds.upperBound
        case "0":
            cursor.col = 0
        case "$":
            moveToLineEnd(lines: lines)
        case "^":
            cursor.col = firstNonBlankColumn(in: lines[cursor.row]) ?? 0
        case "/":
            mode = .search(.init(direction: .forward))
        case "?":
            mode = .search(.init(direction: .backward))
        case "n":
            guard let result = searchResult else { break }
            return .search(
                query: result.query,
                direction: result.direction,
                repeatSearch: true
            )
        case "N":
            guard let result = searchResult else { break }
            return .search(
                query: result.query,
                direction: result.direction.reversed,
                repeatSearch: true
            )
        case "w":
            moveWord(.nextStart, lines: lines)
        case "b":
            moveWord(.previousStart, lines: lines)
        case "e":
            moveWord(.nextEnd, lines: lines)
        case "{":
            moveParagraph(-1, lines: lines)
        case "}":
            moveParagraph(1, lines: lines)
        default:
            break
        }
        clampCursor()
        return .none
    }

    private mutating func moveRow(_ delta: Int) {
        cursor.row = min(max(cursor.row + delta, rowBounds.lowerBound), rowBounds.upperBound)
    }

    private mutating func moveColumn(_ delta: Int) {
        cursor.col = min(max(cursor.col + delta, 0), columns - 1)
    }

    private mutating func moveToLineEnd(lines: [Int: String]) {
        let cells = TerminalTextCells.cells(in: lines[cursor.row] ?? "")
        cursor.col = min(cells.last?.start ?? 0, columns - 1)
    }

    private mutating func clampCursor() {
        cursor.row = min(max(cursor.row, rowBounds.lowerBound), rowBounds.upperBound)
        cursor.col = min(max(cursor.col, 0), columns - 1)
    }

    private func firstNonBlankColumn(in line: String?) -> Int? {
        TerminalTextCells.cells(in: line ?? "")
            .first { !$0.character.isWhitespace }?
            .start
    }

    private enum WordMotion {
        case nextStart
        case previousStart
        case nextEnd
    }

    private enum TextClass: Equatable {
        case whitespace
        case separator
        case word
    }

    private struct TextAtom {
        let point: ScrollbackSelectionModel.Point
        let endColumn: Int
        let textClass: TextClass
    }

    private mutating func moveWord(_ motion: WordMotion, lines: [Int: String]) {
        let atoms = contiguousAtoms(lines: lines)
        guard let current = atoms.indices.first(where: {
            atoms[$0].point.row == cursor.row
                && cursor.col >= atoms[$0].point.col
                && cursor.col <= atoms[$0].endColumn
        }) else { return }

        let targetIndex: Int?
        switch motion {
        case .nextStart:
            var next = current + 1
            if atoms[current].textClass != .whitespace {
                while atoms.indices.contains(next),
                      atoms[next].textClass == atoms[current].textClass {
                    next += 1
                }
            }
            while atoms.indices.contains(next), atoms[next].textClass == .whitespace {
                next += 1
            }
            targetIndex = atoms.indices.contains(next) ? next : nil
        case .previousStart:
            var previous = current - 1
            while atoms.indices.contains(previous), atoms[previous].textClass == .whitespace {
                previous -= 1
            }
            guard atoms.indices.contains(previous) else { return }
            let textClass = atoms[previous].textClass
            while atoms.indices.contains(previous - 1),
                  atoms[previous - 1].textClass == textClass {
                previous -= 1
            }
            targetIndex = previous
        case .nextEnd:
            var next = current + 1
            while atoms.indices.contains(next), atoms[next].textClass == .whitespace {
                next += 1
            }
            guard atoms.indices.contains(next) else { return }
            let textClass = atoms[next].textClass
            while atoms.indices.contains(next + 1), atoms[next + 1].textClass == textClass {
                next += 1
            }
            targetIndex = next
        }
        if let targetIndex {
            cursor = atoms[targetIndex].point
        }
    }

    private func contiguousAtoms(lines: [Int: String]) -> [TextAtom] {
        guard lines[cursor.row] != nil else { return [] }
        var first = cursor.row
        var last = cursor.row
        while lines[first - 1] != nil { first -= 1 }
        while lines[last + 1] != nil { last += 1 }

        let separators = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^`{|}~")
        var atoms: [TextAtom] = []
        for row in first...last {
            let cells = TerminalTextCells.cells(in: lines[row] ?? "")
            for cell in cells {
                let textClass: TextClass
                if cell.character.isWhitespace {
                    textClass = .whitespace
                } else if cell.character.isASCII, separators.contains(cell.character) {
                    textClass = .separator
                } else {
                    textClass = .word
                }
                atoms.append(TextAtom(
                    point: .init(row: row, col: cell.start),
                    endColumn: cell.end,
                    textClass: textClass
                ))
            }
            if row < last {
                let lineEnd = min((cells.last?.end ?? -1) + 1, columns - 1)
                atoms.append(TextAtom(
                    point: .init(row: row, col: lineEnd),
                    endColumn: lineEnd,
                    textClass: .whitespace
                ))
            }
        }
        return atoms
    }

    private mutating func moveParagraph(_ direction: Int, lines: [Int: String]) {
        var row = cursor.row
        while true {
            let next = min(max(row + direction, rowBounds.lowerBound), rowBounds.upperBound)
            guard next != row else { return }
            row = next
            cursor.row = row
            if lines[row]?.trimmingCharacters(in: .whitespaces).isEmpty != false {
                return
            }
        }
    }

    private func point(
        _ lhs: ScrollbackSelectionModel.Point,
        isAfter rhs: ScrollbackSelectionModel.Point
    ) -> Bool {
        lhs.row > rhs.row || (lhs.row == rhs.row && lhs.col > rhs.col)
    }

    private func point(
        _ lhs: ScrollbackSelectionModel.Point,
        isBefore rhs: ScrollbackSelectionModel.Point
    ) -> Bool {
        lhs.row < rhs.row || (lhs.row == rhs.row && lhs.col < rhs.col)
    }
}
