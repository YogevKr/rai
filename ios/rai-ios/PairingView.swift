import SwiftUI

struct PairingView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var host = ""
    @State private var port = ""
    @State private var token = ""
    @State private var showingScanner = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showingScanner = true
                    } label: {
                        Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                } footer: {
                    Text("On your Mac, open rai's companion pairing code.")
                }

                Section("Enter manually") {
                    TextField("Mac host or IP", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    SecureField("Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Pair and Connect", action: pairManually)
                        .disabled(host.isEmpty || port.isEmpty || token.isEmpty)
                }
            }
            .navigationTitle("Pair with rai")
            .sheet(isPresented: $showingScanner) {
                NavigationStack {
                    QRScannerView { result in
                        showingScanner = false
                        handleScan(result)
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Scan Code")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingScanner = false }
                        }
                    }
                }
            }
            .alert("Couldn’t Pair", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func pairManually() {
        guard let portNumber = Int(port) else {
            errorMessage = PairingError.invalidPort.localizedDescription
            return
        }
        do {
            try appModel.pair(Pairing(host: host, port: portNumber, token: token))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleScan(_ result: Result<String, Error>) {
        do {
            let code = try result.get()
            try appModel.pair(Pairing(urlString: code))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
