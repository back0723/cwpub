// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
// Swift port of OpenXPlay-Stream kotlin/carlife (CarlifeFraming, Proto, CarlifeCrypto, CarlifeInput,
// CarlifeSession, CarlifeOutput, ReceiverProfile). Experimental; see THIRD_PARTY_NOTICES.txt.
import Foundation
import Network
import CryptoKit
import CommonCrypto
import Security
import Darwin
import AVFoundation

/// Sends the CarPlay picture to a head unit's CarLife app and takes its touches and keys back.
///
/// Wire roles follow the OpenXPlay relay: CarWithin listens on seven TCP ports (one per CarLife
/// channel), announces itself with a one-byte UDP datagram to port 7999, and the head unit
/// connects in. Video is H.264 Annex-B on channel 2. CarLife carries no audio: sound stays on the
/// iPhone and reaches the car over its Bluetooth link.
final class CarLifeOutput {
    static let ports: [UInt16] = [7240, 8240, 9240, 9241, 9242, 9340, 9440]
    static let discoveryPort: UInt16 = 7999

    private let queue = DispatchQueue(label: "CarWithin.carlife", qos: .userInitiated)
    private var listeners: [NWListener] = []
    private var session: Session?
    private var generation = UUID()
    private var running = false
    private var targetAddress: String?
    private var videoWidth = 1280, videoHeight = 720, maxFPS = 30
    private var parameters = VideoParameterSets(codec: .h264)
    private var warnedCodec = false
    private var discoverySocket: Int32 = -1
    private var discoveryErrorLogged = false
    private var audioReceived = 0
    private var navAudioReceived = 0
    private var timer: DispatchSourceTimer?

    var onLog: ((String) -> Void)?
    var onState: ((String) -> Void)?
    /// Every finger the head unit holds, normalized 0…1; an empty list releases them.
    var onTouches: (([TouchPoint]) -> Void)?
    var onControl: ((CarPlayControl) -> Void)?
    var onKeyframeRequest: ((String) -> Void)?
    /// The head unit just asked for a picture. The owner may hand over a cached IDR so the
    /// receiver does not have to wait for a brand-new keyframe (iOS 16 rejects forceKeyFrame).
    var onStartFrameNeeded: (() -> Void)?

    func start(targetAddress: String?, width: Int, height: Int, fps: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOnQueue()
            self.running = true
            self.targetAddress = targetAddress.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            self.videoWidth = width; self.videoHeight = height; self.maxFPS = max(1, min(60, fps))
            let run = self.generation
            for (index, port) in Self.ports.enumerated() { self.listen(port: port, channel: index + 1, run: run) }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.2, repeating: 1)
            var ticks = 0
            timer.setEventHandler { [weak self] in
                guard let self, self.generation == run else { return }
                self.session?.tick()
                self.checkSession()
                // Announce every 2 s until a head unit has authenticated.
                if ticks % 2 == 0, self.session?.authenticated != true { self.discover() }
                ticks += 1
            }
            timer.resume(); self.timer = timer
            self.state("CarLife：正在等待车机连接（端口 \(Self.ports[0])）")
        }
    }

    func append(_ accessUnit: Data, codec: VideoCodec) {
        queue.async { [weak self] in self?.appendOnQueue(accessUnit, codec: codec) }
    }

    /// 把 CarPlay 解码出来的 PCM 交给车机端的伴音通道（CarLife 音乐模块，通道 3）。
    /// 第一包一定打一条日志，用来区分“音频根本没进来”和“进来了但通道没建”。
    func appendAudio(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self else { return }
            self.audioReceived += 1
            if self.audioReceived == 1 {
                self.log("CarLife 伴音：收到第一路音频 \(Int(buffer.format.sampleRate.rounded())) Hz / \(buffer.format.channelCount) 声道")
            }
            self.session?.audio(buffer)
        }
    }

    /// 有电话/微信语音时通知车机暂音乐道 3 与导航通道 4，通话结束后自动恢复，
    /// 避免通话期间车机还在播音乐/导航 ——「打电话时不要有其它音频」。
    func setCallActive(_ active: Bool) {
        queue.async { [weak self] in self?.session?.setCallActive(active) }
    }

    /// 通话期间把对方声音送进车机通道 3（此刻音乐已被 setCallActive 暂停，通道独占）。
    /// iPhone 已把通话音频路由给 CarPlay，本机听筒不响，必须由 YCarWith 播出来，
    /// 否则就会出现「通话时听不到对方」。音乐/导航仍被暂停，通话里不会混入其它音频。
    func appendVoiceAudio(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self else { return }
            self.session?.voiceAudio(buffer)
        }
    }

    /// 导航播报走车机独立的 TTS 通道 4（命令 0x40001/0x40003），不再混进音乐通道 3。
    func appendNavigationAudio(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.navAudioReceived == 0 {
                self.log("CarLife 导航：收到导航播报音频 \(Int(buffer.format.sampleRate.rounded())) Hz / \(buffer.format.channelCount) 声道")
            }
            self.navAudioReceived += 1
            self.session?.navigationAudio(buffer)
        }
    }

    func stop() { queue.async { [weak self] in self?.stopOnQueue() } }

    // MARK: Listeners

    private func listen(port: UInt16, channel: Int, run: UUID) {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true; tcp.enableKeepalive = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        guard let endpointPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: parameters, on: endpointPort) else {
            log("CarLife 端口 \(port) 无法监听"); return
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == run else { return }
            if case .failed(let error) = state { self.log("CarLife 端口 \(port) 监听失败：\(error.localizedDescription)") }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.generation == run else { connection.cancel(); return }
            self.accept(connection, channel: channel)
        }
        listener.start(queue: queue)
        listeners.append(listener)
    }

    private func accept(_ connection: NWConnection, channel: Int) {
        let peer: String
        if case .hostPort(let host, _) = connection.endpoint { peer = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)" }
        else { peer = "车机" }
        if let existing = session, existing.peer != peer {
            // One head unit at a time.
            connection.cancel(); return
        }
        let link = Link(connection: connection, channel: channel)
        if session == nil || (channel == 1 && session?.ownsChannel(1) == true) {
            // A new control socket always starts a new authenticated lifetime.
            session?.close(reason: "控制连接被替换")
            parameters = VideoParameterSets(codec: .h264)
            session = makeSession(peer: peer)
        }
        guard let session else { connection.cancel(); return }
        session.attach(link)
        connection.stateUpdateHandler = { [weak self, weak session, weak link] state in
            guard let self, let session, let link else { return }
            switch state {
            case .ready: self.receive(link, session: session)
            case .failed, .cancelled: self.ended(session, link: link, reason: "连接已断开")
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func makeSession(peer: String) -> Session {
        let session = Session(peer: peer, width: videoWidth, height: videoHeight, maxFPS: maxFPS)
        session.log = { [weak self] in self?.log("CarLife \($0)") }
        session.onState = { [weak self] in self?.state($0) }
        session.onTouches = { [weak self] in self?.onTouches?($0) }
        session.onControl = { [weak self] in self?.onControl?($0) }
        session.onKeyframeRequest = { [weak self] in self?.onKeyframeRequest?("CarLife：\($0)") }
        session.onStartFrameNeeded = { [weak self] in self?.onStartFrameNeeded?() }
        return session
    }

    private func receive(_ link: Link, session: Session) {
        link.connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self, weak session, weak link] data, _, complete, error in
            guard let self, let session, let link, self.session === session, session.owns(link) else { return }
            if let data { link.buffer.append(data) }
            do {
                while let message = try CarLifeFraming.take(from: &link.buffer, channel: link.channel) {
                    try session.receive(message)
                    guard self.session === session else { return }
                }
            } catch {
                session.close(reason: "协议错误：\(error.localizedDescription)")
                self.ended(session, link: link, reason: nil); return
            }
            if complete || error != nil { self.ended(session, link: link, reason: "车机关闭了连接"); return }
            self.receive(link, session: session)
        }
    }

    private func ended(_ session: Session, link: Link, reason: String?) {
        link.connection.cancel()
        guard self.session === session, session.owns(link) || !session.active else { return }
        session.close(reason: reason ?? "会话结束")
        self.session = nil
        parameters = VideoParameterSets(codec: .h264)
        if running { state("CarLife：已断开，正在等待车机重新连接") }
    }

    private func checkSession() {
        guard let session, let failure = session.transportFailure() else { return }
        session.close(reason: failure)
        self.session = nil
        state("CarLife：\(failure)，正在等待车机重新连接")
    }

    // MARK: Video

    /// 把“关键帧开头、一直到当前”的缓存段整段补给车机，让它的解码器有完整依赖链。
    /// 回放期间不按积压跳过帧，否则序列会断在中途。
    func replay(_ accessUnits: [Data], codec: VideoCodec, parameterSets: [Data]) {
        queue.async { [weak self] in
            guard let self, let session = self.session else { return }
            for set in parameterSets { _ = self.parameters.absorb(set) }
            session.replaying = true
            for unit in accessUnits { self.appendOnQueue(unit, codec: codec) }
            session.replaying = false
        }
    }

    private func appendOnQueue(_ accessUnit: Data, codec: VideoCodec) {
        guard running else { return }
        guard codec == .h264 else {
            if !warnedCodec { warnedCodec = true; log("CarLife 只支持 H.264，当前 CarPlay 输出 \(codec.displayName)，已忽略画面") }
            return
        }
        guard let units = try? AnnexB.units(in: accessUnit) else { return }
        var picture: [Data] = []
        var keyframe = false
        for unit in units {
            if codec.parameterSet(unit) != nil { _ = parameters.absorb(unit); continue }
            if codec.isRandomAccess(unit) { keyframe = true }
            picture.append(unit)
        }
        guard !picture.isEmpty, let session, parameters.isComplete else { return }
        session.video(picture: picture, keyframe: keyframe, parameterSets: parameters.ordered)
    }

    // MARK: Discovery

    /// One byte to UDP 7999 makes a listening head unit connect back. Broadcast needs the multicast
    /// entitlement on iOS, which a development build may lack, so the local subnet is also swept by
    /// unicast (at most 254 tiny datagrams every 2 s).
    private func discover() {
        if discoverySocket < 0 {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            discoverySocket = fd
        }
        var targets: [String] = []
        if let targetAddress { targets = [targetAddress] }
        else {
            targets.append("255.255.255.255")
            for network in Self.localNetworks() {
                targets.append(network.broadcast)
                targets.append(contentsOf: network.hosts)
            }
        }
        var failures = 0, lastError: Int32 = 0
        for target in targets {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            address.sin_port = Self.discoveryPort.bigEndian
            guard inet_pton(AF_INET, target, &address.sin_addr) == 1 else { continue }
            var byte: UInt8 = 1
            let sent = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(discoverySocket, &byte, 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if sent < 0 { failures += 1; lastError = errno }
        }
        if failures > 0, !discoveryErrorLogged {
            discoveryErrorLogged = true
            log("CarLife 发现包有 \(failures)/\(targets.count) 个发送失败（errno \(lastError)）；广播在 iOS 上可能被限制，仍会逐个地址发送。找不到车机时请填写车机 IP")
        }
    }

    private struct LocalNetwork { let broadcast: String; let hosts: [String] }
    private static func localNetworks() -> [LocalNetwork] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: [LocalNetwork] = []
        var current = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge"),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let mask = entry.pointee.ifa_netmask else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            // Sweep only /24 or smaller networks.
            guard netmask >= 0xFFFF_FF00, netmask != 0xFFFF_FFFF else { continue }
            let network = ip & netmask, broadcast = network | ~netmask
            func text(_ value: UInt32) -> String { "\(value >> 24).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255)" }
            let hosts = (network + 1 ..< broadcast).filter { $0 != ip }.map(text)
            result.append(LocalNetwork(broadcast: text(broadcast), hosts: hosts))
        }
        return result
    }

    // MARK: Lifecycle

    private func stopOnQueue() {
        generation = UUID(); running = false
        timer?.cancel(); timer = nil
        listeners.forEach { $0.cancel() }; listeners.removeAll()
        session?.close(reason: "CarPlay 已停止"); session = nil
        parameters = VideoParameterSets(codec: .h264); warnedCodec = false
        if discoverySocket >= 0 { close(discoverySocket); discoverySocket = -1 }
        discoveryErrorLogged = false
    }

    private func log(_ message: String) { onLog?(message) }
    private func state(_ message: String) {
        onLog?(message)
        DispatchQueue.main.async { [weak self] in self?.onState?(message) }
    }

    deinit { if discoverySocket >= 0 { close(discoverySocket) } }
}

