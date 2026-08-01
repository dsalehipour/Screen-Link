import CryptoKit
import Foundation

/// Minimal RFC 6455 framing.
///
/// Network.framework can only apply `NWProtocolWebSocket` to an entire listener, which would force
/// WebSocket and HTTP onto separate ports. Two ports means two origins, and therefore two TLS
/// certificates to trust and a reverse proxy that has to be told about both. Framing by hand is a
/// few dozen lines and lets everything share one port, one certificate, one URL.
enum WebSocketProtocol {
    /// Fixed by RFC 6455; concatenated with the client key to derive the handshake response.
    private static let handshakeGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    struct Frame {
        let opcode: Opcode
        let payload: Data
        let isFinal: Bool
    }

    static func acceptKey(for clientKey: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((clientKey + handshakeGUID).utf8))
        return Data(digest).base64EncodedString()
    }

    static func handshakeResponse(acceptKey: String) -> Data {
        Data([
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(acceptKey)",
            "", "",
        ].joined(separator: "\r\n").utf8)
    }

    /// Server-to-client frames are never masked, per the spec.
    static func encode(_ payload: Data, opcode: Opcode) -> Data {
        var out = Data()
        out.append(0x80 | opcode.rawValue)

        let count = payload.count
        if count < 126 {
            out.append(UInt8(count))
        } else if count <= 0xFFFF {
            out.append(126)
            out.append(UInt8(truncatingIfNeeded: count >> 8))
            out.append(UInt8(truncatingIfNeeded: count))
        } else {
            out.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8(truncatingIfNeeded: count >> shift))
            }
        }
        out.append(payload)
        return out
    }

    /// Pulls every complete frame out of `buffer`, leaving any partial trailing frame in place.
    /// Returns nil if the stream is malformed and the connection should be dropped.
    static func decode(from buffer: inout [UInt8]) -> [Frame]? {
        var frames: [Frame] = []
        var cursor = 0

        while true {
            guard buffer.count - cursor >= 2 else { break }
            let start = cursor

            let first = buffer[cursor]
            let second = buffer[cursor + 1]
            cursor += 2

            guard let opcode = Opcode(rawValue: first & 0x0F) else { return nil }
            let isFinal = first & 0x80 != 0
            let isMasked = second & 0x80 != 0

            var length = Int(second & 0x7F)
            if length == 126 {
                guard buffer.count - cursor >= 2 else { cursor = start; break }
                length = Int(buffer[cursor]) << 8 | Int(buffer[cursor + 1])
                cursor += 2
            } else if length == 127 {
                guard buffer.count - cursor >= 8 else { cursor = start; break }
                length = 0
                for i in 0..<8 { length = length << 8 | Int(buffer[cursor + i]) }
                cursor += 8
                // A frame this large is either a bug or an attack; either way, do not allocate it.
                guard length <= 1 << 26 else { return nil }
            }

            // The spec requires clients to mask. Refusing unmasked frames avoids a cache-poisoning
            // class of attack against intermediaries.
            guard isMasked else { return nil }
            guard buffer.count - cursor >= 4 else { cursor = start; break }
            let mask = Array(buffer[cursor..<(cursor + 4)])
            cursor += 4

            guard buffer.count - cursor >= length else { cursor = start; break }
            var payload = Array(buffer[cursor..<(cursor + length)])
            cursor += length
            for i in 0..<payload.count { payload[i] ^= mask[i % 4] }

            frames.append(Frame(opcode: opcode, payload: Data(payload), isFinal: isFinal))
        }

        if cursor > 0 { buffer.removeFirst(cursor) }
        return frames
    }
}
