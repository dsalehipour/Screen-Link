import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

protocol ScreenCapturerDelegate: AnyObject {
    func capturer(_ capturer: ScreenCapturer, didCapture pixelBuffer: CVPixelBuffer, pts: CMTime)
}

struct DisplayInfo: Encodable {
    let index: Int
    let id: UInt32
    let name: String
    let width: Int
    let height: Int
    let x: Int
    let y: Int
    let isMain: Bool
}

enum CaptureError: Error, CustomStringConvertible {
    case noDisplay
    case unknownDisplay(UInt32)
    case notRunning

    var description: String {
        switch self {
        case .noDisplay: return "no shareable display found (is screen recording permission granted?)"
        case .unknownDisplay(let id): return "display \(id) is not attached"
        case .notRunning: return "capture is not running"
        }
    }
}

final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    /// User-interactive QoS keeps the capture/encode path on performance cores. At background or
    /// utility QoS the scheduler confines this work to efficiency cores and frame times roughly triple.
    private let queue = DispatchQueue(label: "screenlink.capture", qos: .userInteractive)

    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private var maxWidth = 1920
    private var fps = 60

    weak var delegate: ScreenCapturerDelegate?
    private(set) var displayID: CGDirectDisplayID = 0
    private(set) var width: Int = 0
    private(set) var height: Int = 0

    // MARK: - Display enumeration

    static func availableDisplays() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let names = await displayNames()
        return content.displays.enumerated().map { index, display in
            DisplayInfo(
                index: index,
                id: display.displayID,
                name: names[display.displayID] ?? "Display \(display.displayID)",
                width: display.width,
                height: display.height,
                x: Int(display.frame.origin.x),
                y: Int(display.frame.origin.y),
                isMain: CGDisplayIsMain(display.displayID) != 0)
        }
    }

    /// SCDisplay carries no human-readable name, so labels come from NSScreen matched on screen number.
    @MainActor
    private static func displayNames() -> [CGDirectDisplayID: String] {
        var map: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let number = screen.deviceDescription[key] as? CGDirectDisplayID {
                map[number] = screen.localizedName
            }
        }
        return map
    }

    // MARK: - Lifecycle

    func start(displayID requested: CGDirectDisplayID?, maxWidth: Int, fps: Int) async throws {
        self.maxWidth = maxWidth
        self.fps = fps

        let display = try await resolve(requested)
        let (cfg, w, h) = makeConfiguration(for: display)
        let filter = SCContentFilter(display: display, excludingWindows: [])

        displayID = display.displayID
        width = w
        height = h
        configuration = cfg

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s

        Log.info("capturing display \(display.displayID) at \(w)x\(h) @ \(fps)fps")
    }

    /// Retargets the live stream instead of tearing it down. The caller still has to restart the
    /// encoder, since displays rarely share a resolution.
    func switchTo(displayID requested: CGDirectDisplayID) async throws {
        guard let stream else { throw CaptureError.notRunning }
        let display = try await resolve(requested)
        let (cfg, w, h) = makeConfiguration(for: display)
        let filter = SCContentFilter(display: display, excludingWindows: [])

        try await stream.updateContentFilter(filter)
        try await stream.updateConfiguration(cfg)

        displayID = display.displayID
        width = w
        height = h
        configuration = cfg

        Log.info("switched to display \(display.displayID) at \(w)x\(h)")
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    /// One-shot capture for the agent path. Defaults to the streaming display but can target any.
    func screenshot(displayID requested: CGDirectDisplayID? = nil) async throws -> CVPixelBuffer? {
        let display = try await resolve(requested ?? displayID)
        let (cfg, _, _) = makeConfiguration(for: display)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: cfg)
        return sample.imageBuffer
    }

    // MARK: - Helpers

    private func resolve(_ requested: CGDirectDisplayID?) async throws -> SCDisplay {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else { throw CaptureError.noDisplay }
        guard let requested, requested != 0 else {
            return content.displays.first { CGDisplayIsMain($0.displayID) != 0 } ?? content.displays[0]
        }
        guard let match = content.displays.first(where: { $0.displayID == requested }) else {
            throw CaptureError.unknownDisplay(requested)
        }
        return match
    }

    private func makeConfiguration(for display: SCDisplay) -> (SCStreamConfiguration, Int, Int) {
        var w = display.width
        var h = display.height
        if w > maxWidth {
            h = Int((Double(h) * Double(maxWidth) / Double(w)).rounded())
            w = maxWidth
        }
        // H.264 requires even dimensions.
        w -= w % 2
        h -= h % 2

        let cfg = SCStreamConfiguration()
        cfg.width = w
        cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        // NV12 is the encoder's native input, so frames reach VideoToolbox without a pixel conversion.
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.queueDepth = 5
        cfg.showsCursor = true
        cfg.capturesAudio = false
        return (cfg, w, h)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // ScreenCaptureKit emits .idle/.blank frames when nothing changed. Encoding those would burn
        // bitrate and encoder time redrawing an identical screen, so only .complete frames continue.
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw), status == .complete,
            let pixelBuffer = sampleBuffer.imageBuffer
        else { return }

        delegate?.capturer(self, didCapture: pixelBuffer, pts: sampleBuffer.presentationTimeStamp)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("capture stopped: \(error.localizedDescription)")
    }
}
