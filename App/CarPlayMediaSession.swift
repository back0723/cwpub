// SPDX-License-Identifier: GPL-3.0-or-later
// Native event/video session adapted from PlayPort's AirPlaySession and media engine.
import Foundation
import CryptoKit
import AVFoundation

/// 车机端迷行 4.1.3 把音频分成两套完全独立的系统（smali 反编译实锤）：
/// · 音乐模块 La/a/b/p/a;，网络通道 3，命令 0x30001 init / 0x30003 pause / 0x30004 play / 0x30006 data
/// · 导航 TTS 模块 La/a/b/p/b;，网络通道 4，命令 0x40001 init / 0x40002 stop / 0x40003 data
/// 两者各有自己的 AudioTrack 与 AudioFocus。以前把音乐、导航、通话全塞进通道 3，
/// 导致导航播报被当成音乐、44100/48000 交替重建同一个 AudioTrack —— 冲突、卡顿、丢声。
enum CarLifeAudioRoute: String {
    case music       // 音乐：通道 3
    case navigation  // 导航播报/系统提示音：通道 4（TTS）
    case voice       // 电话/微信语音：对方声音送车机通道3（音乐/导航暂停），你的声音由麦克风上行回 iPhone

    /// 以 CarPlay 给出的 audioType 为准，stream type 作辅助。
    /// 102(media) 一定是音乐；telephony/speechRecognition 一定是通话；
    /// alert/navigation 是导航播报；其余(default/101) 保守当音乐，保证一定有声音。
    static func classify(streamType: Int, audioType: String) -> CarLifeAudioRoute {
        let kind = audioType.lowercased()
        // 电话 / 语音识别 → 归为 .voice：对方声音送车机通道3、你的声音由麦克风上行回 iPhone。
        if ["telephony", "speechrecognition"].contains(kind) { return .voice }
        if streamType == 100 { return .voice }
        // 导航播报 / 系统提示 / 语音助手 → 车机独立 TTS 通道 4。
        // 【音乐+导航双双无声根因】CarPlay 的 stream 101（Opus 48000Hz 单声道，audioType=default）
        // 就是导航/Siri 语音。旧逻辑把它当音乐塞进通道 3，和音乐 stream 102（AAC 44100Hz 双声道）
        // 交替触发 audio() 里的 init —— 每秒十几次重建同一个 AudioTrack，最终彻底卡死无声。
        // 按 CarPlay 规范：100=电话、101=语音/导航、102=媒体音乐，物理分开到车机两个播放器。
        if ["alert", "navigation", "navi", "tts", "speech", "assistant", "default"].contains(kind) { return .navigation }
        if streamType == 101 { return .navigation }
        // 媒体音乐 → 通道 3。
        if streamType == 102 || kind == "media" { return .music }
        return .music
    }
}

/// 一路解码后的音频帧及其去向。onAudioPCM 用它把音乐/导航/通话分到车机不同通道。
struct CarLifeAudioFrame {
    let buffer: AVAudioPCMBuffer
    let streamType: Int
    let audioType: String
    let route: CarLifeAudioRoute
}

