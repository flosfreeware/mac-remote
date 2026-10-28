import AVFoundation
import SwiftUI

struct QRCodeScanner: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let found: (String) -> Void
    func makeCoordinator() -> Coordinator {
        Coordinator { value in
            found(value)
            dismiss()
        }
    }
    func makeUIViewController(context: Context) -> ScannerController { let c = ScannerController(); c.delegate = context.coordinator; return c }
    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let found: (String) -> Void
        private var delivered = false
        init(found: @escaping (String) -> Void) { self.found = found }
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !delivered, let value = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            delivered = true
            // Metadata delivery is currently on main, but preserve that contract
            // if the capture queue changes in the future.
            DispatchQueue.main.async { self.found(value) }
        }
    }
}

final class ScannerController: UIViewController {
    weak var delegate: AVCaptureMetadataOutputObjectsDelegate?
    private let session = AVCaptureSession()
    override func viewDidLoad() { super.viewDidLoad(); guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }; session.addInput(input); let output = AVCaptureMetadataOutput(); guard session.canAddOutput(output) else { return }; session.addOutput(output); output.setMetadataObjectsDelegate(delegate, queue: .main); output.metadataObjectTypes = [.qr]; let preview = AVCaptureVideoPreviewLayer(session: session); preview.frame = view.bounds; preview.videoGravity = .resizeAspectFill; view.layer.addSublayer(preview); DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() } }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); session.stopRunning() }
}
