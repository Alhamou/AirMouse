import AppKit

/// The menu bar icon and its menu.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private unowned let app: AppDelegate

    init(app: AppDelegate) {
        self.app = app
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refresh()
    }

    /// Update the icon: filled while an iPhone is connected, dimmed on error.
    func refresh() {
        let symbol = app.clients > 0 ? "rectangle.and.hand.point.up.left.fill" : "rectangle.and.hand.point.up.left"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AirMouse")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.appearsDisabled = app.errorMessage != nil
        item.button?.toolTip = app.clients > 0 ? "AirMouse — iPhone connected" : "AirMouse"
    }

    // Rebuilt every time it opens, so it always shows the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status: String
        if let error = app.errorMessage {
            status = "⚠︎ \(error)"
        } else if app.clients > 0 {
            status = app.clients == 1 ? "iPhone connected" : "\(app.clients) devices connected"
        } else {
            status = "Waiting for iPhone — \(app.ip)"
        }
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "").isEnabled = false

        if !Accessibility.isTrusted {
            menu.addItem(ActionItem("⚠︎ Allow Accessibility Access…") { Accessibility.openSettings() })
        }
        menu.addItem(.separator())

        menu.addItem(ActionItem("Show QR Code…", key: "q") { [unowned self] in app.showQRCode() })
        menu.addItem(ActionItem("Copy Link") { [unowned self] in app.copyLink() })
        menu.addItem(.separator())

        menu.addItem(ActionItem("Send Root Certificate via AirDrop…") { [unowned self] in app.shareRootCertificate() })
        menu.addItem(ActionItem("Show Root Certificate in Finder") { [unowned self] in app.revealRootCertificate() })
        menu.addItem(.separator())

        let login = ActionItem("Start at Login") { LoginItem.set(!LoginItem.isEnabled) }
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(ActionItem("Reset Access Link") { [unowned self] in app.resetLink() })
        if app.errorMessage != nil {
            menu.addItem(ActionItem("Restart Server") { [unowned self] in app.restartServer() })
        }
        menu.addItem(.separator())

        menu.addItem(ActionItem("Quit AirMouse") { NSApp.terminate(nil) })
    }
}

/// NSMenuItem that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
