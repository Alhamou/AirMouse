import AppKit
import ApplicationServices
import ServiceManagement
import SystemConfiguration

/// Persistent preferences (UserDefaults).
enum Preferences {
    private static let defaults = UserDefaults.standard

    static let port: UInt16 = 8443

    /// Random access token in the URL, so other devices on the network can't control the Mac.
    static var token: String {
        if let token = defaults.string(forKey: "token"), !token.isEmpty { return token }
        return resetToken()
    }

    @discardableResult
    static func resetToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        defaults.set(token, forKey: "token")
        return token
    }

    /// LG webOS TV that the phone's TV tab controls.
    static var tvHost: String {
        get { defaults.string(forKey: "tvHost") ?? "192.168.1.51" }
        set { defaults.set(newValue, forKey: "tvHost") }
    }

    /// Key the TV issues when AirMouse is accepted, so it doesn't ask again. One per TV address.
    static func tvClientKey(host: String) -> String? { defaults.string(forKey: "tvClientKey." + host) }
    static func setTVClientKey(_ key: String?, host: String) { defaults.set(key, forKey: "tvClientKey." + host) }

    /// The TV's hardware address, learned while it's on, to wake it from standby.
    static func tvMAC(host: String) -> String? { defaults.string(forKey: "tvMAC." + host) }
    static func setTVMAC(_ mac: String, host: String) { defaults.set(mac, forKey: "tvMAC." + host) }

    /// True only the very first time the app runs.
    static func isFirstLaunch() -> Bool {
        guard !defaults.bool(forKey: "launchedBefore") else { return false }
        defaults.set(true, forKey: "launchedBefore")
        return true
    }
}

enum LocalNetwork {
    /// The Mac's LAN IPv4 address. Prefers en0/en1 (Ethernet / Wi-Fi) over VPN or bridge interfaces.
    static func ipv4Address() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        var byInterface: [String: String] = [:]
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ifa.pointee.ifa_flags)
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !ip.hasPrefix("169.254.") else { continue }  // link-local: no DHCP
            byInterface[String(cString: ifa.pointee.ifa_name)] = ip
        }
        for name in ["en0", "en1", "en2", "en3"] { if let ip = byInterface[name] { return ip } }
        return byInterface.first { $0.key.hasPrefix("en") }?.value
    }

    /// Bonjour name, e.g. "Mac-mini" (reachable as Mac-mini.local).
    static var hostName: String {
        (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? "Mac"
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("AirMouse: login item change failed: \(error.localizedDescription)")
        }
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds AirMouse to the Accessibility list.
    static func prompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
