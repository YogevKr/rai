import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class EndpointClipboard: ObservableObject {
    static let failureMessage = "Copy failed. The selection remains available."
    @Published private(set) var message: String?
    private let writer: (String) -> Bool
    #if DEBUG
    private static var failNextWrite = requestsLabFailure(bundleIdentifier: Bundle.main.bundleIdentifier,
        environment: ProcessInfo.processInfo.environment)
    #endif

    init(writer: ((String) -> Bool)? = nil) {
        self.writer = writer ?? Self.writeSystemClipboard
    }

    @discardableResult
    func copy(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        #if DEBUG
        if Self.failNextWrite {
            Self.failNextWrite = false
            message = Self.failureMessage
            return false
        }
        #endif
        let written = writer(text)
        message = written ? nil : Self.failureMessage
        return written
    }

    func dismissFailure() { message = nil }

    private static func writeSystemClipboard(_ text: String) -> Bool {
        #if os(macOS)
        let board = NSPasteboard.general
        board.clearContents()
        return board.setString(text, forType: .string)
        #else
        return writeUIKitClipboard(text, to: .general)
        #endif
    }

    #if os(iOS)
    static func writeUIKitClipboard(_ text: String, to board: UIPasteboard) -> Bool {
        let previous = board.changeCount
        board.string = text
        // UIKit's setter returns no receipt. Verify our synchronous write before reporting success.
        return board.changeCount != previous && board.string == text
    }
    #endif

    #if DEBUG
    static func requestsLabFailure(bundleIdentifier: String?, environment: [String: String]) -> Bool {
        guard environment["RAI_LAB_FAIL_NEXT_COPY"] == "1", let bundleIdentifier else { return false }
        return bundleIdentifier.hasPrefix("gr.krig.rai.lab.")
            || bundleIdentifier.hasPrefix("com.whetstone.rai.ios.lab.")
    }
    #endif
}

struct EndpointClipboardNotice: View {
    @ObservedObject var clipboard: EndpointClipboard

    var body: some View {
        if let message = clipboard.message {
            HStack {
                Text(message).accessibilityIdentifier("endpoint.copy.failure")
                Button("Dismiss") { clipboard.dismissFailure() }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(8)
        }
    }
}

#if os(macOS)
final class EndpointSelectableTextView: NSTextView {
    var clipboard = EndpointClipboard()

    override func moveToBeginningOfDocument(_ sender: Any?) {
        // Read-only NSTextView otherwise scrolls without moving its selection.
        setSelectedRange(NSRange(location: 0, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    override func moveToEndOfDocument(_ sender: Any?) {
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        scrollRangeToVisible(selectedRange())
    }


    func moveSelection(_ motion: EndpointSelectionMotion, extending: Bool) {
        switch (motion, extending) {
        case (.characterBackward, false): moveBackward(nil)
        case (.characterBackward, true): moveBackwardAndModifySelection(nil)
        case (.characterForward, false): moveForward(nil)
        case (.characterForward, true): moveForwardAndModifySelection(nil)
        case (.wordBackward, false): moveWordBackward(nil)
        case (.wordBackward, true): moveWordBackwardAndModifySelection(nil)
        case (.wordForward, false): moveWordForward(nil)
        case (.wordForward, true): moveWordForwardAndModifySelection(nil)
        case (.lineStart, false): moveToBeginningOfLine(nil)
        case (.lineStart, true): moveToBeginningOfLineAndModifySelection(nil)
        case (.lineEnd, false): moveToEndOfLine(nil)
        case (.lineEnd, true): moveToEndOfLineAndModifySelection(nil)
        case (.documentStart, false): moveToBeginningOfDocument(nil)
        case (.documentStart, true): moveToBeginningOfDocumentAndModifySelection(nil)
        case (.documentEnd, false): moveToEndOfDocument(nil)
        case (.documentEnd, true): moveToEndOfDocumentAndModifySelection(nil)
        }
        scrollRangeToVisible(selectedRange())
    }

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (string as NSString).length else { return }
        clipboard.copy((string as NSString).substring(with: range))
    }
}
#else
final class EndpointSelectableTextView: UITextView {
    var clipboard = EndpointClipboard()
    private var motionAnchor: Int?
    private var motionHead: Int?
    private var motionRange: NSRange?

    func moveSelection(_ motion: EndpointSelectionMotion, extending: Bool) {
        // Native handles and search can replace the selection between commands.
        if motionRange != selectedRange {
            motionAnchor = selectedRange.location
            motionHead = NSMaxRange(selectedRange)
        }
        let head: Int
        if !extending, selectedRange.length > 0, motion.granularity == .character {
            // An unmodified arrow collapses a selection before moving another character.
            head = motion.backward ? selectedRange.location : NSMaxRange(selectedRange)
        } else {
            guard let start = position(from: beginningOfDocument, offset: motionHead ?? selectedRange.location),
                  let target = tokenizer.position(from: start, toBoundary: motion.granularity, inDirection: motion.direction) else { return }
            head = offset(from: beginningOfDocument, to: target)
        }
        let anchor = extending ? (motionAnchor ?? selectedRange.location) : head
        selectedRange = NSRange(location: min(anchor, head), length: abs(head - anchor))
        motionAnchor = anchor
        motionHead = head
        motionRange = selectedRange
        scrollRangeToVisible(selectedRange)
    }

    override var keyCommands: [UIKeyCommand]? {
        let motions = EndpointSelectionMotion.allCases.flatMap { motion in
            [false, true].map { extending in
                let command = UIKeyCommand(input: motion.keyInput,
                    modifierFlags: motion.keyModifiers.union(extending ? .shift : []),
                    action: #selector(moveCapturedSelection(_:)))
                command.discoverabilityTitle = (extending ? "Select: " : "Move: ") + motion.rawValue
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }
        return motions + (super.keyCommands ?? [])
    }

    @objc func moveCapturedSelection(_ command: UIKeyCommand) {
        let modifiers = command.modifierFlags.subtracting(.shift)
        guard let motion = EndpointSelectionMotion.allCases.first(where: {
            $0.keyInput == command.input && $0.keyModifiers == modifiers
        }) else { return }
        moveSelection(motion, extending: command.modifierFlags.contains(.shift))
    }

    override func copy(_ sender: Any?) {
        guard let range = selectedTextRange, let selected = text(in: range), !selected.isEmpty else { return }
        clipboard.copy(selected)
    }
}
#endif

#if os(iOS)
private extension EndpointSelectionMotion {
    var backward: Bool {
        [.characterBackward, .wordBackward, .lineStart, .documentStart].contains(self)
    }
    var direction: UITextDirection {
        UITextDirection(rawValue: backward ? UITextStorageDirection.backward.rawValue : UITextStorageDirection.forward.rawValue)
    }
    var granularity: UITextGranularity {
        switch self {
        case .characterBackward, .characterForward: .character
        case .wordBackward, .wordForward: .word
        case .lineStart, .lineEnd: .line
        case .documentStart, .documentEnd: .document
        }
    }
    var keyInput: String {
        switch self {
        case .documentStart: UIKeyCommand.inputUpArrow
        case .documentEnd: UIKeyCommand.inputDownArrow
        default: backward ? UIKeyCommand.inputLeftArrow : UIKeyCommand.inputRightArrow
        }
    }
    var keyModifiers: UIKeyModifierFlags {
        switch self {
        case .characterBackward, .characterForward: []
        case .wordBackward, .wordForward: .alternate
        case .lineStart, .lineEnd, .documentStart, .documentEnd: .command
        }
    }
}
#endif