// MARK: - Transport link

private final class Link {
    let connection: NWConnection
    let channel: Int
    var buffer = Data()
    var pendingBytes = 0
    /// Last time a write completed (or the first write started); detects stalled sockets.
    var progressAt = DispatchTime.now()
    init(connection: NWConnection, channel: Int) { self.connection = connection; self.channel = channel }

    func write(_ data: Data) {
        if pendingBytes == 0 { progressAt = .now() }
        pendingBytes += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingBytes = max(0, self.pendingBytes - data.count)
            self.progressAt = .now()
            if error != nil { self.connection.cancel() }
        })
    }
    var stalled: Bool { pendingBytes > 0 && DispatchTime.now().uptimeNanoseconds - progressAt.uptimeNanoseconds > 4_000_000_000 }
}

// MARK: - Framing

struct CarLifeMessage { let channel: Int; let id: Int; var payload: Data }

enum CarLifeError: LocalizedError {
    case protocolViolation(String)
    var errorDescription: String? { if case .protocolViolation(let code) = self { return code }; return nil }
}

private func require(_ condition: Bool, _ code: String) throws {
    if !condition { throw CarLifeError.protocolViolation(code) }
}

enum CarLifeFraming {
    static let maximumMessageBytes = 67_108_864
    /// Channels 1 (command) and 6 (touch) use 8-byte headers, the rest 12.
    static func headerSize(_ channel: Int) -> Int { channel == 1 || channel == 6 ? 8 : 12 }

    static func encode(_ message: CarLifeMessage) throws -> Data {
        let header = headerSize(message.channel)
        try require(message.payload.count <= maximumMessageBytes - header, "invalid_payload_length")
        var data = Data(capacity: header + message.payload.count)
        if header == 8 {
            try require(message.payload.count <= 65535, "invalid_payload_length")
            data.appendBE(UInt16(message.payload.count)); data.appendBE(UInt16(0))
        } else {
            data.appendBE(UInt32(message.payload.count)); data.appendBE(UInt32(0))
        }
        data.appendBE(UInt32(truncatingIfNeeded: message.id))
        data.append(message.payload)
        return data
    }

