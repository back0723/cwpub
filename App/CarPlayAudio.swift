// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AVFoundation
import CryptoKit
import Darwin
import Network

private final class AudioDatagramPort {
    let port: UInt16
    private var source: DispatchSourceRead?
    var onPacket: ((Data) -> Void)?
    init(queue: DispatchQueue, peerAddress: String) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var receiveBuffer: Int32 = 512 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
        var allowed = in_addr()
        guard inet_pton(AF_INET, peerAddress, &allowed) == 1 else { close(fd); throw ProtocolError.malformed("音频对端地址") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { close(fd); throw POSIXError(.EIO) }
        var count = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &count) } }
        guard named == 0 else { close(fd); throw POSIXError(.EIO) }
        port = UInt16(bigEndian: address.sin_port)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue); self.source = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Bound the work per dispatch so media cannot starve control traffic.
            var bytes = [UInt8](repeating: 0, count: 65536)
            for _ in 0..<32 {
                var peer = sockaddr_in(); var size = socklen_t(MemoryLayout<sockaddr_in>.size)
                let length = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &bytes, 65536, 0, $0, &size) } }
                guard length > 0 else { break }
                guard peer.sin_addr.s_addr == allowed.s_addr else { continue }
                self.onPacket?(Data(bytes.prefix(length)))
            }
        }
        source.setCancelHandler { close(fd) }; source.resume()
    }
    func stop() { source?.cancel(); source = nil; onPacket = nil }
    deinit { stop() }
}

