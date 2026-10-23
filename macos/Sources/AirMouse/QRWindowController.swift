import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Small window with the QR code to open the trackpad page on the iPhone.
final class QRWindowController {
    private let model = QRModel()
    private let window: NSWindow

    init(app: AppDelegate) {
        let view = QRView(model: model,
                          copy: { [unowned app] in app.copyLink() },
                          airDrop: { [unowned app] in app.shareRootCertificate() })
        window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "AirMouse"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
    }

    func update(url: String) {
        model.url = url
        model.image = Self.qrImage(for: url)
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func qrImage(for text: String) -> NSImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else {
            return NSImage()
        }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

final class QRModel: ObservableObject {
    @Published var url = ""
    @Published var image = NSImage()
}

private struct QRView: View {
    @ObservedObject var model: QRModel
    let copy: () -> Void
    let airDrop: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Scan with your iPhone camera").font(.headline)
            Image(nsImage: model.image)
                .interpolation(.none)
                .resizable()
                .frame(width: 240, height: 240)
                .padding(12)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(model.url)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
            Text("The iPhone must be on the same Wi-Fi. First time? Send the root certificate to the iPhone and trust it (see README).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Send Root Certificate…", action: airDrop)
                Button("Copy Link", action: copy).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