    /// Removes one complete message from `buffer`, or returns nil when more bytes are needed.
    static func take(from buffer: inout Data, channel: Int) throws -> CarLifeMessage? {
        let size = headerSize(channel)
        guard buffer.count >= size else { return nil }
        let bytes = [UInt8](buffer.prefix(size))
        let length: Int, id: Int
        if size == 8 {
            length = Int(bytes[0]) << 8 | Int(bytes[1])
            id = Int(UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7]))
        } else {
            length = Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
            id = Int(UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16 | UInt32(bytes[10]) << 8 | UInt32(bytes[11]))
        }
        try require((0...(maximumMessageBytes - size)).contains(length), "invalid_payload_length")
        // Bounded input: only the video channel carries large messages, and it is outbound.
        try require(length <= 4 * 1024 * 1024, "payload_too_large")
        guard buffer.count >= size + length else { return nil }
        let payload = Data(buffer[(buffer.startIndex + size)..<(buffer.startIndex + size + length)])
        buffer.removeFirst(size + length)
        return CarLifeMessage(channel: channel, id: id, payload: payload)
    }
}

private extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) { Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) } }
}

// MARK: - Protobuf subset

/// Presence-aware subset of proto2; unknown fields are skipped, never interpreted.
struct CarLifeProto {
    private(set) var integers: [Int: Int64] = [:]
    private(set) var strings: [Int: [Data]] = [:]
    func number(_ field: Int) -> Int64? { integers[field] }
    func text(_ field: Int) -> String? { strings[field]?.last.map { String(decoding: $0, as: UTF8.self) } }
    func messages(_ field: Int) -> [CarLifeProto] { (strings[field] ?? []).compactMap { try? CarLifeProto(parsing: $0) } }

    init(parsing data: Data) throws {
        let bytes = [UInt8](data)
        var offset = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                try require(offset < bytes.count, "malformed_protobuf")
                let next = bytes[offset]; offset += 1
                if index == 9 { try require(next <= 1, "malformed_protobuf") }
                value |= UInt64(next & 127) << UInt64(index * 7)
                if next < 128 { return value }
            }
            throw CarLifeError.protocolViolation("malformed_protobuf")
        }
        func skip(_ count: Int) throws {
            try require(count >= 0 && count <= bytes.count - offset, "malformed_protobuf"); offset += count
        }
        func field(_ tag: UInt64, depth: Int, collect: Bool) throws {
            try require(depth < 32 && (1...536_870_911).contains(tag >> 3), "malformed_protobuf")
            let number = Int(tag >> 3)
            switch tag & 7 {
            case 0: let value = try varint(); if collect { integers[number] = Int64(bitPattern: value) }
            case 1: try skip(8)
            case 2:
                let length = try varint()
                try require(length <= UInt64(bytes.count - offset), "malformed_protobuf")
                let end = offset + Int(length)
                if collect { strings[number, default: []].append(Data(bytes[offset..<end])) }
                offset = end
            case 3:
                while true {
                    let nested = try varint()
                    if nested & 7 == 4 { try require(nested >> 3 == UInt64(number), "malformed_protobuf"); break }
                    try field(nested, depth: depth + 1, collect: false)
                }
            case 5: try skip(4)
            default: throw CarLifeError.protocolViolation("malformed_protobuf")
            }
        }
        while offset < bytes.count { try field(try varint(), depth: 0, collect: true) }
    }
}

struct CarLifeProtoWriter {
    private(set) var data = Data()
    private mutating func varint(_ number: UInt64) {
        var value = number
        while value & ~UInt64(127) != 0 { data.append(UInt8(value & 127) | 128); value >>= 7 }
        data.append(UInt8(value))
    }
    func number(_ field: Int, _ value: Int64) -> Self {
        var copy = self; copy.varint(UInt64(field) << 3); copy.varint(UInt64(bitPattern: value)); return copy
    }
    func text(_ field: Int, _ value: String) -> Self { bytes(field, Data(value.utf8)) }
    func bytes(_ field: Int, _ value: Data) -> Self {
        var copy = self; copy.varint(UInt64(field) << 3 | 2); copy.varint(UInt64(value.count)); copy.data.append(value); return copy
    }
}

// MARK: - Crypto

private final class CarLifeCrypto {
    private var key: Data?
    private(set) var active = false

    /// RSA-PKCS#1 encrypts a fresh AES-128 key with the head unit's SubjectPublicKeyInfo.
    func negotiate(publicKey base64: String) throws -> String {
        guard let der = Data(base64Encoded: base64) else { throw CarLifeError.protocolViolation("invalid_public_key") }
        let pkcs1 = Self.rsaKey(fromSPKI: der) ?? der
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let publicKey = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, nil) else {
            throw CarLifeError.protocolViolation("invalid_public_key")
        }
        var fresh = Data(count: 16)
        let status = fresh.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        try require(status == errSecSuccess, "random_failed")
        guard let encrypted = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionPKCS1, fresh as CFData, nil) as Data? else {
            throw CarLifeError.protocolViolation("content_encryption_failed")
        }
        key = fresh
        return encrypted.base64EncodedString()
    }

    func activate() throws { try require(key != nil, "unexpected_phase"); active = true }

    func transform(_ message: CarLifeMessage, encrypt: Bool) throws -> CarLifeMessage {
        guard active, message.id != 98305, !message.payload.isEmpty, let key else { return message }
        var output = Data(count: message.payload.count + kCCBlockSizeAES128)
        let outputCount = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            message.payload.withUnsafeBytes { input in
                key.withUnsafeBytes { k in
                    CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                            k.baseAddress, kCCKeySizeAES128, nil,
                            input.baseAddress, message.payload.count, out.baseAddress, outputCount, &moved)
                }
            }
        }
        try require(status == kCCSuccess, "content_encryption_failed")
        output.count = moved
        var result = message; result.payload = output
        return result
    }

    /// MD5 over "CARLIFE" + brand + model + sdk + the challenge after its "2.0;" prefix.
    static func authenticate(brand: String, model: String, sdk: String, challenge: String) throws -> String {
        try require(challenge.hasPrefix("2.0;") && challenge.count > 4, "unsupported_auth_challenge")
        let text = "CARLIFE" + brand + model + sdk + challenge.dropFirst(4)
        return Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// SubjectPublicKeyInfo → PKCS#1 RSAPublicKey (the BIT STRING contents), as SecKey expects.
    private static func rsaKey(fromSPKI der: Data) -> Data? {
        let bytes = [UInt8](der)
        func tlv(_ at: Int) -> (tag: UInt8, start: Int, end: Int)? {
            guard at + 1 < bytes.count else { return nil }
            var length = Int(bytes[at + 1]), start = at + 2
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard count > 0, count <= 4, start + count <= bytes.count else { return nil }
                length = bytes[start..<(start + count)].reduce(0) { $0 << 8 | Int($1) }
                start += count
            }
            guard start + length <= bytes.count else { return nil }
            return (bytes[at], start, start + length)
        }
        guard let outer = tlv(0), outer.tag == 0x30,
              let algorithm = tlv(outer.start), algorithm.tag == 0x30,
              let bits = tlv(algorithm.end), bits.tag == 0x03, bits.end > bits.start + 1, bytes[bits.start] == 0 else { return nil }
        return Data(bytes[(bits.start + 1)..<bits.end])
    }
}

// MARK: - Session

/// One head unit and one authenticated lifetime; a reconnect always gets a new instance.
/// Confined to the CarLifeOutput queue.
private final class Session {
    /// 3.x receivers (protocol 1) neither challenge nor accept parameter sets on every keyframe.
    private enum Profile { case legacy, current
        init?(major: Int64) { switch major { case 1: self = .legacy; case 3, 4: self = .current; default: return nil } }
    }
    // Device information the auth hash is computed over; kept equal to the OpenXPlay relay.
    private static let brand = "OpenXPlay", model = "Relay", sdk = "1"

