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
    /// Downscale anything wider than this before encoding. Old head units decode a 1436×640
    /// JPEG per frame slowly; 1280 keeps the picture usable with a much cheaper decode.
    private var maximumWidth: CGFloat
    private var lastEmitUs: UInt64 = 0
    /// Frames dropped because no decoder existed yet; logged throttled to keep the log readable.
    private var droppedWhileUnready = 0
    /// First JPEG actually produced, logged once per decoder lifetime as end-to-end proof.
    private var loggedFirstJPEG = false
    /// Consecutive decode failures. Two in a row means the hardware decoder is not usable for
    /// this stream (it shares the iPhone's single hardware H.264 channel with the local preview
    /// and answers -12903 kVTVideoDecoderMalfunctionErr), so the decoder drops to software.
    private var decodeFailures = 0
    /// Latched once software decoding was needed; kept for the process lifetime.
    private var softwareDecode = false

    /// Called on `queue` with a complete JPEG (no leading opcode). The server adds its own header.
    var onJPEG: ((Data) -> Void)?

    private static let decompressionCallback: VTDecompressionOutputCallback = { reference, _, status, _, imageBuffer, _, _ in
        guard let reference else { return }
        let box: CallbackBox = Unmanaged.fromOpaque(reference).takeUnretainedValue()
        guard status == noErr else { box.failure?(status); return }
        guard let imageBuffer else { return }
        box.output?(imageBuffer)
    }

    init(quality: Float = 0.55, maximumFPS: Int = 20, maximumWidth: CGFloat = 1280) {
        self.quality = NSNumber(value: Double(min(max(quality, 0.1), 1.0)))
        self.maximumFPS = maximumFPS
        self.maximumWidth = maximumWidth
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
            guard newParameters.isComplete else {
                self.onLog?("JPEG 解码器暂不能配置：参数集不完整（SPS \(newParameters.sps?.count ?? 0) / PPS \(newParameters.pps?.count ?? 0)）")
                return
            }
            let unchanged = newParameters == self.parameters
            self.parameters = newParameters
            // 每次 CarPlay 会话重启都会把服务端的参数集清空重来，而这里保存的可能是上一场的，
            // 参数没变但解码器已经不在了（-12903 之后被扔掉）也必须重建，否则画面永远不出来。
            if unchanged, self.session != nil, !self.softwareDecode { return }
            self.rebuildSessionLocked(newParameters, software: self.softwareDecode)
        }
    }

    /// Hand an access unit to the encoder. `sample` is the 4-byte length-prefixed picture array,
    /// i.e. the same buffer the MSE/WebCodecs path uses. Frames are newest-wins while busy.
    func enqueue(_ sample: Data, keyframe: Bool) {
        queue.async {
            // A compatibility viewer can connect long after the configuration record, and a
            // stream reset can drop it: recover SPS/PPS from the access unit itself so the JPEG
            // path can never stay silent just because configure() was never reached.
            if self.session == nil {
                self.adoptLocked(from: sample)
                // 这一帧没带参数集（普通 P 帧）时，用上一次缓存的参数集也要把解码器建起来，
                // 否则一次 -12903 之后兼容画面就再也不会恢复。
                if self.session == nil, let stored = self.parameters {
                    self.rebuildSessionLocked(stored, software: self.softwareDecode)
                }
            }
            guard self.session != nil else {
                self.droppedWhileUnready += 1
                if self.droppedWhileUnready == 1 || self.droppedWhileUnready % 90 == 0 {
                    self.onLog?("JPEG 兼容未就绪：还没有可用的 SPS/PPS，已丢弃 \(self.droppedWhileUnready) 帧")
                }
                return
            }
            self.droppedWhileUnready = 0
            if self.decoding {
                self.pending = sample
                self.pendingKeyframe = keyframe
                return
            }
            self.submitLocked(sample, keyframe: keyframe)
        }
    }

    /// When no decoder survives: rebuild it from the parameter sets carried by this access unit.
    private func adoptLocked(from sample: Data) {
        guard let sets = Self.parameterSets(in: sample) else { return }
        if sets != parameters {
            parameters = sets
            onLog?("JPEG 兼容：从访问单元补齐参数集（\(sets.codec.displayName) SPS \(sets.sps?.count ?? 0) / PPS \(sets.pps?.count ?? 0)）")
        }
        rebuildSessionLocked(sets, software: softwareDecode)
        if session != nil {
            onLog?("JPEG 兼容解码器已建立（\(sets.codec.displayName)，\(softwareDecode ? "软件" : "硬件")解码）")
        }
    }

    /// Reads the 4-byte length-prefixed NAL units of one access unit and returns the parameter
    /// sets it carries (H.264 SPS/PPS or H.265 VPS/SPS/PPS). Returns nil when it carries none.
    static func parameterSets(in sample: Data) -> VideoParameterSets? {
        let bytes = [UInt8](sample)
        var offset = 0
        var units: [UInt8: Data] = [:]
        var codec: VideoCodec?
        while offset + 4 <= bytes.count {
            let length = (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
                       | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            offset += 4
            guard length > 0, length <= bytes.count - offset else { return nil }
            let unit = Data(bytes[offset..<(offset + length)])
            offset += length
            guard let first = unit.first else { continue }
            let h264 = first & 0x1f
            let h265 = (first >> 1) & 0x3f
            if h264 == 7 { units[7] = unit; codec = .h264 }
            else if h264 == 8 { units[8] = unit; codec = codec ?? .h264 }
            else if h265 == 32 { units[32] = unit; codec = codec ?? .h265 }
            else if h265 == 33 { units[33] = unit; codec = codec ?? .h265 }
            else if h265 == 34 { units[34] = unit; codec = codec ?? .h265 }
        }
        guard let codec else { return nil }
        switch codec {
        case .h264:
            guard let sps = units[7], let pps = units[8] else { return nil }
            return VideoParameterSets(codec: .h264, sps: sps, pps: pps)
        case .h265:
            guard let vps = units[32], let sps = units[33], let pps = units[34] else { return nil }
            return VideoParameterSets(codec: .h265, vps: vps, sps: sps, pps: pps)
        }
    }

    /// 车机自己上报的帧率决定兼容画面有多宽：软解跟不上就降到下一档，只改编码宽度，
    /// 高度按画面计划的比例跟着走，不会被拉变形。实测那台 CM8049（Android 4.2）扛不住时值这个。
    func setMaximumWidth(_ width: CGFloat) {
        queue.async {
            let clamped = min(max(width, 640), 1920)
            guard clamped != self.maximumWidth else { return }
            self.maximumWidth = clamped
            self.onLog?("JPEG 兼容画面宽度改为 \(Int(clamped))")
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
            self.droppedWhileUnready = 0
            self.decodeFailures = 0
            self.loggedFirstJPEG = false
        }
    }

    // MARK: - session

    private func rebuildSessionLocked(_ parameters: VideoParameterSets, software: Bool = false) {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        var description: CMVideoFormatDescription?
        let status: OSStatus
        switch parameters.codec {
        case .h264:
            guard let sps = parameters.sps, let pps = parameters.pps else {
                onLog?("JPEG 解码器缺少 H.264 参数集（SPS \(parameters.sps?.count ?? 0) / PPS \(parameters.pps?.count ?? 0)）")
                return
            }
            let sets = [sps as NSData, pps as NSData]
            var pointers = sets.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
            var sizes = sets.map(\.length)
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: &pointers, parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        case .h265:
            guard let vps = parameters.vps, let sps = parameters.sps, let pps = parameters.pps else {
                onLog?("JPEG 解码器缺少 H.265 参数集（VPS \(parameters.vps?.count ?? 0) / SPS \(parameters.sps?.count ?? 0) / PPS \(parameters.pps?.count ?? 0)）")
                return
            }
            let sets = [vps as NSData, sps as NSData, pps as NSData]
            var pointers = sets.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
            var sizes = sets.map(\.length)
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: &pointers, parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
        }
        guard status == noErr, let description else {
            onLog?("JPEG 解码器建立失败：参数集无法生成格式描述（OSStatus \(status)）")
            return
        }
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
        // 硬解通道在这台 iPhone 上只有一个：本机预览已经占了，兼容解码器再要就会被
        // 反复拒绝（-12903 kVTVideoDecoderMalfunctionErr）。software=true 时显式禁用硬解。
        // 常量 kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder 在 Swift 里
        // 带 iOS 17 可用性标注，这里用同名字符串键，运行时行为一致且能编译到低版本 iOS。
        let specification: CFDictionary? = software
            ? (["EnableHardwareAcceleratedVideoDecoder": false] as CFDictionary)
            : nil
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: description,
            decoderSpecification: specification, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &record, decompressionSessionOut: &created)
        guard createStatus == noErr, let created else {
            onLog?("JPEG 解码器建立失败：VTDecompressionSessionCreate 返回 \(createStatus)")
            return
        }
        _ = VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        decoding = false
        decodeFailures = 0
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
            let now = DispatchTime.now().uptimeNanoseconds / 1000
            if now - lastErrorUs > 2_000_000 {
                lastErrorUs = now
                onLog?("JPEG 提交解码失败（\(decodeStatus)），等待下一关键帧")
            }
            decoding = false
            recoverLocked(status: decodeStatus, sample: sample)
            drainPendingLocked()
        }
    }

    /// 解码失败后的自愈阶梯：先用这一帧里的参数集重建（会话换了分辨率时旧格式描述会一直报错），
    /// 再退软件解码（硬解通道被本机预览占着，硬解会一直 -12903），最后才把解码器扔掉等关键帧。
    private func recoverLocked(status: OSStatus, sample: Data) {
        decodeFailures += 1
        if let sets = Self.parameterSets(in: sample), sets.isComplete, sets != parameters {
            parameters = sets
            onLog?("JPEG 兼容：解码失败（\(status)），按这一帧的新参数集重建解码器")
            rebuildSessionLocked(sets, software: softwareDecode)
            return
        }
        if decodeFailures >= 2, !softwareDecode {
            softwareDecode = true
            onLog?("JPEG 解码失败（\(status)），改用软件解码（硬解通道被本机预览占用）")
            if let parameters { rebuildSessionLocked(parameters, software: true) } else { session = nil }
            return
        }
        if decodeFailures >= 8 {
            session = nil
            formatDescription = nil
            parameters = nil
            decodeFailures = 0
            droppedWhileUnready = 0
            onLog?("JPEG 解码器连续失败（\(status)），已重置，等下一个关键帧")
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
        var image = CIImage(cvPixelBuffer: buffer)
        let width = image.extent.width
        if maximumWidth > 0, width > maximumWidth {
            let scale = maximumWidth / width
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
        ]
        guard let jpeg = try? ciContext.jpegRepresentation(of: image, colorSpace: colorSpace,
                                                           options: options) else {
            let now = DispatchTime.now().uptimeNanoseconds / 1000
            if now - lastErrorUs > 2_000_000 {
                lastErrorUs = now
                onLog?("JPEG 编码失败：CIContext 未能生成 JPEG")
            }
            return
        }
        if !loggedFirstJPEG {
            loggedFirstJPEG = true
            onLog?("JPEG 兼容画面已送出：\(Int(image.extent.width))×\(Int(image.extent.height))，首帧 \(jpeg.count) 字节")
        }
        onJPEG?(jpeg)
    }

    private func drainPendingLocked() {
        guard !decoding, let next = pending else { return }
        pending = nil
        submitLocked(next, keyframe: pendingKeyframe)
    }
}
