import AppKit
import MetalKit
@testable import SwiftTerm
import XCTest

@testable import RaiApp

/// Uses the production preference without writing any persistent defaults.
@MainActor
struct TerminalRendererProbeConfiguration {
    let name: String?
    private let savedArguments: [String: Any]
    private let stagedShader: URL?

    init(required: Bool = false) throws {
        name = ProcessInfo.processInfo.environment["RAI_TEST_TERMINAL_RENDERER"]
        if required && name == nil {
            throw XCTSkip("Set RAI_TEST_TERMINAL_RENDERER=cg or metal to run visible renderer probes.")
        }
        savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        // SwiftTerm's safe shader lookup checks its host bundle. Under XCTest,
        // SwiftPM puts the resource bundle beside that host instead of inside it.
        // Stage only the missing test resource, then remove our copy at teardown.
        if name == "metal" {
            let source = try XCTUnwrap(Bundle.module.url(forResource: "Shaders", withExtension: "metal"))
            let host = Bundle(for: TerminalRendererProbeTests.self)
            let resources = host.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
            let destination = resources.appendingPathComponent("Shaders.metal")
            if FileManager.default.fileExists(atPath: destination.path) {
                guard try Data(contentsOf: source) == Data(contentsOf: destination) else {
                    throw NSError(domain: "TerminalRendererProbe", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "The test host already contains different Metal shaders."
                    ])
                }
                stagedShader = nil
            } else {
                try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: destination)
                stagedShader = destination
            }
        } else {
            stagedShader = nil
        }
        if let name {
            guard name == "cg" || name == "metal" else {
                throw NSError(domain: "TerminalRendererProbe", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "RAI_TEST_TERMINAL_RENDERER must be cg or metal."
                ])
            }
            var arguments = savedArguments
            arguments["terminalMetalRenderer"] = name == "metal"
            arguments["terminalMetalBuffering"] = "aggregated"
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
    }

    func restore() {
        if name != nil {
            UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
        }
        if let stagedShader { try? FileManager.default.removeItem(at: stagedShader) }
    }

    func verify(_ view: FocusAwareTerminalView, file: StaticString = #filePath, line: UInt = #line) {
        if let name {
            XCTAssertEqual(view.isUsingMetalRenderer, name == "metal", file: file, line: line)
        }
    }
}