final class CarPlayMediaSession {
    private let queue: DispatchQueue
    private let secret: SymmetricKey
    private let peerAddress: String
    private var eventListener: MediaTCPListener?
    private var videoListener: MediaTCPListener?
    private var event: MediaTCPConnection?
    private var video: MediaTCPConnection?
    private var timing: MediaTiming?
    private var audio: [Int: CarPlayAudio] = [:]
    /// 车机麦 PCM（CarLife 通道 5 / id 0x58001）→ 当前通话流的上行编码链路。
    /// 只有 voice 流对应的 CarPlayAudio 会持有 NativeMicrophone，音乐流拿到会自己忽略。
    func feedVehicleMicrophone(_ pcm: Data) {
        for output in audio.values { output.feedVehicleMicrophone(pcm) }
    }
    private let audioEnabled: Bool
    private let hevc: Bool
    private var eventCipher: ControlCipher?
    private var eventParser = RTSPParser(allowResponses: true)
    private var screen: ScreenStream?
    private var cseq = 0
    private var videoPackets = 0
    var onLog: ((String) -> Void)?
    var onBrowserAudio: ((Int, AVAudioPCMBuffer, UInt64) -> Void)?
    /// 每一路解码后的 PCM 及其分类，用来喂 CarLife 车机端的音乐/导航/通话通道。
    var onAudioPCM: ((CarLifeAudioFrame) -> Void)?
    /// 车机页面上有没有人在要声音；没人要时音频留给本机播放（CarLife 模式就是这种情况）。
    var browserAudioWanted: (() -> Bool)?
    /// 是否允许本机播放（「由 iPhone 输出」）。为 false 时，未转发到接收端就保持静默。
    var localAudioWanted: (() -> Bool)?
    var onVideo: ((Data, VideoCodec) -> Void)?
    init(queue: DispatchQueue, secret: SymmetricKey, peerAddress: String, audioEnabled: Bool, hevc: Bool) {
        self.queue = queue; self.secret = secret; self.peerAddress = peerAddress
        self.audioEnabled = audioEnabled; self.hevc = hevc
    }
    func setup(_ data: Data) throws -> Data {
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ProtocolError.malformed("SETUP 属性列表")
        }
        onLog?("SETUP 字段：\(values.keys.sorted().joined(separator: ", "))")
        onLog?("SETUP 详情：" + values.keys.sorted().map { key -> String in
            let value = values[key]
            if let text = value as? String { return "\(key)=\(text)" }
            if let number = value as? NSNumber { return "\(key)=\(number)" }
            if let list = value as? [String] { return "\(key)=[\(list.joined(separator: ","))]" }
            if let list = value as? [Any] { return "\(key)=\(list.count) 项" }
            return "\(key)=?"
        }.joined(separator: "；"))
        var response: [String: Any] = [:]
        if let streams = values["streams"] as? [[String: Any]] {
            var replies: [[String: Any]] = []
            for stream in streams {
                guard let type = stream["type"] as? NSNumber else { throw ProtocolError.malformed("媒体流类型") }
                // 诊断：把这一路流的全部键打印出来，确认 iPhone 有没有给上行端口、input 标志是否出现。
                let detail = stream.keys.sorted().map { key -> String in
                    let value = stream[key]
                    if let text = value as? String { return "\(key)=\(text)" }
                    if let number = value as? NSNumber { return "\(key)=\(number)" }
                    if let list = value as? [Any] { return "\(key)=[\(list.count) 项]" }
                    return "\(key)=?"
                }.joined(separator: "；")
                onLog?("媒体流明细：\(detail)")
                onLog?("已请求媒体流 \(type)，音频格式 \((stream["audioFormat"] as? NSNumber)?.stringValue ?? "无")")
                if [100, 101, 102].contains(type.intValue), audioEnabled {
                    guard eventListener != nil, let connectionID = stream["streamConnectionID"] as? NSNumber,
                          let bits = stream["audioFormat"] as? NSNumber else { throw ProtocolError.malformed("音频 SETUP 字段") }
                    let format = try ReceiverAudioFormat(bits: bits.uint64Value)
                    let audioType = (stream["audioType"] as? String ?? "").lowercased()
                    let streamType = type.intValue
                    let route = CarLifeAudioRoute.classify(streamType: streamType, audioType: audioType)
                    CarPlayMediaSession.recordAudioSetup(type: streamType, audioType: audioType)
                    // 【上行端口】iPhone 在 SETUP 里给「要上行」的流都带 dataPort + input=1：
                    // telephony dataPort=59913、speechrecognition dataPort=49929（1.2 实据）。
                    // 这个端口就是 iPhone 监听的输入口，把采集到的声音经 DataStream-Input 加密后发过去，
                    // 对方才听得到。
                    // 【1.5 实测教训】这台 iPhone 通话时可能只建 speechRecognition 一路（对方声音也走
                    // 这一路，Opus 24k），压根不建 telephony；1.3/1.4 只认 telephony → 日志里永远
                    // 「上行端口：无」，通话上行自然一条都没有。现在两路都收，telephony 优先。
                    var microphonePort: UInt16?
                    let hasInput = (stream["input"] as? NSNumber).map { $0.intValue != 0 } ?? false
                    let rawPort = (stream["dataPort"] as? NSNumber)?.uint16Value ?? 0
                    if route == .voice, hasInput, rawPort > 0, CarPlayAudio.capturesMicrophone,
                       ["telephony", "speechrecognition"].contains(audioType) {
                        microphonePort = rawPort
                    }
                    if let port = microphonePort {
                        onLog?("上行端口：\(port)（iPhone 输入口，audioType=\(audioType)）")
                    } else {
                        onLog?("上行端口：无（audioType=\(audioType)，input=\(hasInput ? 1 : 0)，dataPort=\(rawPort)）")
                    }
                    audio.removeValue(forKey: streamType)?.stop()
                    // 通话流（telephony / speechrecognition）标记 isVoice：CarPlayAudio 据此在本机绝不抢
                    // AVAudioSession 路由（抢了会顶断通话）；对方声音走车机通道3、你的声音由麦克风上行。
                    let isVoice = route == .voice
                    let output = try CarPlayAudio(secret: secret, peerAddress: peerAddress,
                        connectionID: connectionID.uint64Value, format: format, microphonePort: microphonePort,
                        isVoice: isVoice, isNavigation: route == .navigation)
                    output.onLog = { [weak self] in self?.onLog?($0) }
                    // 所有流（含通话）统一遵循 browserAudioWanted：
                    // · CarLife 模式恒 true → 走 onBrowserAudio 转发后直接 return，不落本机
                    //   AVAudioEngine 播放分支。那个分支在 CarAudio 路由下会 setCategory(.playAndRecord)
                    //   + overrideOutputAudioPort(.speaker)，正是顶断微信、双方听不到的元凶。
                    // · 通话对方声音已由 onAudioPCM → 车机通道3 播出（音乐/导航此刻暂停独占）。
                    // · 本方案上行交给 iPhone 系统通话：车机不采麦，无需再启动上行麦克风。
                    output.shouldForwardAudio = { [weak self] in self?.browserAudioWanted?() ?? true }
                    output.shouldPlayLocally = { [weak self] in self?.localAudioWanted?() ?? true }
                    // 导航/通话只交给车机对应通道，本机 AVAudioEngine 不再重复播放，避免车机与手机双份声音。
                    output.onPCM = { [weak self] buffer in
                        let frame = CarLifeAudioFrame(buffer: buffer, streamType: streamType, audioType: audioType, route: route)
                        self?.onAudioPCM?(frame)
                    }
                    // 网页/车机浏览器：通话流也转发，由 shouldForwardAudio 决定本机是否让位。
                    if let onBrowserAudio {
                        output.onBrowserAudio = { buffer, stamp in onBrowserAudio(streamType, buffer, stamp) }
                    }
                    audio[streamType] = output
                    replies.append(["type": type, "dataPort": output.dataPort, "controlPort": output.controlPort,
                                    "streamConnectionID": connectionID])
                    let routeText: String
                    switch route {
                    case .music: routeText = "音乐→车机通道3"
                    case .navigation: routeText = "导航→车机通道4(TTS)"
                    case .voice: routeText = "通话→对方声音送车机通道3(音乐/导航暂停)"
                    }
                    onLog?("音频流 \(type) 已就绪：\(format.name) \(format.sampleRate) Hz / \(format.channels) 声道，audioType=\(audioType.isEmpty ? "无" : audioType)，\(routeText)")
                    continue
                }
                guard type.intValue == 110, let connectionID = stream["streamConnectionID"] as? NSNumber else {
                    throw ProtocolError.malformed("不支持的媒体流类型 \(type)")
                }
                guard eventListener != nil else { throw ProtocolError.malformed("初始 SETUP 前请求了屏幕流") }
                video?.stop(); video = nil; videoListener?.stop()
                screen = ScreenStream(secret: secret, connectionID: connectionID.uint64Value)
                videoPackets = 0
                let listener = try MediaTCPListener(queue: queue, peerAddress: peerAddress); videoListener = listener
                listener.onConnection = { [weak self] connection in
                    guard let self, self.video == nil else { connection.stop(); return }
                    self.video = connection; self.onLog?("视频 TCP 通道已连接")
                    self.flushNightMode()
                    connection.onBytes = { [weak self] bytes in
                        guard let self, let screen = self.screen else { return }
                        do {
                            for unit in try screen.append(bytes) {
                                self.videoPackets += 1
                                if self.videoPackets <= 2 {
                                    self.onLog?("已解码 \(screen.codec.displayName) 访问单元 \(self.videoPackets)（\(unit.count) 字节）")
                                }
                                self.onVideo?(unit, screen.codec)
                            }
                        } catch { self.onLog?("视频数据被拒绝：\(error)"); throw error }
                    }
                    connection.onClose = { [weak self] in self?.video = nil; self?.onLog?("视频通道已关闭") }
                    connection.start()
                }
                replies.append(["type": 110, "dataPort": listener.port])
                onLog?("视频监听器已在端口 \(listener.port) 就绪")
            }
            response["streams"] = replies
        } else {
            // iOS 16 sends the event/timing SETUP first and only asks for the screen stream (type
            // 110) once the features it proposed are enabled. "mainBuffered" is the switch that
            // makes the phone deliver the main screen stream at all; without it the phone simply
            // records the session and never sends video (the classic "waiting for a keyframe").
            let replyFeatures = enabledFeatures(proposed: values["features"] as? [String])
            onLog?("回复的会话功能：\(replyFeatures.joined(separator: ", "))")
            if let listener = eventListener, let timing = self.timing {
                // The phone may repeat this SETUP after a reconnect; answer with the same ports.
                onLog?("重复的初始 SETUP，沿用事件/时钟端口 \(listener.port)/\(timing.port)")
                response = ["eventPort": listener.port, "timingPort": timing.port, "enabledFeatures": replyFeatures]
                return try PropertyListSerialization.data(fromPropertyList: response, format: .binary, options: 0)
            }
            let timingPort = (values["timingPort"] as? NSNumber)?.intValue ?? 0
            guard (0...65535).contains(timingPort) else { throw ProtocolError.malformed("时钟同步端口") }
            timing = try MediaTiming(queue: queue, peerAddress: peerAddress, peerPort: UInt16(timingPort))
            let listener = try MediaTCPListener(queue: queue, peerAddress: peerAddress); eventListener = listener
            listener.onConnection = { [weak self] connection in self?.acceptEvent(connection) }
            if let proposed = values["features"] as? [String] {
                onLog?("iPhone 提议的会话功能：\(proposed.joined(separator: ", "))")
            }
            response = ["eventPort": listener.port, "timingPort": timing!.port, "enabledFeatures": replyFeatures]
            onLog?("事件/时钟同步监听器已就绪：\(listener.port)/\(timing!.port)")
        }
        return try PropertyListSerialization.data(fromPropertyList: response, format: .binary, options: 0)
    }

    /// Features the accessory enables. 能出画面的 CarMode 只认 `viewAreas`；额外回
    /// `mainBuffered` 反而让 iOS 16 在 RECORD 后直接断开，连 streams SETUP 都不发。
    private func enabledFeatures(proposed: [String]?) -> [String] {
        _ = proposed
        return hevc ? ["viewAreas", "hevc"] : ["viewAreas"]
    }
    private func acceptEvent(_ connection: MediaTCPConnection) {
        guard event == nil else { connection.stop(); return }
        event = connection
        eventCipher = ControlCipher(readKey: PairVerify.derive(secret, salt: "Events-Salt", info: "Events-Read-Encryption-Key"),
            writeKey: PairVerify.derive(secret, salt: "Events-Salt", info: "Events-Write-Encryption-Key"))
        onLog?("加密事件通道已连接")
        connection.onBytes = { [weak self, weak connection] bytes in
            guard let self, let connection, let cipher = self.eventCipher else { return }
            for request in try self.eventParser.append(cipher.receive(bytes)) {
                if request.method.hasPrefix("RTSP/") || request.method.hasPrefix("HTTP/") {
                    // Answer to one of our commands; only failures are worth a log line.
                    if request.target != "200" { self.onLog?("iPhone 拒绝了事件命令（状态 \(request.target)，CSeq \(request.headers["cseq"] ?? "?")）") }
                    continue
                }
                try connection.send(cipher.encrypt(RTSPResponse().encoded(for: request)))
            }
        }
        connection.onClose = { [weak self] in self?.event = nil; self?.eventCipher = nil; self?.onLog?("事件通道已关闭") }
        connection.start()
        // 这里不能立刻发 setNightMode：iOS 16 在视频流起来之前会用 408 拒掉，几秒后把整条控制
        // 连接 TEARDOWN 掉，于是永远等不到 streams SETUP。CarMode 全程不发命令正是这个原因。
    }
    var hasEventChannel: Bool { event != nil && eventCipher != nil }
    /// Full multitouch state: every slot is reported each time; missing slots report up.
    func touch(_ contacts: [CarPlayInfo.TouchContact]) {
        _ = sendHID(CarPlayInfo.HID.touch, CarPlayInfo.touchReport(contacts), label: "触控")
    }
    /// 已建立的音频流记录（type/audioType），用于启动自检与日志对照。
    private static let setupLock = NSLock()
    private static var setupStore: [String] = []
    static var audioSetups: [String] {
        setupLock.lock(); defer { setupLock.unlock() }
        return setupStore
    }
    static func recordAudioSetup(type: Int, audioType: String) {
        setupLock.lock()
        setupStore.append("\(type)/\(audioType.isEmpty ? "-" : audioType)")
        setupLock.unlock()
    }
    /// Momentary HID key: the press report followed by the all-released report.
    func pressHID(_ uuid: String, _ report: Data, release: Data) {
        guard sendHID(uuid, report, label: "按键") else { onLog?("按键未发送：事件通道尚未连接"); return }
        _ = sendHID(uuid, release, label: "按键")
    }
    func requestSiri() {
        // CarPlay 彻底不使用 Siri：不再向 iPhone 发 requestSiri，避免拉起语音识别流、抢音频会话。
        onLog?("已忽略 Siri 请求（CarPlay 不启用 Siri）")
    }
    /// Latest wanted day/night state; kept until the event channel can carry it.
    private var pendingNightMode: Bool?
    func setNightMode(_ night: Bool) {
        pendingNightMode = night
        flushNightMode()
    }
    private func flushNightMode() {
        guard let night = pendingNightMode, hasEventChannel else { return }
        // 视频流没起来之前发命令会被 408 拒掉并连带 TEARDOWN，所以等画面通道就绪再发。
        guard video != nil else {
            if !deferredNightModeLogged {
                deferredNightModeLogged = true
                onLog?("外观命令暂缓：等视频流就绪后再通知 iPhone")
            }
            return
        }
        if sendCommand(["type": "setNightMode", "params": ["nightMode": night]], label: "夜间模式") {
            pendingNightMode = nil
            deferredNightModeLogged = false
            onLog?("已通知 iPhone 切换为\(night ? "夜间" : "白天")外观")
        }
    }
    private var deferredNightModeLogged = false
    private func sendHID(_ uuid: String, _ report: Data, label: String) -> Bool {
        sendCommand(["type": "hidSendReport", "uuid": uuid, "hidReport": report], label: label)
    }
    /// Asks the iPhone to encode an IDR/IRAP picture now. CarPlay only sends one keyframe at stream
    /// start, so every decoder recovery and every late browser viewer depends on this command.
    func requestKeyFrame() -> Bool { sendCommand(["type": "forceKeyFrame"], label: "关键帧请求") }
    /// Car-initiated command on the encrypted event channel (same framing as HID reports).
    private func sendCommand(_ command: [String: Any], label: String) -> Bool {
        guard let event, let eventCipher else { return false }
        do {
            let body = try PropertyListSerialization.data(fromPropertyList: command, format: .binary, options: 0)
            cseq += 1
            let header = "POST /command RTSP/1.0\r\nContent-Type: application/x-apple-binary-plist\r\nContent-Length: \(body.count)\r\nCSeq: \(cseq)\r\n\r\n"
            try event.send(eventCipher.encrypt(Data(header.utf8) + body))
            return true
        } catch { onLog?("\(label)写入失败：\(error)"); event.stop(); return false }
    }
    func stop() {
        audio.values.forEach { $0.stop() }; audio.removeAll()
        CarPlayAudio.endMediaSession()
        eventListener?.stop(); videoListener?.stop(); event?.stop(); video?.stop(); timing?.stop()
        eventListener = nil; videoListener = nil; event = nil; video = nil; timing = nil; screen = nil; eventCipher = nil
    }
    func feedback() throws -> Data? {
        guard !audio.isEmpty, let timing else { return nil }
        let streams = audio.map { $0.value.feedback(type: $0.key, ntp: timing.timestamp()) }
        return try PropertyListSerialization.data(fromPropertyList: ["streams": streams], format: .binary, options: 0)
    }
    /// A stream-specific teardown must not terminate the other live streams.
    func teardown(_ body: Data) throws -> Bool {
        guard !body.isEmpty, let values = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any],
              let streams = values["streams"] as? [[String: Any]] else { stop(); return true }
        for stream in streams {
            guard let type = stream["type"] as? NSNumber else { continue }
            if type.intValue == 110 { video?.stop(); video = nil; videoListener?.stop(); videoListener = nil; screen = nil }
            audio.removeValue(forKey: type.intValue)?.stop()
        }
        return false
    }
    deinit { stop() }
}
