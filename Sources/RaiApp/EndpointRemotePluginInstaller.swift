import Foundation
import RaiCore

/// The same foreground SSH process prints the review and receives its explicit answer.
@MainActor
final class EndpointRemotePluginInstaller {
    private enum Phase { case preparing, awaiting(UUID), executing, finished }
    private var phase = Phase.preparing
    private var process: MachineSetupProcess?
    private var output = ""
    private var request: EndpointPluginRequest
    private let isCurrent: () -> Bool
    private let deliver: (EndpointPluginResult) -> Void

    init(request: EndpointPluginRequest, isCurrent: @escaping () -> Bool,
         deliver: @escaping (EndpointPluginResult) -> Void) {
        self.request = request; self.isCurrent = isCurrent; self.deliver = deliver
    }

    func start(binary: String = "/usr/bin/ssh", arguments: [String]) throws {
        guard isCurrent() else { throw HerdrEndpointError.staleIdentity }
        if case .uninstall = request.operation { phase = .executing }
        let process = MachineSetupProcess(update: { [weak self] output, prompt in
            self?.receive(output, prompt: prompt)
        }, finish: { [weak self] status in self?.finish(status) })
        self.process = process
        try process.start(binary: binary, arguments: arguments)
    }

    func answer(_ request: EndpointPluginRequest, previewID: UUID, approve: Bool) throws {
        if !approve, case .preparing = phase, previewID == self.request.id {
            self.request = request
            cancel()
            deliver(.init(requestID: request.id, value: .object(["output": .string("Remote plugin review cancelled.")])))
            return
        }
        guard isCurrent(), request.bootID == self.request.bootID,
              case .awaiting(let current) = phase, current == previewID, let process else {
            throw HerdrEndpointError.staleIdentity
        }
        self.request = request
        phase = .executing
        do { try process.answer(promptID: previewID, approve: approve) }
        catch { fail(error.localizedDescription); throw error }
    }

    func cancel() {
        phase = .finished
        process?.cancel()
        process = nil
    }

    private func receive(_ text: String, prompt: UUID?) {
        output = text
        guard isCurrent() else { fail("The selected machine changed. The plugin command stopped."); return }
        if process?.outputTruncated == true {
            switch phase {
            case .preparing, .awaiting:
                fail("The plugin preview exceeded 64 KiB. Installation stopped because the complete review is unavailable.")
                return
            case .executing: output = "Earlier command output was omitted.\n" + text
            case .finished: break
            }
        }
        guard let prompt else { return }
        switch phase {
        case .preparing:
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("Install this plugin? [y/N]") else {
                fail("The remote command requested an unexpected approval. Installation stopped.")
                return
            }
            phase = .awaiting(prompt)
            deliver(.init(requestID: request.id, value: .object([
                "preview_id": .string(prompt.uuidString), "can_confirm": .bool(true), "output": .string(text),
            ])))
        case .executing: fail("The plugin requested more interactive input. The command stopped.")
        case .awaiting, .finished: break
        }
    }

    private func finish(_ status: Int32) {
        if case .finished = phase { return }
        phase = .finished
        process = nil
        guard isCurrent() else { deliver(.init(requestID: request.id, error: "The selected machine changed.")); return }
        if status == 0 {
            deliver(.init(requestID: request.id, value: .object(["output": .string(output.isEmpty ? "The remote plugin command finished." : output)])))
        } else {
            deliver(.init(requestID: request.id, error: "Remote plugin command exited with status \(status).\n\(output)"))
        }
    }

    private func fail(_ message: String) {
        if case .finished = phase { return }
        phase = .finished
        process?.cancel(); process = nil
        deliver(.init(requestID: request.id, error: message))
    }
}
