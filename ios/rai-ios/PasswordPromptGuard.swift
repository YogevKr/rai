import Foundation
import SwiftTerm

enum PasswordPromptGuard {
    enum State: Equatable {
        case unknown
        case clear
        case prompt
    }

    static let waiting = "Waiting for the screen"
    static let verificationFailure = "Could not verify the screen — check the pane"
    static let refusal = "This is a password prompt — it shows nothing as you type, "
        + "so nothing sent from here can be verified. Use the keyboard (Type) to answer it yourself."

    private static let patterns = [
        #"^Enter passphrase( for [^:]{1,80})?:\s*$"#,
        #"^\[sudo\] password for [^:]{1,64}:\s*$"#,
        #"^.{1,64}'s password:\s*$"#,
        #"^Password:\s*$"#,
        #"^Passphrase:\s*$"#,
    ]

    static func isPasswordPrompt(_ grid: String) -> Bool {
        guard let row = grid.components(separatedBy: .newlines).last(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else {
            return false
        }
        return patterns.contains {
            row.range(of: $0, options: .regularExpression) != nil
        }
    }

    static func refusalMessage(droppedQueuedLines: Int) -> String {
        guard droppedQueuedLines > 0 else { return refusal }
        let suffix = droppedQueuedLines == 1
            ? "1 queued line for this pane was dropped."
            : "\(droppedQueuedLines) queued lines for this pane were dropped."
        return refusal + " " + suffix
    }
}

final class PasswordPromptGridReader {
    private let delegate = PasswordPromptTerminalDelegate()
    private var terminals: [String: Terminal] = [:]

    func apply(data: Data, full: Bool, size: PaneGridSize?, paneID: String) -> String? {
        guard full || terminals[paneID] != nil else { return nil }
        let terminal = terminals[paneID] ?? Terminal(delegate: delegate)
        terminals[paneID] = terminal
        if let size, terminal.cols != size.cols || terminal.rows != size.rows {
            terminal.resize(cols: size.cols, rows: size.rows)
        }
        if full {
            terminal.feed(byteArray: [0x1B, 0x5B, 0x48, 0x1B, 0x5B, 0x32, 0x4A])
        }
        terminal.feed(byteArray: [UInt8](data))
        guard let text = String(data: terminal.getBufferAsData(), encoding: .utf8) else {
            return nil
        }
        var rows = text.components(separatedBy: "\n")
        if rows.last?.isEmpty == true {
            rows.removeLast()
        }
        return rows.suffix(terminal.rows).joined(separator: "\n")
    }

    func remove(_ paneID: String) {
        terminals.removeValue(forKey: paneID)
    }

    func removeAll() {
        terminals.removeAll()
    }
}

private final class PasswordPromptTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
