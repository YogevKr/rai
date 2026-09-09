import RaiCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum EndpointAppearance: String, CaseIterable {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct EndpointThemePalette {
    let colors: [String: EndpointThemeColor]
    let dark: Bool

    init(theme: String, dark: Bool) {
        colors = EndpointTheme.stored(theme).palette(dark: dark)
        self.dark = dark
    }

    func color(_ token: String, fallback: SwiftUI.Color) -> SwiftUI.Color {
        guard let value = colors[token]?.rgbValue(ansi: dark ? EndpointTerminalAppearance.darkColors : EndpointTerminalAppearance.lightColors) else {
            return fallback
        }
        return SwiftUI.Color(red: Double((value >> 16) & 255) / 255,
                             green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }

    /// Scope contrast to native bars drawn over an imported sidebar color.
    var sidebarColorScheme: ColorScheme? {
        let ansi = dark ? EndpointTerminalAppearance.darkColors : EndpointTerminalAppearance.lightColors
        guard let rgb = colors["sidebar_bg"]?.rgbValue(ansi: ansi) ?? colors["panel_bg"]?.rgbValue(ansi: ansi) else { return nil }
        let brightness = Double((rgb >> 16) & 255) * 0.2126 + Double((rgb >> 8) & 255) * 0.7152 + Double(rgb & 255) * 0.0722
        return brightness < 128 ? .dark : .light
    }

    var foreground: SwiftUI.Color { color("text", fallback: .primary) }
    var secondary: SwiftUI.Color { color("subtext0", fallback: .secondary) }
    var sidebar: SwiftUI.Color { color("sidebar_bg", fallback: color("panel_bg", fallback: .clear)) }
}

#if os(macOS)
struct EndpointMacAppearance: ViewModifier {
    let appearance: EndpointAppearance
    @State private var systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(appearance.colorScheme ?? (systemIsDark ? .dark : .light))
            .onReceive(NSApp.publisher(for: \.effectiveAppearance)) { value in
                systemIsDark = value.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            }
    }
}
#endif

struct EndpointAppearanceMenu: View {
    @Binding var appearance: EndpointAppearance
    @Binding var borders: EndpointBorderMode
    @Binding var theme: String
    var presentTheme: (() -> Void)? = nil
    @State private var showTheme = false

    var body: some View {
        Menu("Appearance") {
            Picker("Mode", selection: $appearance) {
                ForEach(EndpointAppearance.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Picker("Pane Borders", selection: $borders) {
                ForEach(EndpointBorderMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Button("Theme Colors…") {
                if let presentTheme { presentTheme() }
                else { showTheme = true }
            }
        }
        .sheet(isPresented: $showTheme) { EndpointThemeSheet(storedTheme: $theme, borders: $borders) }
    }
}

struct EndpointPaneBorders: View {
    let surface: HerdrEndpointSurface?
    let mode: EndpointBorderMode

    var body: some View {
        GeometryReader { geometry in
            if let surface, surface.popup == nil, surface.grid.width > 0, surface.grid.height > 0,
               mode.isVisible(paneCount: surface.panes.count) {
                ForEach(surface.panes, id: \.paneID) { pane in
                    let width = geometry.size.width / CGFloat(surface.grid.width)
                    let height = geometry.size.height / CGFloat(surface.grid.height)
                    Rectangle().strokeBorder(.primary.opacity(pane.focused ? 0.65 : 0.3), lineWidth: 1)
                        .frame(width: CGFloat(pane.rect.width) * width, height: CGFloat(pane.rect.height) * height)
                        .offset(x: CGFloat(pane.rect.x) * width, y: CGFloat(pane.rect.y) * height)
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Native defaults remain local. Reporting a host theme can change Herdr's shared foreground rendering.
@MainActor
enum EndpointTerminalAppearance {
    static func apply(_ view: TerminalView, dark: Bool, theme: EndpointTheme = EndpointTheme()) {
        let colors = theme.palette(dark: dark)
        let baseANSI = dark ? darkColors : lightColors
        let foreground = colors["text"]?.rgbValue(ansi: baseANSI) ?? (dark ? 0xf8f8f2 : 0x202124)
        let background = colors["panel_bg"]?.rgbValue(ansi: baseANSI) ?? (dark ? 0x212121 : 0xfafafc)
        view.nativeForegroundColor = color(foreground)
        view.nativeBackgroundColor = color(background)
        view.caretColor = color(foreground)
        view.caretTextColor = color(background)
        view.selectedTextBackgroundColor = color(colors["selection_bg"]?.rgbValue(ansi: baseANSI) ?? (dark ? 0x545454 : 0xd9d0ea))
        view.selectedTextForegroundColor = color(foreground)
        var ansi = baseANSI
        for (index, token) in [(1, "red"), (2, "green"), (3, "yellow"), (4, "blue"), (5, "mauve"), (6, "teal")] {
            if let value = colors[token]?.rgbValue(ansi: baseANSI) { ansi[index] = value; ansi[index + 8] = value }
        }
        view.installColors(ansi.map {
            SwiftTerm.Color(red: UInt16(($0 >> 16) & 255) * 257,
                            green: UInt16(($0 >> 8) & 255) * 257, blue: UInt16($0 & 255) * 257)
        })
    }

    static let darkColors: [UInt32] = [
        0x21222C, 0xFF5555, 0x50FA7B, 0xFFCB6B, 0x82AAFF, 0xC792EA, 0x8BE9FD, 0xF8F8F2,
        0x545454, 0xFF6E6E, 0x69FF94, 0xFFCB6B, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xF8F8F2,
    ]
    static let lightColors: [UInt32] = [
        0x30343B, 0xC9363E, 0x238636, 0x9A6700, 0x2563B9, 0x7651B2, 0x087F8C, 0xE8E8EC,
        0x687386, 0xE0525B, 0x2DA44E, 0xB58407, 0x3B7DDD, 0x9067C6, 0x1597A5, 0xFFFFFF,
    ]

    #if os(macOS)
    private static func color(_ value: UInt32) -> NSColor {
        RGBAColor.hex(value).nsColor
    }
    #else
    static func color(_ value: UInt32) -> UIColor {
        UIColor(red: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    #endif
}

struct EndpointThemeSheet: View {
    @Binding var storedTheme: String
    @Binding var borders: EndpointBorderMode
    @State private var importedBorders: EndpointBorderMode?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var draft = EndpointTheme()
    @State private var layer = "shared"
    @State private var importFile = false
    @State private var importText = ""
    @State private var errorMessage: String?
    @State private var importMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Theme") {
                    themePicker("Base Theme", selection: $draft.name)
                    Toggle("Use Separate Light and Dark Colors", isOn: $draft.autoSwitch)
                    if draft.autoSwitch {
                        themePicker("Light Theme", selection: $draft.lightName)
                        themePicker("Dark Theme", selection: $draft.darkName)
                    }
                    Text("Colors apply to this client. Herdr keeps explicit terminal colors.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Color Overrides") {
                    Picker("Edit Colors", selection: $layer) {
                        Text("Shared").tag("shared")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }.pickerStyle(.segmented)
                    if layer != "shared" && !draft.autoSwitch {
                        Text("Enable separate colors to use this layer.").foregroundStyle(.secondary)
                    }
                    ForEach(EndpointThemeCatalog.tokens, id: \.self) { token in
                        HStack {
                            Text(token.replacingOccurrences(of: "_", with: " ").capitalized)
                            Spacer()
                            TextField("Inherited", text: override(token))
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("theme-color-\(layer)-\(token)")
                                .frame(maxWidth: 175)
                        }
                    }
                    Text("Use #RGB, #RRGGBB, rgb(r,g,b), a named color, or reset. Clear a value to inherit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Preview") {
                    Text("Workspace · Agent · Terminal")
                        .foregroundStyle(previewColor("text", fallback: .primary))
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(previewColor("panel_bg", fallback: SwiftUI.Color.secondary.opacity(0.1)))
                    HStack {
                        ForEach(["accent", "red", "green", "yellow", "blue", "mauve", "teal"], id: \.self) { token in
                            Circle().fill(previewColor(token, fallback: .secondary))
                                .frame(width: 20, height: 20).accessibilityLabel(token)
                        }
                    }
                }
                Section("Import Herdr Theme") {
                    Button("Choose Theme File…") { importFile = true }
                    #if os(iOS)
                    EndpointThemeSourceEditor(text: $importText).frame(minHeight: 100)
                        .accessibilityLabel("Herdr theme TOML")
                    #else
                    TextEditor(text: $importText).font(.system(.body, design: .monospaced)).frame(minHeight: 100)
                        .accessibilityLabel("Herdr theme TOML")
                    #endif
                    Button("Import Pasted Theme") { importSource(importText) }.disabled(importText.isEmpty)
                    Text("Import [theme] and [theme.custom] tables. Review the colors, then select Save.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let importMessage { Text(importMessage).foregroundStyle(.secondary) }
                    if let importedBorders { Text("Imported pane borders: \(importedBorders.rawValue.capitalized)") }
                }
                Section { Button("Reset Theme") { draft = EndpointTheme(); importMessage = nil; importedBorders = nil } }
            }
            .formStyle(.grouped)
            .navigationTitle("Theme Colors")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
        #if os(macOS)
        .frame(width: 580, height: 700)
        #endif
        .onAppear { draft = EndpointTheme.stored(storedTheme) }
        .fileImporter(isPresented: $importFile, allowedContentTypes: [.plainText, .text, .data]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: EndpointThemeImport.maximumBytes + 1) ?? Data()
                guard let source = String(data: data, encoding: .utf8) else { throw EndpointThemeError("Theme file must use UTF-8 text.") }
                importSource(source)
            } catch { errorMessage = error.localizedDescription }
        }
        .alert("Theme Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func themePicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text(title == "Base Theme" ? "Rai Default" : "Automatic").tag("")
            ForEach(EndpointThemeCatalog.names, id: \.self) { Text($0).tag($0) }
        }
    }

    private func override(_ token: String) -> Binding<String> {
        Binding(get: {
            switch layer {
            case "light": return draft.light[token] ?? ""
            case "dark": return draft.dark[token] ?? ""
            default: return draft.shared[token] ?? ""
            }
        }, set: { value in
            let color: String? = value.isEmpty ? nil : value
            switch layer {
            case "light": draft.light[token] = color
            case "dark": draft.dark[token] = color
            default: draft.shared[token] = color
            }
        })
    }

    private func previewColor(_ token: String, fallback: SwiftUI.Color) -> SwiftUI.Color {
        let dark = layer == "dark" || (layer == "shared" && colorScheme == .dark)
        let ansi = dark ? EndpointTerminalAppearance.darkColors : EndpointTerminalAppearance.lightColors
        guard let value = draft.palette(dark: dark)[token]?.rgbValue(ansi: ansi) else { return fallback }
        return SwiftUI.Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255)
    }

    private func importSource(_ source: String) {
        do {
            let settings = try EndpointThemeImport.parseSettings(source)
            draft = settings.theme
            importedBorders = settings.borders
            importMessage = "Theme imported. Select Save to apply it."
        } catch { errorMessage = error.localizedDescription }
    }

    private func save() {
        do {
            try draft.validate()
            storedTheme = try draft.encoded()
            if let importedBorders { borders = importedBorders }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

#if os(iOS)
/// TOML must retain typed identifiers, quotes, and punctuation without keyboard substitutions.
struct EndpointThemeSourceEditor: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        view.adjustsFontForContentSizeCategory = true
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.delegate = context.coordinator
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        guard view.text != text else { return }
        let selection = view.selectedRange
        view.text = text
        let length = text.utf16.count
        let location = min(selection.location, length)
        view.selectedRange = NSRange(location: location, length: min(selection.length, length - location))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textViewDidChange(_ view: UITextView) { text.wrappedValue = view.text }
    }
}
#endif
