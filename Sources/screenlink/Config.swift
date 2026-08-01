import Foundation
import Security

struct Config {
    /// HTTP and WebSocket share one port, so there is a single origin to secure and to hand out.
    var port: UInt16 = 8766
    /// Loopback unless explicitly widened. Reaching the network is opt-in because this process can
    /// see and drive the entire machine.
    var bindHost: String = "127.0.0.1"
    var useTLS: Bool = false
    var fps: Int = 60
    var maxWidth: Int = 1920
    var bitrate: Int = 12_000_000
    var allowInput: Bool = true
    var token: String = Config.randomToken()
    var clientPath: String?
    var logPath: String?
    /// CGDirectDisplayID to capture at startup; nil selects the main display.
    var displayID: UInt32?

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func fromCommandLine() -> Config {
        var c = Config()
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--port", "--http-port": if let v = it.next(), let n = UInt16(v) { c.port = n }
            case "--fps": if let v = it.next(), let n = Int(v) { c.fps = max(1, min(120, n)) }
            case "--max-width": if let v = it.next(), let n = Int(v) { c.maxWidth = max(320, n) }
            case "--bitrate": if let v = it.next(), let n = Int(v) { c.bitrate = n }
            case "--token": if let v = it.next() { c.token = v }
            case "--display": if let v = it.next(), let n = UInt32(v) { c.displayID = n }
            case "--client": if let v = it.next() { c.clientPath = v }
            case "--log": if let v = it.next() { c.logPath = v }
            case "--no-input": c.allowInput = false
            case "--host": if let v = it.next() { c.bindHost = v }
            case "--tls": c.useTLS = true
            case "--lan":
                // TLS comes along automatically: off the loopback interface the token and the
                // screen contents would otherwise cross the network in the clear.
                if let address = NetworkInterfaces.primaryIPv4() {
                    c.bindHost = address
                    c.useTLS = true
                } else {
                    Log.warn("--lan requested but no local network address was found; staying on loopback")
                }
            default: Log.warn("ignoring unknown argument: \(arg)")
            }
        }
        return c
    }
}