    let peer: String
    private(set) var active = true
    private(set) var authenticated = false
    private var channels: [Int: Link] = [:]
    private let crypto = CarLifeCrypto()
    private var profile: Profile?
    private var deviceSent = false, authAnswered = false, authAccepted = false
    private var streaming = false
    private var encryptionRequested = false
    private let width: Int, height: Int, maxFPS: Int
    private var fps: Int
    private var encoderChannel = 1
    private var lastSent = DispatchTime.now()
    private var lastKeyframeRequest = DispatchTime(uptimeNanoseconds: 0)
    private let createdAt = DispatchTime.now()
    private var framesSent = 0
    private var waitingForKeyframe = true
    private var parameterSetsSent = false
    private var skips = 0
    private var loggedNoVideoLink = false
    /// 正在回放缓存段，这期间不按积压跳帧。
    var replaying = false
    /// Held fingers in the order they went down; pointer-up indexes refer to this order.
    private var touches: [TouchPoint] = []
    /// Above this backlog on the video socket, frames are skipped to the next keyframe.
    private let skipPendingBytes = 1024 * 1024

    var log: ((String) -> Void)?
    var onState: ((String) -> Void)?
    var onTouches: (([TouchPoint]) -> Void)?
    var onControl: ((CarPlayControl) -> Void)?
    var onKeyframeRequest: ((String) -> Void)?
    /// The head unit just asked for a picture. The owner may hand over a cached IDR so the
    /// receiver does not have to wait for a brand-new keyframe (iOS 16 rejects forceKeyFrame).
    var onStartFrameNeeded: (() -> Void)?

    init(peer: String, width: Int, height: Int, maxFPS: Int) {
        self.peer = peer; self.width = width; self.height = height; self.maxFPS = maxFPS; fps = maxFPS
    }

    private static func port(for channel: Int) -> String {
        CarLifeOutput.ports.indices.contains(channel - 1) ? String(CarLifeOutput.ports[channel - 1]) : "?"
    }

    func attach(_ link: Link) {
        channels.updateValue(link, forKey: link.channel)?.connection.cancel()
        if link.channel == 1 {
            log?("车机 \(peer) 已连接")
        } else {
            log?("CarLife 通道 \(link.channel) 已连接（端口 \(Self.port(for: link.channel))）")
        }
    }
    func owns(_ link: Link) -> Bool { channels[link.channel] === link }
    func ownsChannel(_ channel: Int) -> Bool { channels[channel] != nil }

    func receive(_ wire: CarLifeMessage) throws {
        guard active else { return }
        // 车机如果对音乐模块有回应（准备/错误码），这里就能看到；一直没有输出说明它压根没派发。
        if wire.channel == 3, channelThreeInbound < 8 {
            channelThreeInbound += 1
            log?("CarLife 通道 3 收到车机消息 id=\(wire.id)，长度 \(wire.payload.count)")
        }
        let message = try crypto.transform(wire, encrypt: false)
        guard profile != nil || message.id == 98305 else { return }
        func proto() throws -> CarLifeProto { try CarLifeProto(parsing: message.payload) }
        switch message.id {
        case 98305:
            try require(profile == nil, "unexpected_phase")
            let payload = try proto()
            guard let major = payload.number(1), let selected = Profile(major: major) else {
                log?("车机协议版本不受支持（\(payload.number(1).map(String.init) ?? "无")）")
                throw CarLifeError.protocolViolation("version_mismatch")
            }
            profile = selected
            log?("协议版本 \(major).\(payload.number(2) ?? 0)，\(selected == .legacy ? "3.x 车机" : "4.x 车机")")
            send(1, 65538, CarLifeProtoWriter().number(1, 1).number(2, major).data)
            onState?("CarLife：车机 \(peer) 已连接，正在认证")
        case 98343, 98307:
            sendDevice()
        case 98376:
            try require(deviceSent, "unexpected_phase")
            guard let challenge = try proto().text(1) else { throw CarLifeError.protocolViolation("malformed_protobuf") }
            let answer = try CarLifeCrypto.authenticate(brand: Self.brand, model: Self.model, sdk: Self.sdk, challenge: challenge)
            send(1, 65609, CarLifeProtoWriter().text(1, answer).data)
            authAnswered = true
        case 98378:
            try require(authAnswered, "unexpected_phase")
            try require(try proto().number(1) == 1, "auth_rejected")
            authAccepted = true
            send(1, 65611, CarLifeProtoWriter().number(1, 1).data)
        case 98380:
            try require(authAccepted, "unexpected_phase")
            established(reason: "认证通过")
            let flags: [(String, Int64)] = [("AAC_SUPPORT", 0), ("CONTENT_ENCRYPTION", 0), ("CONNECT_TYPE", 5)]
            var writer = CarLifeProtoWriter().number(1, Int64(flags.count))
            for (key, value) in flags { writer = writer.bytes(2, CarLifeProtoWriter().text(1, key).number(2, value).data) }
            send(1, 65617, writer.data)
        case 98386:
            let wantsEncryption = try proto().messages(2).contains { $0.text(1) == "CONTENT_ENCRYPTION" && $0.number(2) == 1 }
            if wantsEncryption, !encryptionRequested, !crypto.active {
                encryptionRequested = true
                log?("车机要求内容加密")
                send(1, 65642)
            }
        case 98411:
            try require(authenticated && !crypto.active, "unexpected_phase")
            guard let key = try proto().text(1) else { throw CarLifeError.protocolViolation("malformed_protobuf") }
            send(1, 65644, CarLifeProtoWriter().text(1, try crypto.negotiate(publicKey: key)).data)
        case 98413:
            try require(!crypto.active, "unexpected_phase")
            send(1, 65646)
        case 98415:
            try crypto.activate()
            log?("内容加密已启用")
        case 98311:
            // A receiver that does not challenge establishes the session at video negotiation.
            if !authenticated, profile == .legacy { established(reason: "车机无需认证") }
            try require(authenticated, "unexpected_phase")
            let payload = try proto()
            guard let rawWidth = payload.number(1), let rawHeight = payload.number(2),
                  (16...16384).contains(rawWidth), (16...16384).contains(rawHeight) else {
                throw CarLifeError.protocolViolation("invalid_display")
            }
            let requestedFPS = Int(payload.number(3) ?? 0)
            fps = requestedFPS > 0 ? min(max(requestedFPS, 1), maxFPS) : maxFPS
            encoderChannel = message.channel
            log?("车机屏幕 \(rawWidth)×\(rawHeight)，请求 \(requestedFPS) FPS；发送 \(width)×\(height) @ \(fps) FPS H.264")
            send(encoderChannel, 65544, CarLifeProtoWriter().number(1, Int64(width)).number(2, Int64(height)).number(3, Int64(fps)).data)
        case 98313:
            try require(authenticated, "unexpected_phase")
            streaming = true; waitingForKeyframe = true
            loggedNoVideoLink = false
            onState?("CarLife：车机已请求画面，正在等待关键帧")
            log?("CarLife：车机请求画面（视频通道 \(channels[2] == nil ? "未建立" : "已建立")）")
            // 现有代码只会向 iPhone 要一个新 IDR。iOS 16.x 会把这个事件命令回 408，
            // 于是车机永远等不到关键帧。这里同时让上层把缓存中的 IDR 直接回放给车机。
            onStartFrameNeeded?()
            requestKeyframe("车机请求画面")
        case 98314:
            streaming = false
            releaseTouches()
            onState?("CarLife：车机暂停了画面")
        case 98389:
            if let code = try? proto().text(1) { log?("车机状态码 \(code.prefix(40))") }
        case 425985, 425998:
            guard authenticated else { break }
            do { try touch(message.payload, raw: message.id == 425998) }
            catch { log?("忽略无效触控数据") }
        case 425992:
            guard authenticated, let code = try? proto().number(1), let control = Self.control(forKey: code) else { break }
            onControl?(control)
        default:
            // Empty keepalives and unknown extension messages need no reply.
            break
        }
    }

