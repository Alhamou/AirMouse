import Foundation
import Security

/// Local-only TLS certificates, stored in ~/Library/Application Support/AirMouse.
///
/// A private root CA is created once. Install and trust `rootCA.pem` on the iPhone a single time;
/// the server certificate it signs is re-issued automatically whenever the Mac's IP changes,
/// and the phone keeps trusting it.
struct CertificateManager {
    let directory: URL
    var rootCAURL: URL { directory.appendingPathComponent("rootCA.pem") }
    private var rootKeyURL: URL { directory.appendingPathComponent("rootCA-key.pem") }
    private var identityURL: URL { directory.appendingPathComponent("identity.p12") }
    private var ipURL: URL { directory.appendingPathComponent("ip.txt") }
    private static let p12Password = "airmouse"  // only protects the file in transit to SecPKCS12Import

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("AirMouse", isDirectory: true)
    }

    /// Server identity for `ip`, creating the root CA and/or server certificate when needed.
    func identity(ip: String, host: String) throws -> SecIdentity {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: rootCAURL.path) || !fm.fileExists(atPath: rootKeyURL.path) {
            try makeRootCA(host: host)
            try? fm.removeItem(at: identityURL)  // old server cert was signed by a different root
        }
        let certifiedIP = (try? String(contentsOf: ipURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if certifiedIP != ip || !fm.fileExists(atPath: identityURL.path) {
            try makeServerCertificate(ip: ip, host: host)
            try ip.write(to: ipURL, atomically: true, encoding: .utf8)
        }
        return try loadIdentity()
    }

    // MARK: Generation (openssl ships with macOS at /usr/bin/openssl)

    private func makeRootCA(host: String) throws {
        let config = """
        [req]
        distinguished_name = dn
        x509_extensions    = v3
        prompt             = no
        [dn]
        CN = AirMouse Local CA (\(host))
        O  = AirMouse
        [v3]
        basicConstraints     = critical, CA:TRUE
        keyUsage             = critical, keyCertSign, cRLSign
        subjectKeyIdentifier = hash
        """
        try withTempFile(config) { cnf in
            try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650",
                         "-keyout", rootKeyURL.path, "-out", rootCAURL.path, "-config", cnf])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rootKeyURL.path)
    }

    private func makeServerCertificate(ip: String, host: String) throws {
        // iOS requirements: RSA >= 2048, SHA-256, SAN, serverAuth EKU, validity <= 825 days.
        let ext = """
        [v3]
        basicConstraints       = critical, CA:FALSE
        keyUsage               = critical, digitalSignature, keyEncipherment
        extendedKeyUsage       = serverAuth
        subjectKeyIdentifier   = hash
        authorityKeyIdentifier = keyid
        subjectAltName         = IP:\(ip), IP:127.0.0.1, DNS:\(host).local, DNS:localhost
        """
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let key = tmp.appendingPathComponent("key.pem").path
        let csr = tmp.appendingPathComponent("server.csr").path
        let cert = tmp.appendingPathComponent("cert.pem").path

        try openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", csr,
                     "-subj", "/CN=AirMouse (\(host))/O=AirMouse"])
        try withTempFile(ext) { extFile in
            try openssl(["x509", "-req", "-in", csr, "-CA", rootCAURL.path, "-CAkey", rootKeyURL.path,
                         "-CAcreateserial", "-CAserial", tmp.appendingPathComponent("ca.srl").path,
                         "-out", cert, "-days", "825", "-sha256", "-extfile", extFile, "-extensions", "v3"])
        }
        try openssl(["pkcs12", "-export", "-inkey", key, "-in", cert, "-certfile", rootCAURL.path,
                     "-name", "AirMouse", "-out", identityURL.path, "-passout", "pass:\(Self.p12Password)"])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identityURL.path)
    }

    private func loadIdentity() throws -> SecIdentity {
        let data = try Data(contentsOf: identityURL)
        var options: [String: Any] = [kSecImportExportPassphrase as String: Self.p12Password]
        if #available(macOS 15.0, *) {
            options[kSecImportToMemoryOnly as String] = true  // don't add it to the login keychain
        }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else {
            throw CertificateError.importFailed(status)
        }
        return identity as! SecIdentity
    }

    // MARK: Helpers

    private func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw CertificateError.openssl(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func withTempFile(_ contents: String, _ body: (String) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cnf")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url.path)
    }
}

enum CertificateError: LocalizedError {
    case openssl(String)
    case importFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .openssl(let message): return "Certificate generation failed: \(message)"
        case .importFailed(let status): return "Could not load the TLS certificate (error \(status))."
        }
    }
}
