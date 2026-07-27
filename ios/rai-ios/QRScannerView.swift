import AVFoundation
import SwiftUI

struct QRScannerView: UIViewControllerRepresentable {
    let completion: (Result<String, Error>) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.completion = completion
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var completion: ((Result<String, Error>) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var completed = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        Task { await configureForCameraPermission() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }

    private func configureForCameraPermission() async {
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = await AVCaptureDevice.requestAccess(for: .video)
        default:
            authorized = false
        }
        guard authorized else {
            finish(.failure(ScannerError.cameraPermission))
            return
        }
        configureSession()
    }

    private func configureSession() {
        do {
            guard let camera = AVCaptureDevice.default(for: .video) else {
                throw ScannerError.cameraUnavailable
            }
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else { throw ScannerError.cameraUnavailable }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { throw ScannerError.cameraUnavailable }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.insertSublayer(layer, at: 0)
            previewLayer = layer
            layer.frame = view.bounds
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
            }
        } catch {
            finish(.failure(error))
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        finish(.success(value))
    }

    private func finish(_ result: Result<String, Error>) {
        guard !completed else { return }
        completed = true
        session.stopRunning()
        completion?(result)
    }
}
enum ScannerError: LocalizedError {
    case cameraPermission
    case cameraUnavailable

    var errorDescription: String? {
        switch self {
        case .cameraPermission: "Camera access is required to scan a pairing code. You can pair manually instead."
        case .cameraUnavailable: "The camera is unavailable. You can pair manually instead."
        }
    }
}