    private func established(reason: String) {
        authenticated = true
        onState?("CarLife：已与车机 \(peer) 建立会话（\(reason)）")
    }

    private func sendDevice() {
        guard !deviceSent else { return }
        send(1, 65540, CarLifeProtoWriter().text(1, "Android").text(4, Self.brand).text(14, Self.model)
            .text(20, Self.sdk).text(24, "4.0.0").data)
        deviceSent = true
    }

    // MARK: Video

    func video(picture: [Data], keyframe: Bool, parameterSets: [Data]) {
        guard active, authenticated, streaming else { return }
        guard let videoLink = channels[2], let profile else {
            // 只报一次，免得刷屏；这行能区分“通道没建”和“参数集没拿到”。
            if !loggedNoVideoLink {
                loggedNoVideoLink = true
                log?("CarLife：画面暂不可发（视频通道\(channels[2] == nil ? "未建立" : "已建立")，编码参数\(profile == nil ? "缺失" : "就绪")）")
            }
            return
        }
        if waitingForKeyframe {
            guard keyframe else { return }
            waitingForKeyframe = false
        } else if !keyframe, !replaying, videoLink.pendingBytes > skipPendingBytes {
            // Never drop a single dependent frame: skip the rest of this GOP and ask for an IDR.
            waitingForKeyframe = true; skips += 1
            if skips == 1 || skips % 10 == 0 { log?("车机网络跟不上，跳到下一个关键帧（第 \(skips) 次）") }
            requestKeyframe("网络积压")
            return
        }
        func annexB(_ units: [Data]) -> Data {
            units.reduce(into: Data()) { $0.append(contentsOf: [0, 0, 0, 1]); $0.append($1) }
        }
        var units = picture
        if keyframe {
            switch profile {
            case .current:
                units = parameterSets + picture
            case .legacy:
                // A 3.x receiver keeps the first parameter sets and supplies them itself after a
                // decoder reset, but only to a keyframe whose first NAL is the IDR slice.
                let idr = Array(picture.drop { VideoCodec.h264.nalType($0) != 5 })
                if !idr.isEmpty {
                    units = (parameterSetsSent ? [] : parameterSets) + idr
                    parameterSetsSent = true
                }
            }
        }
        guard send(2, 131073, annexB(units)) else { return }
        framesSent += 1
        if framesSent == 1 { onState?("CarLife：正在向车机 \(peer) 发送 CarPlay 画面") }
    }

    // MARK: Audio (CarLife 音乐模块，通道 3)

    /// 车机端 CarLife 的音乐模块（`La/a/b/p/a;`）只在通道 3 上收音频：
    /// · 0x30001 带 CarlifeMusicInit{sampleRate, channelConfig, sampleFormat}，收到就建 AudioTrack；
    /// · 0x30002 = 停止并销毁播放器；0x30003 = 暂停；0x30004 = 播放/继续；0x30005 = 空操作；
    /// · 0x30006 携带裸 PCM（PCM16 小端），车机把它塞进自己的播放队列。
    ///
    /// 【迷行 4.1.3 无声根因，反编译实锤】之前把 0x30003 当 play、0x30004 当 pause，正好反了：
    /// 车机 g0() 的 packed-switch 0x30001 起依次是 init/stop/pause/play/noop/data——
    /// · 0x30003 → `c.a()` → 日志「AudioPlayer pause」→ `AudioTrack.pause()`（真暂停）
    /// · 0x30004 → `c.c()` → 日志「AudioPlayer resume」→ `AudioTrack.play()`（真播放）
    /// 于是我们每次 init 后发 0x30003，车机把刚建好的 AudioTrack 立刻暂停，数据一直在写但喇叭永远不出声。
    /// 对调 play/pause 后，init→0x30004 才会真正 start。
    private enum MusicCommand {
        static let initialize = 196_609   // 0x30001
        static let stop = 196_610         // 0x30002
        static let pause = 196_611        // 0x30003（车机是 pause！反编译确认）
        static let play = 196_612         // 0x30004（车机是 play！反编译确认）
        static let noop = 196_613         // 0x30005
        static let data = 196_614         // 0x30006
    }
    /// 导航 TTS 模块 La/a/b/p/b; 的命令（smali 反编译确认）：0x40001 init / 0x40002 stop / 0x40003 data。
    /// 它和音乐模块各有独立 AudioTrack + AudioFocus，所以导航播报不会再和音乐抢同一个播放器。
    private enum TTSCommand {
        static let initialize = 262_145   // 0x40001
        static let stop = 262_146         // 0x40002
        static let data = 262_147         // 0x40003
    }
    private var audioRate = 0, audioChannels = 0
    private var audioInitAt = DispatchTime(uptimeNanoseconds: 0)
    private var audioInitLink: ObjectIdentifier?
    private var lastAudioReport = DispatchTime(uptimeNanoseconds: 0)
    private var audioFramesSent = 0
    private var audioPlayed = false
    private var loggedNoAudioChannel = false
    /// 车机在通道 3 上回过来的消息计数，只记前几条用于诊断。
    private var channelThreeInbound = 0
    private var lastPlayAt = DispatchTime(uptimeNanoseconds: 0)
    private var lastAudioAt = DispatchTime(uptimeNanoseconds: 0)
    /// 【停播后仍响】CarPlay 在 iPhone 停止音乐后仍持续推静音帧（日志：数据包一直涨、载荷=6 字节）。
    /// 照单全收会让车机 AudioTrack 一直有数据、加上 tick() 每 5 秒补 play，停播后还不停重播残留缓冲。
    /// 连续静音超过 1.2 秒就发一次 pause 并停送静音数据；再次出现有效声音时自动恢复 play。
    private var silentSince: DispatchTime?
    private var pausedBySilence = false

    /// 导航 TTS（通道 4）独立播放器状态，与音乐互不干扰。
    private var ttsRate = 0, ttsChannels = 0
    private var ttsInitLink: ObjectIdentifier?
    private var ttsFramesSent = 0
    private var ttsPlayed = false
    private var ttsSilentSince: DispatchTime?
    private var ttsPausedBySilence = false
    private var lastTTSAudioAt = DispatchTime(uptimeNanoseconds: 0)
    private var loggedNoTTSChannel = false
    /// 通话/微信语音期间：暂停车机音乐与导航，避免混入其它音频。
    private var callActive = false
    private var musicPausedByCall = false
    private var ttsPausedByCall = false
    /// 通话对方声音（通道3，音乐暂停时独占）独立状态。
    private var voiceRate = 0, voiceChannels = 0
    private var voiceInitLink: ObjectIdentifier?
    private var voicePlayed = false
    private var lastVoiceReport = DispatchTime(uptimeNanoseconds: 0)
    private var lastVoicePlayAt = DispatchTime(uptimeNanoseconds: 0)
    private var voiceFrames = 0
    /// 导航播报期间把音乐压到正常音量的 70%（App 侧缩放 PCM，不依赖车机 setVolume）。
    private var duckMusicUntil = DispatchTime(uptimeNanoseconds: 0)
    private var loggedDucking = false

