import CoreGraphics
import Foundation

/// Commands arrive as JSON over the WebSocket (human path) or POST /command (agent path).
/// Pointer coordinates are normalized to [0,1] over the captured display; the server converts
/// them to global points. Sending pixels instead would break across Retina scaling and multi-display.
struct InputCommand: Decodable {
    enum Kind: String, Decodable {
        case auth
        case mouse
        case scroll
        case key
        case text
        case keyframe
        case display
    }

    let type: Kind
    var action: String?
    var x: Double?
    var y: Double?
    var dx: Double?
    var dy: Double?
    var button: String?
    var code: String?
    var text: String?
    var token: String?
    /// Credential from a previous approval. Presented on its own it is enough to open a session;
    /// without it the token only buys the right to ask for approval at the Mac.
    var deviceId: String?
    var deviceSecret: String?
    var deviceName: String?
    var meta: Bool?
    var shift: Bool?
    var alt: Bool?
    var ctrl: Bool?
    /// CGDirectDisplayID for `.display`; clients read the valid set from StreamInfo.
    var display: UInt32?

    var modifiers: CGEventFlags {
        var flags: CGEventFlags = []
        if meta == true { flags.insert(.maskCommand) }
        if shift == true { flags.insert(.maskShift) }
        if alt == true { flags.insert(.maskAlternate) }
        if ctrl == true { flags.insert(.maskControl) }
        return flags
    }
}

struct StreamInfo: Encodable {
    let type = "info"
    let width: Int
    let height: Int
    let fps: Int
    let codec: String
    let displayID: UInt32
    let displays: [DisplayInfo]
}

enum BinaryFrame {
    static let headerSize = 12

    /// [0] kind, [1] flags, [2...3] reserved, [4...11] capture time as epoch millis.
    /// Server and browser share a clock here, so the client can subtract this from Date.now()
    /// for a true capture-to-decode latency measurement.
    static func encode(_ frame: H264Encoder.Frame) -> Data {
        var out = Data(capacity: frame.data.count + headerSize)
        out.append(1)
        out.append(frame.isKeyframe ? 1 : 0)
        out.append(0)
        out.append(0)
        withUnsafeBytes(of: frame.captureEpochMs.bitPattern.littleEndian) { out.append(contentsOf: $0) }
        out.append(frame.data)
        return out
    }
}

func epochMillis() -> Double {
    Date().timeIntervalSince1970 * 1000.0
}