final class CarPlayAudio {
    let dataPort: UInt16
    let controlPort: UInt16
    let format: ReceiverAudioFormat
    let connectionID: UInt64
    private let queue: DispatchQueue
    private let data: AudioDatagramPort
    private let control: AudioDatagramPort
    private let cipher: AudioStream
    // Construct the playback graph only when authenticated audio actually arrives. Creating
    // it during RTSP SETUP can block for seconds while iOS switches the CarPlay audio route.
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let output: AVAudioFormat
    private let decoder: NativeAudioDecoder
    private var microphone: NativeMicrophone?
    private var queuedFrames = 0
    private var active = true
    private var playing = false
    private var rejected = 0
    private var firstTimestamp: UInt32?
    private var lastTimestamp: UInt32?
    private var buffering = true
    private var packets = 0
    private var latePackets = 0
    private var overflowPackets = 0
    private var underruns = 0
    /// 媒体音频（102 AAC）的载荷体征：真机上解码一直 -50，得先看清 iPhone 到底送了多大的包。
    private var minPayload = Int.max
    private var maxPayload = 0
    private var decodedPackets = 0
    private var nextStatistics = 0.0
    private var retryPlaybackAt = 0.0
    /// 通話/其他音頻占用時只記一次日誌，避免每包刷屏。
    private var loggedOtherAudio = false
    private let feedbackLock = NSLock()
    private var renderedSampleTime: UInt32?
    private var browserClock: (rtp: UInt32, host: UInt64)?
    private static let renderQueue = DispatchQueue(label: "TDSCarKit.audio", qos: .userInteractive)
    // Audio decoding never blocks the video/RTSP queue. All streams share this queue.
    private static var playingStreams = 0
    #if os(iOS)
    private static var hasSpeakerOverride = false
    #endif
    var onLog: ((String) -> Void)?
    var onBrowserAudio: ((AVAudioPCMBuffer, UInt64) -> Void)?
    /// 每个解码出来的 PCM 缓冲都会先走这里一次，用于把伴音送给 CarLife 车机端。
    var onPCM: ((AVAudioPCMBuffer) -> Void)?
    /// 车机页面上是否真的有人在要声音。返回 false（或未设置）时音频在本机播放。
    var shouldForwardAudio: (() -> Bool)?
    /// 声音选项选了"车机蓝牙"：本机播放时优先把音频送到车机蓝牙（A2DP），而不是手机扬声器。
    static var preferBluetoothOutput = false
    /// 麦克风输入设置：true 用 iPhone 麦克风，false 不占用手机麦克风（交给车机/系统）。
    static var capturesMicrophone = true
    init(secret: SymmetricKey, peerAddress: String, connectionID: UInt64, format: ReceiverAudioFormat, microphonePort: UInt16? = nil) throws {
        self.queue = Self.renderQueue; self.connectionID = connectionID; self.format = format
        decoder = try NativeAudioDecoder(format: format)
        output = decoder.output
        cipher = AudioStream(secret: secret, connectionID: connectionID)
        data = try AudioDatagramPort(queue: Self.renderQueue, peerAddress: peerAddress)
        control = try AudioDatagramPort(queue: Self.renderQueue, peerAddress: peerAddress)
        dataPort = data.port; controlPort = control.port
        if let microphonePort, !format.isAAC, format.channels == 1, Self.capturesMicrophone {
            microphone = NativeMicrophone(secret: secret, connectionID: connectionID, address: peerAddress, port: microphonePort, format: format)
        }
        data.onPacket = { [weak self] in self?.receive($0) }
        decoder.onLog = { [weak self] text in self?.onLog?(text) }
    }
    private func receive(_ wire: Data) {
        guard active else { return }
        do {
            let packet = try cipher.receive(wire)
            minPayload = min(minPayload, packet.samples.count); maxPayload = max(maxPayload, packet.samples.count)
            let arrival = DispatchTime.now().uptimeNanoseconds / 1000
            // Decode every accepted compressed packet to preserve the codec's overlap state.
            packets += 1
            if let lastTimestamp, Int32(bitPattern: packet.timestamp &- lastTimestamp) <= 0 { latePackets += 1; return }
            lastTimestamp = packet.timestamp
            guard let buffer = try decoder.decode(packet.samples) else { return }
            decodedPackets += 1
            onPCM?(buffer)
            // 只有在车机页面上真的有人在要声音时才转发；没人要就让下面的本地播放跑起来，
            // 不然这条音频包会被转发到一个不存在的听众那里，手机和车机同时没声音。
            if let onBrowserAudio, shouldForwardAudio?() ?? true {
                onBrowserAudio(buffer, browserTimestamp(packet.timestamp, arrival: arrival))
                return
            }
            let frames = Int(buffer.frameLength)
            guard queuedFrames + frames <= format.sampleRate * 2 else { overflowPackets += 1; return }
            if !playing {
                let now = ProcessInfo.processInfo.systemUptime
                guard now >= retryPlaybackAt else { return }
                retryPlaybackAt = now + 0.5
                #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                // 修复「通话双方听不到」：
                // 旧逻辑只要检测到 isOtherAudioPlaying 就整包 return，等于通话时本机一丁点声音都不放；
                // 而且通话前 setCategory(.playback/.playAndRecord) 会把 iPhone 的 CarPlay 音频路由
                // 从微信通话那儿抢过来，微信自己的声音进不了听筒 —— 这才是「双方都没声音」的根因。
                // 新策略：通话期间不碰 category / 不 setActive / 不 overrideOutputAudioPort，
                // 只用 .mixWithOthers 把解码出的对方声音温和地混入当前路由（微信正在用的那个输出）。
                // 对方声音同时早已在 onPCM 里送到 CarLife 通道 3、在 onBrowserAudio 里送到网页。
                let needsDuplexCategory = microphone != nil || Self.hasSpeakerOverride
                let inCall = session.isOtherAudioPlaying
                var options: AVAudioSession.CategoryOptions = needsDuplexCategory ? [.defaultToSpeaker] : []
                if Self.preferBluetoothOutput { options.insert(.allowBluetoothA2DP) }
                if inCall {
                    // 通话中：绝不 setCategory / setActive / overrideOutputAudioPort，也绝不切路由。
                    // 这些动作都会把微信正在用的 CarPlay/听筒路由抢走，正是「双方没声音」的根因。
                    // 直接建 AVAudioEngine 播放图，用当前会话把解码出的对方声音混进去；
                    // 同一份 PCM 已在 onPCM 送 CarLife 通道3、在 onBrowserAudio 送网页。
                    if !loggedOtherAudio {
                        loggedOtherAudio = true
                        onLog?("通话占用音频：不抢占路由，对方声音混入本机并送通道3/网页")
                    }
                } else {
                    loggedOtherAudio = false
                    // 要录音时绝不能带 .mixWithOthers：后台里“可混音的录音”会被系统直接拒绝
                    // （AVAudioSession.ErrorCode.cannotStartRecording / 561145187）。
                    if BackgroundKeepAlive.holdsAudioSession, microphone == nil { options.insert(.mixWithOthers) }
                    let category: AVAudioSession.Category = needsDuplexCategory ? .playAndRecord : .playback
                    if session.category != category || session.mode != .default || session.categoryOptions != options {
                        try session.setCategory(category, mode: .default, options: options)
                    }
                    try session.setActive(true)
                    if Self.preferBluetoothOutput, microphone == nil {
                        // 想让车机喇叭出声：先把音频从虚拟 CarPlay 路由上摘下来，交给蓝牙。
                        if session.category != .playback {
                            try session.setCategory(.playback, mode: .default, options: options.union(.allowBluetoothA2DP))
                        }
                        try? session.overrideOutputAudioPort(.none)
                        let bluetooth = session.currentRoute.outputs.contains {
                            $0.portType == .bluetoothA2DP || $0.portType == .bluetoothLE || $0.portType == .bluetoothHFP
                        }
                        if bluetooth {
                            onLog?("音频输出走车机蓝牙：\(session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ", "))")
                        } else if session.currentRoute.outputs.contains(where: { $0.portType == .carAudio }) {
                            try session.setCategory(.playAndRecord, mode: .default, options: options.union(.defaultToSpeaker))
                            try session.overrideOutputAudioPort(.speaker)
                            Self.hasSpeakerOverride = true
                            onLog?("没找到车机蓝牙音频（先在 iPhone 设置里连上），改用 iPhone 扬声器")
                        }
                    } else if session.currentRoute.outputs.contains(where: { $0.portType == .carAudio }) {
                        // In the same-device session CarAudio is our own virtual CarPlay receiver.
                        // Feeding decoded audio back into that route leaves the physical speaker silent.
                        if session.category != .playAndRecord {
                            try session.setCategory(.playAndRecord, mode: .default, options: options.union(.defaultToSpeaker))
                        }
                        do {
                            try session.overrideOutputAudioPort(.speaker)
                            Self.hasSpeakerOverride = true
                            onLog?("本机音频避开 CarPlay 路由，改用 iPhone 扬声器")
                        } catch {
                            Self.deactivateSessionIfIdle()
                            throw error
                        }
                    }
                }
                #endif
                let engine: AVAudioEngine
                if let existing = self.engine { engine = existing }
                else {
                    engine = AVAudioEngine()
                    let player = AVAudioPlayerNode()
                    engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: output)
                    self.engine = engine; self.player = player
                }
                do { try engine.start() } catch {
                    #if os(iOS)
                    Self.deactivateSessionIfIdle()
                    #endif
                    throw error
                }
                playing = true; Self.playingStreams += 1
                if let microphone {
                    microphone.onLog = onLog
                    DispatchQueue.main.async { microphone.start() }
                }
                firstTimestamp = packet.timestamp
                onLog?("原生 \(format.name) 播放已开始：\(format.sampleRate) Hz，\(format.channels) 声道")
                #if os(iOS)
                onLog?("音频输出路由：\(AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ", "))")
                #endif
            }
            guard let player else { return }
            queuedFrames += frames
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self, self.active else { return }
                    self.queuedFrames = max(0, self.queuedFrames - frames)
                    if self.queuedFrames == 0, !self.buffering {
                        self.player?.pause(); self.buffering = true; self.underruns += 1
                    }
                }
            }
            let prebuffer = format.sampleRate * (format.isAAC ? 180 : 40) / 1000
            if buffering, queuedFrames >= prebuffer {
                player.play(); buffering = false
            }
            updateFeedback()
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextStatistics {
                nextStatistics = now + 5
            onLog?("音频状态：数据包=\(packets)，队列=\(queuedFrames * 1000 / format.sampleRate)ms，欠载=\(underruns)，延迟=\(latePackets)，溢出=\(overflowPackets)，拒绝=\(rejected)，载荷=\(minPayload == Int.max ? 0 : minPayload)–\(maxPayload) 字节，解出=\(decodedPackets)")
            }

        } catch {
            rejected += 1
            if rejected <= 3 {
                onLog?("音频数据包被拒绝：\(error.localizedDescription)（\(format.name) \(format.sampleRate) Hz / \(format.channels) 声道，负载 \(wire.count) 字节）")
            }
        }
    }
    private func browserTimestamp(_ rtp: UInt32, arrival: UInt64) -> UInt64 {
        if let anchor = browserClock {
            let samples = Int64(Int32(bitPattern: rtp &- anchor.rtp))
            let position = Int64(anchor.host) + samples * 1_000_000 / Int64(format.sampleRate)
            // Keep source timing through packet bursts, and re-anchor after a genuine clock reset.
            if samples >= 0, position >= 0, abs(position - Int64(arrival)) < 500_000 {
                return UInt64(position)
            }
        }
        browserClock = (rtp, arrival)
        return arrival
    }

    private func updateFeedback() {
        guard let firstTimestamp, let player, let render = player.lastRenderTime,
              let position = player.playerTime(forNodeTime: render) else { return }
        let rendered = firstTimestamp &+ UInt32(truncatingIfNeeded: max(0, position.sampleTime))
        feedbackLock.lock()
        renderedSampleTime = rendered
        feedbackLock.unlock()
    }

    func feedback(type: Int, ntp: UInt64) -> [String: Any] {
        // Never wait for AVAudioEngine or an iOS route transition on the RTSP/video queue.
        feedbackLock.lock()
        let rendered = renderedSampleTime
        feedbackLock.unlock()
        var info: [String: Any] = ["type": type, "sampleRate": format.sampleRate]
        if let rendered {
            info["sampleTime"] = NSNumber(value: rendered)
            info["timestamp"] = NSNumber(value: ntp)
            info["streamConnectionID"] = NSNumber(value: connectionID)
        }
        return info
    }

    func stop() {
        // Keep this stream alive until its queued teardown completes; a replacement stream may
        // negotiate immediately, but the render queue always observes the old stop first.
        queue.async { self.stopOnQueue() }
    }
    static func endMediaSession() {
        #if os(iOS)
        renderQueue.async { deactivateSessionIfIdle(releaseSpeakerOverride: true) }
        #endif
    }
    private func stopOnQueue() {
        guard active else { return }; active = false
        if let microphone { DispatchQueue.main.async { microphone.stop() } }; microphone = nil
        data.stop(); control.stop(); player?.stop(); engine?.stop(); queuedFrames = 0
        if playing {
            playing = false; Self.playingStreams -= 1
            #if os(iOS)
            Self.deactivateSessionIfIdle()
            #endif
        }
    }
    #if os(iOS)
    /// Releases the shared session after the last stream, unless the background keep-alive still
    /// plays in it: deactivating would stop that player too and iOS would suspend the app.
    private static func deactivateSessionIfIdle(releaseSpeakerOverride: Bool = false) {
        guard playingStreams == 0 else { return }
        let session = AVAudioSession.sharedInstance()
        let keepAlive = BackgroundKeepAlive.holdsAudioSession
        if hasSpeakerOverride {
            // A CarPlay audio format change tears down the old RTP stream. Keep the
            // output route through that replacement so iOS does not renegotiate again.
            guard releaseSpeakerOverride else { return }
            hasSpeakerOverride = false
            try? session.overrideOutputAudioPort(.none)
            try? session.setCategory(.playback, mode: .default, options: keepAlive ? [.mixWithOthers] : [])
        }
        guard !keepAlive else { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
    #endif
}

/// Converts one authenticated RTP payload to native Float32 PCM.
/// AAC payloads are raw access units, not ADTS containers.
final class NativeAudioDecoder {
    struct Attempt {
        let name: String
        let formatID: AudioFormatID
        let flags: UInt32
        let cookie: Data?
        let framesPerPacket: UInt32
    }
    let output: AVAudioFormat
    private let format: ReceiverAudioFormat
    private var converter: AVAudioConverter?
    private var compressed: AVAudioFormat?
    /// 车机端拿到的 AAC 既可能是 AAC-LC（1024 样点/帧），也可能是 CarPlay 常用的 AAC-ELD
    /// （512 样点/帧，格式 ID 是 'eld ' 而不是 'aac '）。之前一直在 LC 的格式 ID 上换 cookie，
    /// 这件事本身没有意义，所以永远只得到 paramErr(-50)。这里把格式 ID、flags、cookie 一起换着试。
    private var attempts: [Attempt] = []
    private var attemptIndex = 0
    private var loggedPreview = false
    var onLog: ((String) -> Void)?
    init(format: ReceiverAudioFormat) throws {
        self.format = format
        output = AVAudioFormat(standardFormatWithSampleRate: Double(format.sampleRate), channels: AVAudioChannelCount(format.channels))!
        if format.isAAC {
            let frequency: [UInt8] = format.sampleRate == 48000 ? [0x11, 0x90] : [0x12, 0x10]
            let elt: [UInt8] = format.sampleRate == 48000 ? [0x9C, 0x88] : [0x9D, 0x08]
            attempts = [
                Attempt(name: "AAC-LC 头部 2 字节", formatID: kAudioFormatMPEG4AAC, flags: 2, cookie: Data(frequency), framesPerPacket: 1024),
                Attempt(name: "AAC-ELD（'eld ' 格式）", formatID: kAudioFormatMPEG4AAC_ELD, flags: 0, cookie: Data(elt), framesPerPacket: 512),
                Attempt(name: "AAC-LC flags 0", formatID: kAudioFormatMPEG4AAC, flags: 0, cookie: Data(frequency), framesPerPacket: 1024),
                Attempt(name: "AAC-LC 无头部", formatID: kAudioFormatMPEG4AAC, flags: 2, cookie: nil, framesPerPacket: 1024),
                Attempt(name: "AAC-ELD 无头部", formatID: kAudioFormatMPEG4AAC_ELD, flags: 0, cookie: nil, framesPerPacket: 512),
            ]
        } else if format.isOpus {
            attempts = [Attempt(name: "Opus", formatID: kAudioFormatOpus, flags: 0, cookie: nil, framesPerPacket: UInt32(format.sampleRate / 50))]
        }
        if !attempts.isEmpty {
            do { try apply(attempts[0]) } catch { throw error }
        }
    }

    private func apply(_ attempt: Attempt) throws {
        var description = AudioStreamBasicDescription(mSampleRate: Double(format.sampleRate), mFormatID: attempt.formatID,
            mFormatFlags: attempt.flags, mBytesPerPacket: 0, mFramesPerPacket: attempt.framesPerPacket, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(format.channels), mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &description) else {
            throw ProtocolError.malformed("\(attempt.name) 输入格式不可用")
        }
        guard let codec = AVAudioConverter(from: input, to: output) else {
            throw ProtocolError.malformed("\(attempt.name) 解码器不可用")
        }
        if let cookie = attempt.cookie { codec.magicCookie = cookie }
        codec.primeMethod = .none
        compressed = input; converter = codec
    }

    /// 当前配置解不出来时换下一种（格式 ID / flags / cookie 一起换）。
    private func advance() -> Bool {
        guard attemptIndex + 1 < attempts.count else { return false }
        attemptIndex += 1
        let attempt = attempts[attemptIndex]
        do {
            try apply(attempt)
            onLog?("音频解码改用第 \(attemptIndex + 1) 种：\(attempt.name)")
            return true
        } catch {
            onLog?("音频解码第 \(attemptIndex + 1) 种（\(attempt.name)）不可用：\(error.localizedDescription)")
            return false
        }
    }

    func decode(_ payload: Data) throws -> AVAudioPCMBuffer? {
        guard !payload.isEmpty, payload.count <= 65507 else { throw ProtocolError.malformed("音频载荷大小") }
        while true {
            do {
                return try decodeOnce(payload)
            } catch {
                if !loggedPreview {
                    loggedPreview = true
                    let head = payload.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
                    onLog?("音频包头部 \(head)（\(payload.count) 字节）：\(error.localizedDescription)")
                }
                if advance() { continue }
                throw error
            }
        }
    }

    private func decodeOnce(_ payload: Data) throws -> AVAudioPCMBuffer? {
        if let converter, let compressed {
            let input = AVAudioCompressedBuffer(format: compressed, packetCapacity: 1, maximumPacketSize: payload.count)
            input.packetCount = 1; input.byteLength = UInt32(payload.count)
            payload.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: payload.count) }
            input.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0,
                mVariableFramesInPacket: format.isOpus ? 0 : (format.isAAC ? 0 : 1024), mDataByteSize: UInt32(payload.count))
            guard let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: format.isOpus ? AVAudioFrameCount(format.sampleRate * 120 / 1000) : 4096) else { throw ProtocolError.malformed("AAC 输出缓冲区") }
            var supplied = false, error: NSError?
            let status = converter.convert(to: pcm, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            if status == .error { throw error ?? NSError(domain: "TDSAudio", code: 1) }
            return pcm.frameLength > 0 ? pcm : nil
        }
        let frameBytes = format.channels * 2
        guard payload.count % frameBytes == 0 else { throw ProtocolError.malformed("PCM 帧大小") }
        let frames = payload.count / frameBytes
        guard frames <= format.sampleRate / 4,
              let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(frames)), let planes = buffer.floatChannelData else {
            throw ProtocolError.malformed("PCM 输出缓冲区")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        payload.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for frame in 0..<frames {
                for channel in 0..<format.channels {
                    let index = (frame * format.channels + channel) * 2
                    let sample = Int16(bitPattern: UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
                    planes[channel][frame] = Float(sample) / 32768
                }
            }
        }
        return buffer
    }
}