    private var audioLink: Link? {
        // 车机只在通道 3 上认音乐消息；通道没建时不要往别的通道乱发。
        channels[3]
    }
    private var ttsLink: Link? { channels[4] }

    func audio(_ buffer: AVAudioPCMBuffer) {
        guard active, authenticated else { return }
        // 通话期间音乐一律不送车机，避免混入通话。
        guard !callActive else { return }
        let frames = Int(buffer.frameLength)
        let channelsInBuffer = Int(buffer.format.channelCount)
        let rate = Int(buffer.format.sampleRate.rounded())
        guard frames > 0, channelsInBuffer > 0, rate >= 8000 else { return }
        // 【停播后仍响】先做静音检测，静音帧绝不送车机：
        // iPhone 停止音乐后 CarPlay 仍持续推静音帧，若照单全收，车机 AudioTrack 会被 tick() 的
        // 定期 play 不断唤醒、重播残留缓冲 → 停播后还一直响。连续静音 1.2 秒就发一次 pause。
        let nowNs = DispatchTime.now().uptimeNanoseconds
        // 导航播报时把音乐压到 70%：App 侧直接缩放 PCM16，车机无需支持 setVolume。
        let ducking = nowNs < duckMusicUntil.uptimeNanoseconds
        guard var pcm = Self.pcm16(buffer) else { return }
        if ducking { Self.scalePCM16(&pcm, 0.7) }
        if ducking && !loggedDucking {
            loggedDucking = true
            log?("CarLife 伴音：导航播报中，音乐音量压低到 70%")
        }
        if !ducking { loggedDucking = false }
        let peak = Self.peakPCM16(pcm)
        if peak < 64 {
            // 【闪退修复】silentSince 必须在这里就用当前时刻落定，不能晚于 nowNs：
            // 之前先算 nowNs 再 silentSince = .now()，两者先后两个采样点，若 since > nowNs，
            // UInt64 减法下溢 → Swift 直接 trap（车机一连上推静音帧就闪）。
            // 统一用 nowNs 落定，并用 >= 钳制后再相减，杜绝任何负差。
            if silentSince == nil { silentSince = DispatchTime(uptimeNanoseconds: nowNs) }
            if !pausedBySilence, let since = silentSince, nowNs >= since.uptimeNanoseconds,
               nowNs - since.uptimeNanoseconds > 1_200_000_000 {
                send(3, MusicCommand.pause)
                pausedBySilence = true
                audioPlayed = false
                log?("CarLife 伴音：iPhone 已停止播放（持续静音），已暂停车机播放")
            }
            return
        }
        if pausedBySilence {
            send(3, MusicCommand.play)
            pausedBySilence = false
            silentSince = nil
            audioPlayed = true
            lastPlayAt = .now()
            log?("CarLife 伴音：声音恢复，已重新播放")
        } else {
            silentSince = nil
        }
        guard let link = audioLink else {
            if !loggedNoAudioChannel {
                loggedNoAudioChannel = true
                log?("CarLife：音频通道（通道 3 / 端口 9240）没建立，声音暂时送不上车机")
            }
            return
        }
        let linkID = ObjectIdentifier(link)
        // 通道 3 可能比音频晚到（车机自己决定什么时候连），换了 socket 就得重发一次初始化，
        // 否则车机那边根本没建 AudioTrack，数据进来也只能丢。
        if audioRate != rate || audioChannels != channelsInBuffer || audioInitLink != linkID {
            audioRate = rate; audioChannels = channelsInBuffer; audioFramesSent = 0
            // 车机的 `La/a/b/l/c/d/b;`（AudioParams）把这三个数当成 (sampleRate, channelCount, bitDepth)：
            //   c() 用 channelCount==1 → CHANNEL_OUT_MONO(4)，否则 STEREO(12)；
            //   b() 用 bitDepth==16 → ENCODING_PCM_16BIT(2)，否则 FLOAT(3)。
            // 所以这里必须送"声道数 1/2"和"位深 16"，送 Android 枚举(4/12、2)会被当成 4 声道 + float。
            let initData = CarLifeProtoWriter().number(1, Int64(rate)).number(2, Int64(channelsInBuffer)).number(3, 16).data
            send(3, MusicCommand.initialize, initData)
            audioInitAt = .now()
            send(3, MusicCommand.play)
            audioPlayed = true
            lastPlayAt = .now()
            audioInitLink = linkID
            log?("CarLife 伴音：初始化 \(rate) Hz / \(channelsInBuffer) 声道 / 16 位 PCM16（通道 3 已就绪，播放命令=\(String(format: "0x%X", MusicCommand.play))）")
        }
        // 太久没声（切歌/暂停后恢复）时补一次播放命令，免得车机还停在暂停态。
        let now = DispatchTime.now().uptimeNanoseconds
        if !audioPlayed || now - lastAudioAt.uptimeNanoseconds > 1_000_000_000 {
            send(3, MusicCommand.play); audioPlayed = true; lastPlayAt = .now()
        }
        lastAudioAt = .now()
        // 车机端写入跟不上就丢这一小段，别把整条连接堵死。
        guard link.pendingBytes < 512 * 1024 else { return }
        guard send(3, MusicCommand.data, pcm) else { return }
        if audioFramesSent == 0 { log?("CarLife 伴音：已开始向车机送音频（\(pcm.count) 字节/包）") }
        audioFramesSent += frames
    }

    /// 通话/微信语音占用时，暂停车机音乐(通道3)与导航(通道4)，结束后恢复。
    func setCallActive(_ active: Bool) {
        guard active != callActive else { return }
        callActive = active
        if active {
            if !pausedBySilence, audioLink != nil {
                send(3, MusicCommand.pause); musicPausedByCall = true
            }
            if !ttsPausedBySilence, ttsLink != nil {
                send(4, TTSCommand.stop); ttsPausedByCall = true
            }
            // 通话开始：先停掉通道3，随后 voiceAudio() 会用通话格式重新 init 接管。
            voicePlayed = false
            log?("CarLife：通话占用，已暂停车机音乐/导航，避免混入通话")
        } else {
            // 通话结束：若之前确实因通话暂停过，恢复播放/重建导航。
            voicePlayed = false
            // 音乐此前是在通话格式下 init 的，这里清掉强制下一帧音乐按 44100/2 重新 init，
            // 否则车机会继续按通话的 48000/1 解析音乐 → 变调/杂音。
            audioInitLink = nil; audioPlayed = false; pausedBySilence = false; silentSince = nil
            if musicPausedByCall {
                musicPausedByCall = false
                // 不在这里 send play：通道3此刻还是通话的 48000/1 格式，若直接 play 会播一段
                // 对方残音/变调。交给下一帧音乐走 audio() 的音格式检测，重新 init(44100/2)+play，
                // 这样"因通话暂停的音乐"会在通话结束后自动、正确地继续播放。
                audioPlayed = false
            }
            if ttsPausedByCall {
                ttsPausedByCall = false
                if !ttsPausedBySilence, ttsLink != nil {
                    // 导航下次有数据会重新 init+播报，这里只需清状态。
                    ttsPlayed = false; ttsInitLink = nil
                }
            }
            log?("CarLife：通话结束，已恢复车机音乐/导航")
        }
    }