@MainActor
final class TerminalRendererProbeTests: XCTestCase {
    private var configuration: TerminalRendererProbeConfiguration?
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        configuration = try TerminalRendererProbeConfiguration(required: true)
        _ = NSApplication.shared
    }

    override func tearDownWithError() throws {
        for window in windows {
            (window.contentView as? FocusAwareTerminalView)?.terminate()
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
        configuration?.restore()
        configuration = nil
    }

    private func host(_ view: FocusAwareTerminalView? = nil) -> FocusAwareTerminalView {
        let frame = NSRect(x: 160, y: 180, width: 960, height: 600)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Rai renderer probe — \(configuration?.name ?? "default")"
        window.isReleasedWhenClosed = false
        let terminal = view ?? FocusAwareTerminalView(frame: NSRect(origin: .zero, size: frame.size))
        terminal.allowMouseReporting = false
        terminal.configurePredictiveEcho(for: nil)
        window.contentView = terminal
        window.makeFirstResponder(terminal)
        window.orderFrontRegardless()
        windows.append(window)
        configuration?.verify(terminal)
        return terminal
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }

    func testSelectionSurvivesOutputAndLocalScrollback() async throws {
        let view = host()
        view.feed(text: "SELECT THIS\r\n")
        view.setSelectionRange(start: Position(col: 0, row: 0), end: Position(col: 11, row: 0))
        for index in 0..<10 { view.feed(text: "output \(index)\r\n") }
        try await settle()
        XCTAssertEqual(view.getSelection(), "SELECT THIS")
        var copied: String?
        view.clipboardWriter = { copied = $0; return true }
        view.copy(self)
        XCTAssertEqual(copied, "SELECT THIS")
        view.selectNone()
        view.feed(text: (0..<150).map { "history \($0)\r\n" }.joined())
        XCTAssertTrue(view.canScroll)
        view.scroll(toPosition: 0)
        try await settle()
        XCTAssertEqual(view.scrollPosition, 0, accuracy: 0.001)
        view.setSelectionRange(start: Position(col: 0, row: 0), end: Position(col: 11, row: 0))
        XCTAssertEqual(view.getSelection(), "SELECT THIS")
        view.scroll(toPosition: 1)
        try await settle()
        XCTAssertEqual(view.scrollPosition, 1, accuracy: 0.001)
        configuration?.verify(view)
    }

    private func preserveFindPasteboard() -> () -> Void {
        // SwiftTerm uses the shared Find pasteboard. Preserve all its formats.
        let pasteboard = NSPasteboard(name: .find)
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        return {
            pasteboard.clearContents()
            let items = saved.map { formats in
                let item = NSPasteboardItem()
                for (type, data) in formats { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
    }

    func testSearchBarStaysAboveRendererAndFindsText() async throws {
        let restorePasteboard = preserveFindPasteboard()
        defer { restorePasteboard() }
        let view = host()
        view.feed(text: "needle one\r\nneedle two\r\n")
        view.setSelectionRange(start: Position(col: 0, row: 0), end: Position(col: 6, row: 0))
        let action = NSMenuItem()
        action.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.performTextFinderAction(action)
        view.layoutSubtreeIfNeeded()
        try await settle()
        let bar = try XCTUnwrap(view.subviews.first { $0 is TerminalFindBarView })
        XCTAssertFalse(bar.isHidden)
        XCTAssertGreaterThan(bar.bounds.height, 0)
        if let metalIndex = view.subviews.firstIndex(where: { $0 is MTKView }) {
            XCTAssertGreaterThan(try XCTUnwrap(view.subviews.firstIndex(of: bar)), metalIndex)
        }
        XCTAssertTrue(view.findNext("needle"))
        XCTAssertEqual(view.getSelection(), "needle")
        let hit = view.hitTest(view.convert(NSPoint(x: bar.bounds.midX, y: bar.bounds.midY), from: bar))
        XCTAssertTrue(hit === bar || hit?.isDescendant(of: bar) == true)
        action.tag = NSTextFinder.Action.hideFindInterface.rawValue
        view.performTextFinderAction(action)
        XCTAssertTrue(bar.isHidden)
        XCTAssertTrue(view.window?.firstResponder === view)
    }

    func testCursorResizeAndWindowTransfer() async throws {
        let view = host()
        view.feed(text: "before transfer\u{1B}[2;4H\u{1B}[?25l")
        try await settle()
        XCTAssertTrue(view.getTerminal().cursorHidden)
        XCTAssertTrue(view.caretView.isHidden)
        view.feed(text: "\u{1B}[?25h")
        try await settle()
        XCTAssertFalse(view.getTerminal().cursorHidden)
        XCTAssertEqual(view.caretView.isHidden, view.isUsingMetalRenderer)
        let oldMetal = view.subviews.first { $0 is MTKView }
        let buffer = view.getTerminal().getBufferAsData()
        view.removeFromSuperview()
        _ = host(view)
        try await settle()
        XCTAssertEqual(view.getTerminal().getBufferAsData(), buffer)
        if let oldMetal {
            XCTAssertFalse(view.subviews.contains { $0 === oldMetal })
            XCTAssertEqual(view.subviews.filter { $0 is MTKView }.count, 1)
        }
        let oldColumns = view.getTerminal().cols
        view.window?.setContentSize(NSSize(width: 640, height: 400))
        try await settle()
        XCTAssertLessThan(view.getTerminal().cols, oldColumns)
        view.feed(text: "\u{1B}[1;1Hafter transfer")
        try await settle()
        XCTAssertTrue(String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self).contains("after transfer"))
        view.isHidden = true
        view.isHidden = false
        configuration?.verify(view)
    }

    func testImagePasteAndKittyImageState() async throws {
        let view = host()
        let recorder = RendererPasteRecorder(frame: .zero)
        view.terminalDelegate = recorder
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("rai.renderer.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        XCTAssertTrue(pasteboard.writeObjects([image]))
        view.pasteboard = pasteboard
        view.feed(text: "\u{1B}[?2004h")
        view.paste(self)
        let sent = String(decoding: recorder.bytes, as: UTF8.self)
        XCTAssertTrue(sent.hasPrefix("\u{1B}[200~"))
        XCTAssertTrue(sent.hasSuffix(" \u{1B}[201~"))
        let path = String(sent.dropFirst(6).dropLast(7))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: URL(fileURLWithPath: path))))
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        view.feed(text: "\u{1B}_Ga=T,f=24,s=1,v=1,i=1,p=1,c=8,r=4,q=2;/wAA\u{1B}\\")
        try await settle()
        XCTAssertEqual(view.getTerminal().kittyGraphicsState.imagesById.count, 1)
        XCTAssertEqual(view.getTerminal().kittyGraphicsState.placementsByKey.count, 1)
        configuration?.verify(view)
    }

    func testInteractivePreview() async throws {
        guard let raw = ProcessInfo.processInfo.environment["RAI_RENDERER_PREVIEW_SECONDS"],
              let seconds = Int(raw), (1...600).contains(seconds) else {
            throw XCTSkip("Set RAI_RENDERER_PREVIEW_SECONDS=1...600 for a visible, isolated preview.")
        }
        // This test hosts only a terminal view and its own echo process.
        // It never starts Rai's app delegate or connects to a Herdr socket.
        let restorePasteboard = preserveFindPasteboard()
        NSPasteboard(name: .find).clearContents()
        let previousPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.regular)
        defer {
            restorePasteboard()
            NSApplication.shared.setActivationPolicy(previousPolicy)
        }
        let view = host()
        view.window?.makeKeyAndOrderFront(nil)
        view.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        view.clipboardWriter = { _ in true }
        view.feed(text: (0..<120).map { "history row \($0)\r\n" }.joined())
        view.feed(text: "\u{1B}[2J\u{1B}[HRai \(configuration?.name ?? "default") renderer preview\r\n")
        view.feed(text: "Select this text. Search for needle. Scroll to see history.\r\n")
        view.feed(text: "needle one     needle two\r\n")
        view.feed(text: "\u{1B}[31mRED \u{1B}[32mGREEN \u{1B}[34mBLUE\u{1B}[0m\r\n")
        view.feed(text: "Unicode: café  日本語  😀\r\n")
        view.feed(text: "Red image below:\r\n")
        view.feed(text: "\u{1B}_Ga=T,f=24,s=1,v=1,i=1,p=1,c=12,r=4,q=2;/wAA\u{1B}\\")
        view.feed(text: "\u{1B}[12;1HType here: \u{1B}[2 q")
        view.startProcess(executable: "/usr/bin/python3", args: ["-c", """
        import os, tty
        tty.setraw(0)
        while True:
            value = os.read(0, 1024)
            if not value: break
            os.write(1, value)
        """], rawInput: true)
        let previousMenu = NSApplication.shared.mainMenu
        let menu = NSMenu()
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Edit")
        let find = NSMenuItem(title: "Find", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        submenu.addItem(find)
        edit.submenu = submenu
        menu.addItem(edit)
        NSApplication.shared.mainMenu = menu
        defer { NSApplication.shared.mainMenu = previousMenu }
        // The caller can inspect this window through the normal UI tools.
        // The test imposes a bounded lifetime and always terminates its PTY.
        print("rai-renderer-preview renderer=\(configuration?.name ?? "default") pid=\(ProcessInfo.processInfo.processIdentifier)")
        for _ in 0..<seconds { try await Task.sleep(for: .seconds(1)) }
    }
}

@MainActor
private final class RendererPasteRecorder: TerminalProcessView {
    var bytes: [UInt8] = []
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        bytes.append(contentsOf: data)
    }
}
