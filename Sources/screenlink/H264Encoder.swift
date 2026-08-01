import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 encoder producing Annex B access units suitable for the WebCodecs `VideoDecoder`.
final class H264Encoder {
    struct Frame {
        let data: Data
        let isKeyframe: Bool
        let captureEpochMs: Double
    }

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var forceKeyframe = true
    private var codecString: String?

    var onFrame: ((Frame) -> Void)?
    /// Fires once the SPS is available; the browser needs the real profile/level to configure its decoder.
    var onCodecString: ((String) -> Void)?

    func start(width: Int, height: Int, fps: Int, bitrate: Int) throws {
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue!,
        ]

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created)

        guard status == noErr, let s = created else {
            throw NSError(domain: "screenlink.encoder", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate failed (\(status))"])
        }

        func set(_ key: CFString, _ value: CFTypeRef) {
            let st = VTSessionSetProperty(s, key: key, value: value)
            if st != noErr { Log.warn("encoder property \(key) rejected (\(st))") }
        }

        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        // B-frames would add a frame of reordering delay for compression we do not need.
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        // PrioritizeEncodingSpeedOverQuality is deliberately not set: the low-latency rate
        // controller already implies it and rejects the property with kVTPropertyNotSupportedErr.
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * 4) as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        // A restart (display switch) produces a new SPS, so the codec string must be re-announced.
        codecString = nil
        forceKeyframe = true
        Log.info("encoder ready: \(width)x\(height) @ \(bitrate / 1_000_000)Mbps, low-latency rate control")
    }

    func stop() {
        guard let s = session else { return }
        session = nil
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(s)
    }

    /// A client joining mid-stream cannot decode anything until the next IDR, so request one immediately.
    func requestKeyframe() {
        lock.lock()
        forceKeyframe = true
        lock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, captureEpochMs: Double) {
        guard let s = session else { return }

        lock.lock()
        let force = forceKeyframe
        forceKeyframe = false
        lock.unlock()

        let props: CFDictionary? = force
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
            : nil

        VTCompressionSessionEncodeFrame(
            s,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: props,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            self?.handleEncoded(sampleBuffer, captureEpochMs: captureEpochMs)
        }
    }

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer, captureEpochMs: Double) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let isKey = Self.isKeyframe(sampleBuffer)
        var out = Data()

        if isKey, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            if codecString == nil, let cs = Self.codecString(from: format) {
                codecString = cs
                onCodecString?(cs)
            }
            // Every IDR carries its own SPS/PPS so a client can join at any keyframe.
            out.append(Self.parameterSetsAnnexB(format))
        }

        let total = CMBlockBufferGetDataLength(block)
        guard total > 0 else { return }
        var bytes = [UInt8](repeating: 0, count: total)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: &bytes) == kCMBlockBufferNoErr
        else { return }

        // VideoToolbox emits AVCC (4-byte big-endian length prefixes); WebCodecs wants Annex B start codes.
        var i = 0
        while i + 4 <= total {
            let n = Int(UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3]))
            i += 4
            guard n > 0, i + n <= total else { break }
            out.append(contentsOf: [0, 0, 0, 1] as [UInt8])
            out.append(contentsOf: bytes[i..<(i + n)])
            i += n
        }

        guard !out.isEmpty else { return }
        onFrame?(Frame(data: out, isKeyframe: isKey, captureEpochMs: captureEpochMs))
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[CFString: Any]],
            let first = attachments.first
        else { return true }
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool { return !notSync }
        return true
    }

    private static func parameterSetsAnnexB(_ format: CMFormatDescription) -> Data {
        var out = Data()
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr
        else { return out }

        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                let pointer
            else { continue }
            out.append(contentsOf: [0, 0, 0, 1] as [UInt8])
            out.append(UnsafeBufferPointer(start: pointer, count: size))
        }
        return out
    }

    /// Builds the `avc1.PPCCLL` string from the SPS so the browser configures a matching decoder.
    private static func codecString(from format: CMFormatDescription) -> String? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0,
            parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
            let sps = pointer, size >= 4
        else { return nil }
        return String(format: "avc1.%02X%02X%02X", sps[1], sps[2], sps[3])
    }
}
