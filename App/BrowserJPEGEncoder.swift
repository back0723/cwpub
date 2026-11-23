import Foundation
import AVFoundation
import CoreMedia
import CoreImage
import CoreGraphics
import ImageIO
import VideoToolbox

/// Browser-only compatibility encoder. It decodes the CarPlay H.264/H.265 access units with
/// VideoToolbox and re-encodes each decoded picture as a standalone JPEG. A JPEG frame is a
/// complete image, so the browser draws it directly on a 2D canvas and never needs an IDR
/// keyframe — this is the same mechanism CarMode 2.5 uses for old head-unit browsers.
///
/// All state is confined to `queue`. Frames are newest-wins under load: if the decoder is still
/// busy the pending sample is replaced, so a slow phone drops frames instead of growing a backlog.
final class BrowserJPEGEncoder {
    private final class CallbackBox {
        var output: ((CVPixelBuffer) -> Void)?
        var failure: ((OSStatus) -> Void)?
    }

    private let queue = DispatchQueue(label: "CarWithin.browser-jpeg", qos: .userInitiated)
    private let callbackBox = CallbackBox()
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var parameters: VideoParameterSets?
    private var decoding = false
    private var pending: Data?
    private var pendingKeyframe = false
    private var pts: Int64 = 0
    private var lastErrorUs: UInt64 = 0
    private let ciContext = CIContext(options: [CIContextOption.useSoftwareRenderer: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    /// JPEG quality, 0...1. Lower keeps an old phone fast and the LAN stream small.
    private let quality: NSNumber
    /// Emit at most this many JPEG frames per second. 0 means uncapped.
    private let maximumFPS: Int
    private var lastEmitUs: UInt64 = 0

    /// Called on `queue` with a complete JPEG (no leading opcode). The server adds its own header.
    var onJPEG: ((Data) -> Void)?

    private static let decompressionCallback: VTDecompressionOutputCallback = { reference, _, status, _, imageBuffer, _, _ in
        guard let reference else { return }
        let box: CallbackBox = Unmanaged.fromOpaque(reference).takeUnretainedValue()
        guard status == noErr else { box.failure?(status); return }
        guard let imageBuffer else { return }
        box.output?(imageBuffer)
    }

    init(quality: Float = 0.55, maximumFPS: Int = 20) {
        self.quality = NSNumber(value: Double(min(max(quality, 0.1), 1.0)))
        self.maximumFPS = maximumFPS
    }

    deinit {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// Reconfigure the decoder when SPS/PPS change. Safe to call with the same parameters.
    func configure(parameters newParameters: VideoParameterSets) {
        queue.async {
            guard newParameters.isComplete, newParameters != self.parameters else { return }
            self.parameters = newParameters
            self.rebuildSessionLocked(newParameters)
        }
    }

    /// Hand an access unit to the encoder. `sample` is the 4-byte length-prefixed picture array,
    /// i.e. the same buffer the MSE/WebCodecs path uses. Frames are newest-wins while busy.
    func enqueue(_ sample: Data, keyframe: Bool) {
        queue.async {
            guard self.session != nil else { return }
            if self.decoding {
                self.pending = sample
                self.pendingKeyframe = keyframe
                return
            }
            self.submitLocked(sample, keyframe: keyframe)
        }
    }

    /// Tear down the decoder. Called when no JPEG viewer remains.
    func invalidate() {
        queue.async {
            if let session = self.session {
                VTDecompressionSessionWaitForAsynchronousFrames(session)
                VTDecompressionSessionInvalidate(session)
            }
            self.session = nil
            self.formatDescription = nil
            self.parameters = nil
            self.pending = nil
            self.decoding = false
        }
    }

    // MARK: - session

    private func rebuildSessionLocked(_ parameters: VideoParameterSets) {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        var description: CMVideoFormatDescription?
        let status: OSStatus
        switch parameters.codec {
        case .h264:
            guard let sps = parameters.sps, let pps = parameters.pps else { return }
            let sets = [sps as NSData, pps as NSData]
            var pointers = sets.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
            var sizes = sets.map(\.length)
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: &pointers, parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        case .h265:
            guard let vps = parameters.vps, let sps = parameters.sps, let pps = parameters.pps else { return }
            let sets = [vps as NSData, sps as NSData, pps as NSData]
            var pointers = sets.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
            var sizes = sets.map(\.length)
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: &pointers, parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
        }
        guard status == noErr, let description else { return }
        formatDescription = description

        callbackBox.output = { [weak self] buffer in
            guard let self else { return }
            self.queue.async { self.handleDecodedLocked(buffer) }
        }
        callbackBox.failure = { [weak self] code in
            guard let self else { return }
            self.queue.async {
                let now = DispatchTime.now().uptimeNanoseconds / 1000
                if now - self.lastErrorUs > 2_000_000 {
                    self.lastErrorUs = now
                    self.onLog?("JPEG 解码失败（\(code)），等待下一关键帧")
                }
                self.decoding = false
                self.drainPendingLocked()
            }
        }

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.decompressionCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(callbackBox).toOpaque()
        )
        var created: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: description,
            decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &record, decompressionSessionOut: &created)
        guard createStatus == noErr, let created else { return }
        _ = VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        decoding = false
    }

    /// Optional log hook wired by the server.
    var onLog: ((String) -> Void)?

    // MARK: - decode / encode

    private func submitLocked(_ sample: Data, keyframe: Bool) {
        guard let session, let formatDescription, sample.count > 4 else { return }
        decoding = true
        var block: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: sample.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: sample.count, flags: 0, blockBufferOut: &block)
        guard createStatus == kCMBlockBufferNoErr, let block else {
            decoding = false; return
        }
        let copyStatus = sample.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block,
                                                  offsetIntoDestination: 0, dataLength: sample.count)
        }
        guard copyStatus == kCMBlockBufferNoErr else { decoding = false; return }

        pts &+= 1
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var sampleSize = sample.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer)
        guard sampleStatus == noErr, let sampleBuffer else { decoding = false; return }
        if !keyframe {
            CMSetAttachment(sampleBuffer, key: kCMSampleAttachmentKey_NotSync,
                            value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
        }
        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
            frameRefcon: nil, infoFlagsOut: &infoFlags)
        if decodeStatus != noErr {
            decoding = false
            drainPendingLocked()
        }
    }

    private func handleDecodedLocked(_ buffer: CVPixelBuffer) {
        defer {
            decoding = false
            drainPendingLocked()
        }
        if maximumFPS > 0 {
            let now = DispatchTime.now().uptimeNanoseconds / 1000
            let minimumInterval = 1_000_000 / UInt64(maximumFPS)
            guard now - lastEmitUs >= minimumInterval else { return }
            lastEmitUs = now
        }
        let image = CIImage(cvPixelBuffer: buffer)
        let options: [CIImageRepresentationOption: Any] = [
            .lossyCompressionQuality: quality
        ]
        guard let jpeg = try? ciContext.jpegRepresentation(of: image, colorSpace: colorSpace,
                                                           options: options) else { return }
        onJPEG?(jpeg)
    }

    private func drainPendingLocked() {
        guard !decoding, let next = pending else { return }
        pending = nil
        submitLocked(next, keyframe: pendingKeyframe)
    }
}
