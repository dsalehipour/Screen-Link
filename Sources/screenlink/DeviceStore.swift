import CryptoKit
import Foundation

/// A device that has been approved at the Mac and may open sessions until it is revoked.
struct PairedDevice: Codable {
    let id: String
    var name: String
    /// SHA-256 of the credential, hex. The credential itself is shown to the device once and never
    /// written down, so a copy of this file is not enough to open a session.
    let secretHash: String
    let pairedAt: Date
    var lastSeenAt: Date
}

/// A device asking to be approved. Short-lived and never persisted.
struct PairingRequest {
    let id: String
    /// Displayed on the Mac and on the device asking. The person approving compares the two, which
    /// is what stops a second party who holds the link from being waved through by mistake.
    let code: String
    let name: String
    let address: String
    let createdAt: Date
}

/// Approved devices and the requests waiting on a decision.
///
/// This exists because holding the link is not meant to be enough. Anyone who obtains the token —
/// by looking at the QR code, or by impersonating this Mac to the phone with a certificate issued
/// behind our back — still cannot open a session without someone approving it here. Access therefore
/// rests on something an attacker away from this machine cannot reach.
final class DeviceStore {
    static let requestLifetime: TimeInterval = 120

    private let lock = NSLock()
    private let fileURL: URL
    private var devices: [PairedDevice] = []
    private var pending: [String: PairingRequest] = [:]

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("devices.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        load()
    }

    // MARK: - Approved devices

    var approved: [PairedDevice] {
        lock.lock()
        defer { lock.unlock() }
        return devices.sorted { $0.pairedAt < $1.pairedAt }
    }

    /// Confirms a credential and records the sighting. Constant-time so a caller cannot search for a
    /// valid secret by measuring how long the comparison takes.
    func verify(deviceId: String, secret: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let index = devices.firstIndex(where: { $0.id == deviceId }) else { return false }
        guard Self.constantTimeEquals(Self.hash(secret), devices[index].secretHash) else { return false }
        devices[index].lastSeenAt = Date()
        save()
        return true
    }

    func revoke(deviceId: String) {
        lock.lock()
        devices.removeAll { $0.id == deviceId }
        save()
        lock.unlock()
    }

    func revokeAll() {
        lock.lock()
        devices.removeAll()
        save()
        lock.unlock()
    }

    // MARK: - Pairing

    /// Opens a request for approval. The caller has already proved it holds the link token; that
    /// only buys the right to ask.
    func beginPairing(name: String, address: String) -> PairingRequest {
        let request = PairingRequest(id: Self.randomHex(8),
                                     code: Self.randomCode(),
                                     name: Self.sanitize(name),
                                     address: address,
                                     createdAt: Date())
        lock.lock()
        pending = pending.filter { Date().timeIntervalSince($0.value.createdAt) < Self.requestLifetime }
        pending[request.id] = request
        lock.unlock()
        return request
    }

    func request(id: String) -> PairingRequest? {
        lock.lock()
        defer { lock.unlock() }
        guard let request = pending[id],
              Date().timeIntervalSince(request.createdAt) < Self.requestLifetime else { return nil }
        return request
    }

    /// Approves a pending request and returns the credential to hand back, once.
    func approve(requestId: String) -> (deviceId: String, secret: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let request = pending.removeValue(forKey: requestId),
              Date().timeIntervalSince(request.createdAt) < Self.requestLifetime else { return nil }

        let deviceId = Self.randomHex(8)
        let secret = Self.randomHex(32)
        devices.append(PairedDevice(id: deviceId,
                                    name: request.name,
                                    secretHash: Self.hash(secret),
                                    pairedAt: Date(),
                                    lastSeenAt: Date()))
        save()
        return (deviceId, secret)
    }

    func deny(requestId: String) {
        lock.lock()
        pending.removeValue(forKey: requestId)
        lock.unlock()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([PairedDevice].self, from: data) else { return }
        devices = stored
    }

    /// Callers already hold the lock.
    private func save() {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    // MARK: - Helpers

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomHex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Six digits: long enough that guessing it inside the request lifetime is hopeless, short
    /// enough to compare between two screens at a glance.
    private static func randomCode() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }

    /// The name is chosen by whoever is connecting and ends up in a menu on this Mac, so it is
    /// stripped of anything that could disguise what is really on the list.
    private static func sanitize(_ name: String) -> String {
        let cleaned = name.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .prefix(40)
        let trimmed = String(String.UnicodeScalarView(cleaned))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unnamed device" : trimmed
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.count { diff |= lhs[i] ^ rhs[i] }
        return diff == 0
    }
}