    // MARK: Audio - 导航播报（TTS，通道 4）
    /// 车机导航 TTS 模块 `La/a/b/p/b;` 在通道 4 上：
    /// · 0x40001 带 CarlifeTTSInit{sampleRate, channelConfig, sampleFormat} 建独立 AudioTrack；
    /// · 0x40002 stop；0x40003 携带裸 PCM16。
    /// 字段号与音乐 init 完全一致（1=rate, 2=channels, 3=bitDepth）。
    func navigationAudio(_ buffer: AVAudioPCMBuffer) {
        guard active, authenticated else { return }
        guard !callActive else { return }  // 通话期间导航也不送车机
        let frames = Int(buffer.frameLength)
        let channelsInBuffer = Int(buffer.format.channelCount)
        let rate = Int(buffer.format.sampleRate.rounded())
        guard frames > 0, channelsInBuffer > 0, rate >= 8000 else { return }
        guard let pcm = Self.pcm16(buffer) else { return }
        let peak = Self.peakPCM16(pcm)
        let nowNs = DispatchTime.now().uptimeNanoseconds

        // 导航播报同样做静音检测：播报结束后停，避免残留缓冲一直占着 TTS AudioTrack。
        if peak < 64 {
            if ttsSilentSince == nil { ttsSilentSince = DispatchTime(uptimeNanoseconds: nowNs) }
            if !ttsPausedBySilence, let since = ttsSilentSince, nowNs >= since.uptimeNanoseconds,
               nowNs - since.uptimeNanoseconds > 800_000_000 {
                send(4, TTSCommand.stop)
                ttsPausedBySilence = true
                ttsPlayed = false
                log?("CarLife 导航：播报结束（静音），已停止车机导航通道")
            }
            return
        }
        if ttsPausedBySilence {
            ttsPausedBySilence = false
            ttsSilentSince = nil
        } else {
            ttsSilentSince = nil
        }
        // 导航播报有声：接下来 1.5 秒把音乐压到 70%（连续播报每帧都会续期）。
        duckMusicUntil = DispatchTime(uptimeNanoseconds: nowNs + 1_500_000_000)
        guard let link = ttsLink else {
            if !loggedNoTTSChannel {
                loggedNoTTSChannel = true
                log?("CarLife：导航音频通道（通道 4 / 端口 9241）没建立，导航播报暂时送不上车机")
            }
            return
        }
        let linkID = ObjectIdentifier(link)
        if ttsRate != rate || ttsChannels != channelsInBuffer || ttsInitLink != linkID {
            ttsRate = rate; ttsChannels = channelsInBuffer; ttsFramesSent = 0
            let initData = CarLifeProtoWriter().number(1, Int64(rate)).number(2, Int64(channelsInBuffer)).number(3, 16).data
            send(4, TTSCommand.initialize, initData)
            ttsInitLink = linkID
            log?("CarLife 导航：初始化 \(rate) Hz / \(channelsInBuffer) 声道 / 16 位 PCM16（通道 4 已就绪）")
        }
        let now = nowNs
        let lastAt = lastTTSAudioAt.uptimeNanoseconds
        if !ttsPlayed || (now >= lastAt && now - lastAt > 2_000_000_000) {
            // TTS init 自带 play，不需要额外的 play 命令（命令表只有 init/stop/data）。
            ttsPlayed = true
        }
        lastTTSAudioAt = DispatchTime(uptimeNanoseconds: now)
        guard link.pendingBytes < 512 * 1024 else { return }
        guard send(4, TTSCommand.data, pcm) else { return }
        if ttsFramesSent == 0 { log?("CarLife 导航：已开始向车机送导航播报（\(pcm.count) 字节/包）") }
        ttsFramesSent += frames
    }

    // MARK: Audio - 通话对方声音（通道 3，音乐暂停时独占）
    /// 通话期间把对方声音送车机喇叭。iPhone 已把通话音频交给 CarPlay，本机听筒不再出声，
    /// 若不送到车机就是「听不到对方」。这里刻意不检查 callActive——通话音频正是要送的那一路；
    /// 音乐/导航已在 setCallActive(true) 里 pause/stop，通道 3/4 此刻只有对方声音。
    func voiceAudio(_ buffer: AVAudioPCMBuffer) {
        guard active, authenticated, callActive else { return }
        let frames = Int(buffer.frameLength)
        let channelsInBuffer = Int(buffer.format.channelCount)
        let rate = Int(buffer.format.sampleRate.rounded())
        guard frames > 0, channelsInBuffer > 0, rate >= 8000 else { return }
        guard let pcm = Self.pcm16(buffer) else { return }
        guard let link = audioLink else { return }
        let linkID = ObjectIdentifier(link)
        // 通话音频（Opus 48000/1）与刚才的音乐（AAC 44100/2）格式不同，必须重新 init，
        // 否则车机还按 44100/2 解析 —— 对方声音会出现变调/杂音/无声。
        if voiceRate != rate || voiceChannels != channelsInBuffer || voiceInitLink != linkID || !voicePlayed {
            voiceRate = rate; voiceChannels = channelsInBuffer
            let initData = CarLifeProtoWriter().number(1, Int64(rate)).number(2, Int64(channelsInBuffer)).number(3, 16).data
            send(3, MusicCommand.initialize, initData)
            send(3, MusicCommand.play)
            voicePlayed = true
            voiceFrames = 0
            lastVoicePlayAt = .now()
            voiceInitLink = linkID
            audioInitLink = linkID   // 让通话结束后的音乐发现格式变化、重新 init 回 44100/2
            log?("CarLife 通话：对方声音接管通道3 \(rate) Hz / \(channelsInBuffer) 声道（音乐/导航已暂停）")
        }
        let now = DispatchTime.now().uptimeNanoseconds
        voiceFrames += 1
        let peak = Self.peakPCM16(pcm)
        // 【我听不到对方根因】车机音乐模块收到 init(48000/1) 会重建 AudioTrack，重建后停在
        // STOPPED 态，紧跟的 play 常被忽略。音乐通道有 tick() 每 5 秒补 play，但通话只有几秒，
        // 根本等不到 → 对方声音数据全被丢弃。这里对通话音频每 500ms 补一次 play，
        // 保证重建后的 AudioTrack 尽快进入播放态。
        if now >= lastVoicePlayAt.uptimeNanoseconds, now - lastVoicePlayAt.uptimeNanoseconds > 500_000_000 {
            lastVoicePlayAt = DispatchTime(uptimeNanoseconds: now)
            send(3, MusicCommand.play)
        }
        lastPlayAt = .now(); lastAudioAt = .now()
        if now >= lastVoiceReport.uptimeNanoseconds, now - lastVoiceReport.uptimeNanoseconds > 1_000_000_000 {
            lastVoiceReport = DispatchTime(uptimeNanoseconds: now)
            log?("CarLife 通话：对方声音已送车机 \(voiceFrames) 帧，峰值 \(peak)，通道3待写 \(link.pendingBytes) 字节")
        }
        guard link.pendingBytes < 512 * 1024 else { return }
        guard send(3, MusicCommand.data, pcm) else { return }
    }