/// On-demand mono PCM/Opus capture for a negotiated voice uplink. All state is main-thread.
/// Music streams never request microphone permission or activate recording.
private final class NativeMicrophone {
    private let engine = AVAudioEngine()
    private let packetizer: MicrophonePacketizer
    private let connection: NWConnection
    private let rate: Int
    private let format: ReceiverAudioFormat
    private var opusEncoder: NativeOpusEncoder?
    private let slots = DispatchSemaphore(value: 4)
    private var converter: AVAudioConverter?
    private var active = true
    private var installedTap = false
    private var loggedWaitingForAudio = false
    private var pending = Data()
    private var failures = 0
    var onLog: ((String) -> Void)?
    init(secret: SymmetricKey, connectionID: UInt64, address: String, port: UInt16, format: ReceiverAudioFormat) {
        self.rate = format.sampleRate; self.format = format
        packetizer = MicrophonePacketizer(secret: secret, connectionID: connectionID)
        connection = NWConnection(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
    }
    func start() {
        guard active else { return }
        #if os(iOS)
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.active else { return }
                if granted { self.beginCapture() }
                else { self.onLog?("麦克风权限被拒绝，语音输入不可用") }
            }
        }
        #else
        onLog?("麦克风采集需要使用 iPhone/iPad 目标")
        #endif
    }
    private func beginCapture() {
        do {
            // 后台播音时系统常把会话留在 .playback（或带 .mixWithOthers），此时开录音必然
            // 报 cannotStartRecording（561145187）。录音前把会话摆回可录状态，并明确用内建麦克风。
            let session = AVAudioSession.sharedInstance()
            // 通话正在进行时：绝不改类别（改了会把通话顶断，真机已复现“双方没声音且自己中断”）。
            // 只有会话本来就已经是可录状态时才直接装 tap；否则等通话结束再来。
            if session.isOtherAudioPlaying, session.category != .playAndRecord {
                if !loggedWaitingForAudio {
                    loggedWaitingForAudio = true
                    onLog?("通话占用音频：先不动音频会话（避免顶断通话），通话结束后再开麦克风")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.active, !self.installedTap else { return }
                    self.beginCapture()
                }
                return
            }
            // 修复「对方听不到你」：通话中微信已经建立好可录会话，绝不改类别/激活，
            // 否则会把微信通话顶断（真机就是「双方没声音且自己中断」）。直接复用现有会话装 tap。
            if !session.isOtherAudioPlaying {
                if session.category != .playAndRecord || session.categoryOptions.contains(.mixWithOthers) {
                    try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
                }
                try session.setActive(true)
            }
            // 通话中不调 setPreferredInput：微信已经选好了输入，强改会打断它。
            if !session.isOtherAudioPlaying,
               let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtIn)
            }
            if format.isOpus { opusEncoder = try NativeOpusEncoder(rate: rate) }
            let input = engine.inputNode.outputFormat(forBus: 0)
            guard input.sampleRate > 0, input.channelCount > 0,
                  let output = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1),
                  let converter = AVAudioConverter(from: input, to: output) else { throw ProtocolError.malformed("麦克风格式") }
            self.converter = converter
            connection.start(queue: .main)
            let slots = self.slots
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: input) { [weak self] buffer, _ in
                guard slots.wait(timeout: .now()) == .success else { return }
                guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { slots.signal(); return }
                copy.frameLength = buffer.frameLength
                let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                for index in 0..<source.count {
                    if let src = source[index].mData, let dst = target[index].mData {
                        dst.copyMemory(from: src, byteCount: Int(source[index].mDataByteSize))
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    defer { slots.signal() }
                    guard let self, self.active else { return }
                    self.send(copy)
                }
            }
            installedTap = true
            try engine.start()
            onLog?("\(format.name) 麦克风已启动：\(rate) Hz 单声道（权限 \(Self.permissionText())）")
        } catch {
            if !loggedFailure {
                loggedFailure = true
                let session = AVAudioSession.sharedInstance()
                let inputs = session.availableInputs?.map { $0.portType.rawValue }.joined(separator: ",") ?? "无"
                onLog?("无法启动麦克风：\(error.localizedDescription)（类别 \(session.category.rawValue)，输入 \(inputs)，权限 \(Self.permissionText())）")
            }
            stop()
        }
    }
    private var loggedFailure = false
    static func permissionText() -> String {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return "已允许"
        case .denied: return "已拒绝（去 设置 > YCarWith 打开麦克风）"
        case .undetermined: return "未询问"
        @unknown default: return "未知"
        }
    }
    private func send(_ input: AVAudioPCMBuffer) {
        guard let converter else { return }
        do {
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * Double(rate) / input.format.sampleRate)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }
            var supplied = false, error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            if status == .error { throw error ?? NSError(domain: "TDSMicrophone", code: 1) }
            guard let samples = output.floatChannelData?[0] else { return }
            for index in 0..<Int(output.frameLength) {
                let scaled = samples[index].isFinite ? max(-32768, min(32767, samples[index] * 32768)) : 0
                let sample = UInt16(bitPattern: Int16(scaled))
                pending.append(UInt8(truncatingIfNeeded: sample >> 8)); pending.append(UInt8(truncatingIfNeeded: sample))
            }
            let frames = rate / 50, bytes = frames * 2
            while pending.count >= bytes {
                let pcm = Data(pending.prefix(bytes))
                pending.removeFirst(bytes)
                let payload: Data
                if let opusEncoder {
                    guard let encoded = try opusEncoder.encode(pcm) else { continue }
                    payload = encoded
                } else { payload = pcm }
                let wire = try packetizer.seal(payload, frames: UInt32(frames))
                connection.send(content: wire, completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.stop() }
                })
            }
        } catch {
            failures += 1
            if failures <= 3 { onLog?("麦克风转换失败：\(error.localizedDescription)") }
        }
    }
    func stop() {
        guard active else { return }; active = false
        if installedTap { engine.inputNode.removeTap(onBus: 0); installedTap = false }
        engine.stop(); connection.cancel(); converter = nil; pending.removeAll()
    }
}

