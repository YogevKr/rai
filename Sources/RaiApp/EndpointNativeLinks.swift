import RaiCore
import SwiftUI

@MainActor
final class EndpointNativeLinks: ObservableObject {
    @Published var error: String?
    @Published private(set) var popupLink: EndpointPopupLinkInvocation?
    private var pending: EndpointPluginRequest?

    @discardableResult
    func activate(url: String, column: Int, row: Int, surface: HerdrEndpointSurface,
                  submit: (EndpointPluginRequest) -> Bool) -> Bool {
        guard pending == nil, popupLink == nil else { return true }
        if surface.popup != nil {
            popupLink = EndpointPopupLinkInvocation.capture(in: surface, column: column, row: row, expectedURL: url)
            error = popupLink == nil ? "The link changed. Try again." : nil
            return true
        }
        guard let link = EndpointPluginLinkInvocation.capture(in: surface, column: column, row: row, expectedURL: url), link.url == url else {
            error = "The link changed. Try again."
            return true
        }
        let request = EndpointPluginRequest(bootID: surface.bootID, operation: .activateLink(link))
        if submit(request) { pending = request }
        else { error = "The workspace cannot open this link now. Try again after it connects." }
        return true
    }

    func receive(_ result: EndpointPluginResult?, surface: HerdrEndpointSurface?) -> URL? {
        guard let result, let pending, result.requestID == pending.id else { return nil }
        self.pending = nil
        if let failure = result.error { error = failure; return nil }
        guard let value = result.value?.objectValue else { error = "The host returned no link result."; return nil }
        if value["handled"] == .bool(true) { return nil }
        guard value["handled"] == .bool(false), case .activateLink(let link) = pending.operation,
              let surface, (try? link.validate(in: surface)) != nil,
              value["url"]?.stringValue == link.url else {
            error = "The link changed. Try again."
            return nil
        }
        guard let url = URL(string: link.url), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { error = "No plugin can open this link."; return nil }
        return url
    }

    func receivePopup(in surface: HerdrEndpointSurface?) -> URL? {
        guard let popupLink else { return nil }
        self.popupLink = nil
        guard let surface, (try? popupLink.validate(in: surface)) != nil else {
            error = "The link changed. Try again."
            return nil
        }
        guard let url = URL(string: popupLink.url), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            error = "Popup links support HTTP and HTTPS. Herdr cannot route popup links to plugins."
            return nil
        }
        return url
    }

    func browserFinished(accepted: Bool) {
        if !accepted { error = "The browser could not open this link." }
    }

    func reset() { pending = nil; popupLink = nil; error = nil }
}

struct EndpointLinkPresentation: ViewModifier {
    @ObservedObject var links: EndpointNativeLinks
    let result: EndpointPluginResult?
    let surface: HerdrEndpointSurface?
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .onChange(of: result?.requestID) { _, _ in
                if let url = links.receive(result, surface: surface) { openURL(url, completion: links.browserFinished) }
            }
            .onChange(of: links.popupLink?.id) { _, _ in
                if let url = links.receivePopup(in: surface) { openURL(url, completion: links.browserFinished) }
            }
            .onChange(of: surface?.bootID) { _, _ in links.reset() }
            .alert("Open Link", isPresented: Binding(get: { links.error != nil }, set: { if !$0 { links.error = nil } })) {
                Button("OK") { links.error = nil }
            } message: { Text(links.error ?? "") }
    }
}
