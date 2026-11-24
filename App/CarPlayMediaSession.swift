// SPDX-License-Identifier: GPL-3.0-or-later
// Native event/video session adapted from PlayPort's AirPlaySession and media engine.
import Foundation
import CryptoKit
import AVFoundation

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
    private let audioEnabled: Bool
    private let hevc: Bool
    private var eventCipher: ControlCipher?
    private var eventParser = RTSPParser(allowResponses: true)
    private var screen: ScreenStream?
    private var cseq = 0
    private var videoPackets = 0
    var onLog: ((String) -> Void)?
    var onBrowserAudio: ((Int, AVAudioPCMBuffer, UInt64) -> Void)?
    /// 每一路音频（含通话）解码后的 PCM，用来喂 CarLife 车机端的伴音通道。
    var onAudioPCM: ((Int, AVAudioPCMBuffer) -> Void)?
    /// 车机页面上有没有人在要声音；没人要时音频留给本机播放（CarLife 模式就是这种情况）。
    var browserAudioWanted: (() -> Bool)?
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
                onLog?("已请求媒体流 \(type)，音频格式 \((stream["audioFormat"] as? NSNumber)?.stringValue ?? "无")")
                if [100, 101, 102].contains(type.intValue), audioEnabled {
                    guard eventListener != nil, let connectionID = stream["streamConnectionID"] as? NSNumber,
                          let bits = stream["audioFormat"] as? NSNumber else { throw ProtocolError.malformed("音频 SETUP 字段") }
                    let format = try ReceiverAudioFormat(bits: bits.uint64Value)
                    let audioType = (stream["audioType"] as? String ?? "").lowercased()
                    let requestsMicrophone = type.intValue == 100 && ["telephony", "speechrecognition", "default"].contains(audioType)
                        && ((stream["input"] as? Bool) == true || (stream["dataPort"] as? NSNumber)?.intValue ?? 0 > 0)
                    let microphonePort = requestsMicrophone ? (stream["dataPort"] as? NSNumber).flatMap { UInt16(exactly: $0.intValue) }.flatMap { $0 > 0 ? $0 : nil } : nil
                    audio.removeValue(forKey: type.intValue)?.stop()
                    let output = try CarPlayAudio(secret: secret, peerAddress: peerAddress,
                        connectionID: connectionID.uint64Value, format: format, microphonePort: microphonePort)
                    output.onLog = { [weak self] in self?.onLog?($0) }
                    output.shouldForwardAudio = { [weak self] in self?.browserAudioWanted?() ?? true }
                    let streamType = type.intValue
                    output.onPCM = { [weak self] buffer in self?.onAudioPCM?(streamType, buffer) }
                    // 修复：微信/电话的通话音频（stream 100 / telephony）原来被这里排除，
                    // 导致网页版和车机浏览器永远收不到通话声音（"双方听不到"）。
                    // 现在所有音频流——包括音乐、通话、Siri——解码后一律转发给网页/车机浏览器，
                    // 由 shouldForwardAudio（页面是否要点声音）决定本机是否让位，不再按 audioType 一刀切。
                    if let onBrowserAudio {
                        output.onBrowserAudio = { buffer, stamp in onBrowserAudio(streamType, buffer, stamp) }
                    }
                    audio[type.intValue] = output
                    replies.append(["type": type, "dataPort": output.dataPort, "controlPort": output.controlPort,
                                    "streamConnectionID": connectionID])
                    onLog?("音频流 \(type) 已就绪：\(format.name) \(format.sampleRate) Hz / \(format.channels) 声道")
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
    /// Momentary HID key: the press report followed by the all-released report.
    func pressHID(_ uuid: String, _ report: Data, release: Data) {
        guard sendHID(uuid, report, label: "按键") else { onLog?("按键未发送：事件通道尚未连接"); return }
        _ = sendHID(uuid, release, label: "按键")
    }
    func requestSiri() {
        guard sendCommand(["type": "requestSiri", "params": ["siriAction": 2]], label: "Siri") else {
            onLog?("Siri 未发送：事件通道尚未连接"); return
        }
        _ = sendCommand(["type": "requestSiri", "params": ["siriAction": 3]], label: "Siri")
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
