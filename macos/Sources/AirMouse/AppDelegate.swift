import AppKit
import Network

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let input = InputController()
    private let certificates = CertificateManager()
    private var server: Server!
    private var statusBar: StatusBarController!
    private var qrWindow: QRWindowController?
    private let pathMonitor = NWPathMonitor()

    private(set) var ip = "127.0.0.1"
    private(set) var clients = 0
    private(set) var errorMessage: String?

    var url: String { "https://\(ip):\(Preferences.port)/?t=\(Preferences.token)" }
    var rootCAURL: URL { certificates.rootCAURL }

    func applicationDidFinishLaunching(_ notification: Notification) {
        server = Server(port: Preferences.port, token: Preferences.token, input: input,
                        pageURL: Self.pageURL, rootCAURL: certificates.rootCAURL)
        server.onClientsChanged = { [weak self] count in
            self?.clients = count
            self?.statusBar.refresh()
        }
        server.onError = { [weak self] message in
            self?.errorMessage = message
            self?.statusBar.refresh()
        }
        statusBar = StatusBarController(app: self)
        startServer()

        if !Accessibility.isTrusted { Accessibility.prompt() }
        if Preferences.isFirstLaunch() {
            LoginItem.set(true)  // start at login by default; toggle in the menu
            showQRCode()
        }

        // Wi-Fi changes can give the Mac a new IP: re-issue the certificate and restart.
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.networkChanged() }
        }
        pathMonitor.start(queue: .main)
    }

    private func startServer() {
        ip = LocalNetwork.ipv4Address() ?? "127.0.0.1"
        do {
            let identity = try certificates.identity(ip: ip, host: LocalNetwork.hostName)
            try server.start(identity: identity)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        statusBar.refresh()
        qrWindow?.update(url: url)
    }

    private func networkChanged() {
        guard let newIP = LocalNetwork.ipv4Address(), newIP != ip else { return }
        server.stop()
        startServer()
    }

    // MARK: Menu actions

    func showQRCode() {
        if qrWindow == nil { qrWindow = QRWindowController(app: self) }
        qrWindow?.update(url: url)
        qrWindow?.show()
    }

    func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    func resetLink() {
        server.setToken(Preferences.resetToken())
        qrWindow?.update(url: url)
        showQRCode()
    }

    func shareRootCertificate() {
        guard let airDrop = NSSharingService(named: .sendViaAirDrop) else { return revealRootCertificate() }
        airDrop.perform(withItems: [certificates.rootCAURL])
    }

    func revealRootCertificate() {
        NSWorkspace.shared.activateFileViewerSelecting([certificates.rootCAURL])
    }

    func restartServer() {
        server.stop()
        startServer()
    }

    /// The trackpad page: bundled in the .app, or ../static/index.html when run with `swift run`.
    private static var pageURL: URL {
        if let bundled = Bundle.main.url(forResource: "index", withExtension: "html") { return bundled }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("static/index.html")
    }
}