/// One 20-ms mono voice packet. Uses Apple's codec, with no Ogg/container header.
final class NativeOpusEncoder {
    private let converter: AVAudioConverter
    private let pcm: AVAudioFormat
    private let compressed: AVAudioFormat
    private let frames: Int
    init(rate: Int) throws {
        frames = rate / 50
        pcm = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)!
        var description = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatOpus,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: UInt32(frames), mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let format = AVAudioFormat(streamDescription: &description),
              let codec = AVAudioConverter(from: pcm, to: format) else { throw ProtocolError.malformed("Opus 编码器不可用") }
        compressed = format; converter = codec
        converter.primeMethod = .none
        converter.bitRate = rate == 48000 ? 64000 : 32000
    }
    func encode(_ bigEndianPCM: Data) throws -> Data? {
        guard bigEndianPCM.count == frames * 2,
              let input = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(frames)) else {
            throw ProtocolError.malformed("Opus 麦克风帧大小")
        }
        input.frameLength = AVAudioFrameCount(frames)
        bigEndianPCM.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in 0..<frames {
                input.floatChannelData![0][index] = Float(Int16(bitPattern: UInt16(bytes[index * 2]) << 8 | UInt16(bytes[index * 2 + 1]))) / 32768
            }
        }
        let packet = AVAudioCompressedBuffer(format: compressed, packetCapacity: 1, maximumPacketSize: 4096)
        var supplied = false, error: NSError?
        let status = converter.convert(to: packet, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if status == .error { throw error ?? NSError(domain: "TDSOpus", code: 1) }
        guard packet.packetCount > 0, packet.byteLength > 0 else { return nil }
        return Data(bytes: packet.data, count: Int(packet.byteLength))
    }
}