    /// Float32（AVAudioEngine 的标准格式）→ 交错 PCM16 小端。
    static func pcm16(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let planes = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return nil }
        var data = Data(count: frames * channels * 2)
        data.withUnsafeMutableBytes { raw in
            guard let out = raw.bindMemory(to: Int16.self).baseAddress else { return }
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let value = max(-1, min(1, Double(planes[channel][frame])))
                    out[frame * channels + channel] = Int16(value * 32_767)
                }
            }
        }
        return data
    }

    /// 取 PCM16 交错数据的峰值绝对值（采样一部分帧即可），用于判断是否静音。
    static func peakPCM16(_ data: Data) -> Int {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard bytes.count >= 2 else { return 0 }
            var peak = 0
            let totalFrames = bytes.count / 2
            let step = max(1, totalFrames / 256)
            var index = 0
            while index < totalFrames {
                let sample = Int16(bitPattern: UInt16(bytes[index * 2]) << 8 | UInt16(bytes[index * 2 + 1]))
                let magnitude = sample == Int16.min ? 32768 : (sample < 0 ? -Int(sample) : Int(sample))
                if magnitude > peak { peak = magnitude }
                index += step
            }
            return peak
        }
    }

    /// 就地缩放交错 PCM16 的幅度（gain<1 降低音量），用于导航播报时的音乐 ducking。
    static func scalePCM16(_ data: inout Data, _ gain: Float) {
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
            let samples = raw.count / MemoryLayout<Int16>.size
            for i in 0..<samples {
                let scaled = Int32(Float(base[i]) * gain)
                base[i] = Int16(max(-32768, min(32767, scaled)))
            }
        }
    }

    func tick() {
        guard active, profile != nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastSent.uptimeNanoseconds > 1_000_000_000 { send(channels[2] != nil ? 2 : 1, 131074) }        // Some head units only recover from decoder resets at a keyframe; keep them regular.
        if streaming, now - lastKeyframeRequest.uptimeNanoseconds >= 1_500_000_000 {
            // 一帧都还没发出去时，同时让上层把缓存 IDR 再回放一次：
            // 车机常常是“先请求画面、后开视频通道”，第一次回放会落在通道还没建的空档上。
            if framesSent == 0, waitingForKeyframe { onStartFrameNeeded?() }
            requestKeyframe(nil)
        }
        // 每 5 秒报一次伴音实况：这行能一眼看出是“没送出去”还是“送了车机不播”。
        if audioRate > 0, now - lastAudioReport.uptimeNanoseconds >= 5_000_000_000 {
            lastAudioReport = .now()
            let seconds = audioRate > 0 ? audioFramesSent / audioRate : 0
            log?("CarLife 伴音：已送 \(seconds) 秒音频，通道3\(audioLink == nil ? "未建立" : "已建立")，待写 \(audioLink?.pendingBytes ?? 0) 字节")
        }
        // 有些车机把最早的 play 吞掉后一直停在“已初始化未播放”，定期补一次（不会打断正在播的）。
        // 但如果正处于静音暂停态，绝不能补 play——那会把车机从 pause 唤醒、重播残留缓冲。
        if audioRate > 0, !pausedBySilence, !callActive, audioLink != nil, now - lastPlayAt.uptimeNanoseconds >= 5_000_000_000 {
            lastPlayAt = .now()
            send(3, MusicCommand.play)
        }
    }

    private func requestKeyframe(_ reason: String?) {
        lastKeyframeRequest = .now()
        onKeyframeRequest?(reason ?? "定期刷新")
    }

    func transportFailure() -> String? {
        if channels.values.contains(where: \.stalled) { return "车机连接写入超时" }
        if !authenticated, DispatchTime.now().uptimeNanoseconds - createdAt.uptimeNanoseconds >= 30_000_000_000 { return "车机认证超时" }
        return nil
    }

    @discardableResult
    private func send(_ channel: Int, _ id: Int, _ payload: Data = Data()) -> Bool {
        guard active, let link = channels[channel] else { return false }
        do {
            let message = try crypto.transform(CarLifeMessage(channel: channel, id: id, payload: payload), encrypt: true)
            link.write(try CarLifeFraming.encode(message))
            lastSent = .now()
            return true
        } catch {
            log?("发送失败：\(error.localizedDescription)"); return false
        }
    }

    // MARK: Input

    /// Action (low byte): 0 down, 1 up, 2 move, 3 cancel, 5 pointer down, 6 pointer up (index in bits 8–15).
    private func touch(_ payload: Data, raw: Bool) throws {
        var contacts: [(id: Int, x: Int, y: Int)] = []
        let action: Int
        if raw {
            let bytes = [UInt8](payload)
            try require(bytes.count >= 4 && (bytes.count - 4) % 5 == 0 && (bytes.count - 4) / 5 <= 10, "invalid_touch")
            action = Int(Int32(bitPattern: UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])))
            var offset = 4
            while offset < bytes.count {
                contacts.append((Int(bytes[offset]), Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]),
                                 Int(bytes[offset + 3]) << 8 | Int(bytes[offset + 4])))
                offset += 5
            }
        } else {
            let proto = try CarLifeProto(parsing: payload)
            guard let value = proto.number(1) else { throw CarLifeError.protocolViolation("invalid_touch") }
            action = Int(truncatingIfNeeded: value)
            if let x = proto.number(2), let y = proto.number(3) { contacts.append((0, Int(x), Int(y))) }
            else { try require([1, 3, 6].contains(action & 255), "invalid_touch") }
            let px = Int(proto.number(4) ?? 0), py = Int(proto.number(5) ?? 0)
            if px != 0 || py != 0 { contacts.append((1, px, py)) }
        }
        let masked = action & 255
        try require([0, 1, 2, 3, 5, 6].contains(masked), "invalid_touch")
        func point(_ c: (id: Int, x: Int, y: Int)) -> TouchPoint {
            TouchPoint(id: c.id, x: min(max(Double(c.x) / Double(width), 0), 1), y: min(max(Double(c.y) / Double(height), 0), 1))
        }
        let valid = contacts.filter { (0...9).contains($0.id) }
        func merge(_ update: [(id: Int, x: Int, y: Int)]) {
            for contact in update {
                if let index = touches.firstIndex(where: { $0.id == contact.id }) { touches[index] = point(contact) }
                else { touches.append(point(contact)) }
            }
        }
        switch masked {
        case 1, 3:
            // Move to the release position first, so the lift happens where the finger was.
            let moved = valid.filter { contact in touches.contains { $0.id == contact.id } }
            if !moved.isEmpty { merge(moved); onTouches?(touches) }
            touches.removeAll()
        case 6:
            let releasedIndex = (action >> 8) & 255
            let releasedID = contacts.indices.contains(releasedIndex) ? contacts[releasedIndex].id
                : touches.indices.contains(releasedIndex) ? touches[releasedIndex].id : nil
            merge(valid)
            if let releasedID {
                // Report the lift position first, then release that finger.
                onTouches?(touches)
                touches.removeAll { $0.id == releasedID }
            }
        default:
            var seen = Set<Int>()
            touches = valid.filter { seen.insert($0.id).inserted }.map(point)
        }
        onTouches?(touches)
    }

    private func releaseTouches() {
        guard !touches.isEmpty else { return }
        touches.removeAll(); onTouches?([])
    }

    /// Android key codes are the only mapping this transport supplies; unknown keys stay local.
    private static func control(forKey code: Int64) -> CarPlayControl? {
        switch code {
        case 3: .home
        case 4: .back
        case 19, 21: .knobPrevious
        case 20, 22: .knobNext
        case 23, 66: .select
        case 79, 85: .playPause
        case 87: .next
        case 88: .previous
        case 219, 231: .siri
        default: nil
        }
    }

    func close(reason: String) {
        guard active else { return }
        active = false
        log?("会话结束：\(reason)（已发送 \(framesSent) 帧）")
        channels.values.forEach { $0.connection.cancel() }
        channels.removeAll()
        releaseTouches()
    }
}
