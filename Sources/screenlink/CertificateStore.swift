import Foundation
import Security

/// Where the server's TLS identity comes from.
///
/// Self-signed works with no infrastructure but costs the user a browser warning per device. A
/// service-issued certificate for a domain you control is warning-free, which is the only way to
/// make this genuinely consumer-ready. Both produce a `SecIdentity`, so the server never has to
/// know which one it got.
protocol CertificateSource {
    /// - Parameter names: hostnames and IP addresses the certificate must be valid for.
    func identity(covering names: [String]) throws -> SecIdentity
}

enum CertificateError: Error, CustomStringConvertible {
    case generationFailed(String)
    case importFailed(OSStatus)
    case noIdentity

    var description: String {
        switch self {
        case .generationFailed(let detail): return "certificate generation failed: \(detail)"
        case .importFailed(let status): return "certificate import failed (OSStatus \(status))"
        case .noIdentity: return "PKCS#12 archive contained no identity"
        }
    }
}

/// Generates and caches a self-signed certificate under Application Support.
///
/// Certificate creation shells out to the system LibreSSL. The Security framework can generate keys
/// but exposes no public API for building an X.509 certificate, and /usr/bin/openssl ships with
/// macOS, so this avoids both a dependency and a hand-rolled DER encoder.
final class SelfSignedCertificateSource: CertificateSource {
    private static let openssl = "/usr/bin/openssl"
    /// Guards only the on-disk archive; the private key never leaves this directory.
    private let passphrase = "screenlink"
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("screenlink/tls", isDirectory: true)
    }

    func identity(covering names: [String]) throws -> SecIdentity {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        let archive = directory.appendingPathComponent("identity.p12")
        let manifest = directory.appendingPathComponent("names.txt")
        let wanted = names.sorted().joined(separator: "\n")

        // Regenerate when the address set changes, otherwise the certificate would not cover the
        // address the phone actually connects to.
        let cached = try? String(contentsOf: manifest, encoding: .utf8)
        if cached != wanted || !FileManager.default.fileExists(atPath: archive.path) {
            try generate(names: names, into: archive)
            try wanted.write(to: manifest, atomically: true, encoding: .utf8)
            Log.info("generated TLS certificate for \(names.joined(separator: ", "))")
        }

        return try Self.loadIdentity(from: archive, passphrase: passphrase)
    }

    /// SHA-256 fingerprint of the leaf certificate, for out-of-band verification during pairing.
    func fingerprint() -> String? {
        let cert = directory.appendingPathComponent("cert.pem")
        guard let output = try? Self.run(Self.openssl,
                                         ["x509", "-in", cert.path, "-noout", "-fingerprint", "-sha256"]),
              let value = output.split(separator: "=").last else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func generate(names: [String], into archive: URL) throws {
        let key = directory.appendingPathComponent("key.pem")
        let cert = directory.appendingPathComponent("cert.pem")
        let config = directory.appendingPathComponent("openssl.cnf")

        // IP addresses have to be declared as IP SANs, not DNS ones, or no browser will match them.
        let subjectAltNames = names.map { name in
            name.range(of: "^[0-9.]+$", options: .regularExpression) != nil ? "IP:\(name)" : "DNS:\(name)"
        }.joined(separator: ", ")

        let contents = """
        [req]
        distinguished_name = dn
        x509_extensions = ext
        prompt = no
        [dn]
        CN = screenlink
        [ext]
        basicConstraints = critical,CA:false
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = critical,serverAuth
        subjectAltName = \(subjectAltNames)
        """
        try contents.write(to: config, atomically: true, encoding: .utf8)

        // Apple platforms reject server certificates with lifetimes over 825 days outright, so a
        // longer-lived certificate would fail before the user ever sees a warning to click through.
        _ = try Self.run(Self.openssl, [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "398",
            "-keyout", key.path, "-out", cert.path, "-config", config.path,
        ])
        _ = try Self.run(Self.openssl, [
            "pkcs12", "-export", "-out", archive.path,
            "-inkey", key.path, "-in", cert.path,
            "-passout", "pass:\(passphrase)", "-name", "screenlink",
        ])

        for file in [key, archive] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    private static func loadIdentity(from archive: URL, passphrase: String) throws -> SecIdentity {
        let data = try Data(contentsOf: archive)
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData,
                                     [kSecImportExportPassphrase as String: passphrase] as CFDictionary,
                                     &items)
        guard status == errSecSuccess else { throw CertificateError.importFailed(status) }
        guard let entries = items as? [[String: Any]],
              let identity = entries.first?[kSecImportItemIdentity as String] else {
            throw CertificateError.noIdentity
        }
        return identity as! SecIdentity
    }

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CertificateError.generationFailed(String(decoding: stderr, as: UTF8.self))
        }
        return String(decoding: stdout, as: UTF8.self)
    }
}
