import Foundation

/// Runs a Cloudflare quick tunnel in front of the local server.
///
/// This is how the phone reaches the Mac from outside the house. cloudflared dials out to
/// Cloudflare and traffic comes back down that connection, so no port is opened on the router and
/// nothing is exposed on the local network either — the server can stay on loopback.
///
/// It is worth being clear about the cost. The hostname is public, so the approval gate at the Mac
/// is the thing standing between a stranger who guesses the link and the desktop. Cloudflare also
/// terminates TLS at their edge, which means the screen and the keystrokes are visible to them in a
/// way they are not on the local network.
final class TunnelController {
    enum State {
        case off
        case starting
        case running(String)
        case failed(String)
    }

    /// Searched by hand because the app is started by launchd, which does not carry a login shell's
    /// PATH, so a bare `cloudflared` would not be found.
    private static let searchPaths = [
        "/opt/homebrew/bin/cloudflared",
        "/usr/local/bin/cloudflared",
        "/usr/bin/cloudflared",
    ]

    static var executable: String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool { executable != nil }

    private let lock = NSLock()
    private var process: Process?
    private var _state: State = .off

    var onStateChange: ((State) -> Void)?

    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    var isActive: Bool {
        switch state {
        case .off, .failed: return false
        case .starting, .running: return true
        }
    }

    func start(localPort: UInt16) {
        guard let executable = Self.executable else {
            return transition(.failed("cloudflared is not installed"))
        }
        stop()
        transition(.starting)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // A quick tunnel needs no account and no domain: Cloudflare allocates a hostname and a
        // certificate for the life of the process. The address changes every time it starts, which
        // is a limitation worth knowing but also means a stale link stops working on its own.
        process.arguments = ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:\(localPort)"]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            self?.absorb(text)
        }

        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            // A clean stop has already moved to .off, so only report an unexpected exit.
            if case .off = state { return }
            transition(.failed("cloudflared exited with status \(finished.terminationStatus)"))
        }

        do {
            try process.run()
            lock.lock()
            self.process = process
            lock.unlock()
        } catch {
            transition(.failed("could not start cloudflared: \(error.localizedDescription)"))
        }
    }

    func stop() {
        lock.lock()
        let running = process
        process = nil
        _state = .off
        lock.unlock()
        running?.terminationHandler = nil
        running?.terminate()
        onStateChange?(.off)
    }

    /// Picks the assigned hostname out of cloudflared's banner.
    private func absorb(_ text: String) {
        Log.info("cloudflared: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        guard case .starting = state else { return }
        guard let range = text.range(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#,
                                     options: .regularExpression) else { return }
        transition(.running(String(text[range])))
    }

    private func transition(_ next: State) {
        lock.lock()
        _state = next
        lock.unlock()
        onStateChange?(next)
    }
}
