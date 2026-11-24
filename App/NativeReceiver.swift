import Foundation
import Network

/// All listener/session state is confined to queue. UI callbacks are always main-thread.
final class NativeReceiver {
    private let queue = DispatchQueue(label: "TDSCarKit.receiver")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var sessions: [UUID: SessionState] = [:]
    /// Access units handed to the main thread but not yet consumed. Over the limit, the local
    /// display skips to the next keyframe instead of dropping arbitrary (dependent) P-frames.
    private var localInFlight = 0
    private var localSkipping = false
    private let maximumLocalInFlight = 12
    #if DEBUG
    private var diagnosticStarted = ProcessInfo.processInfo.systemUptime
    private var diagnosticCPU = TailingPerformanceDiagnostics.cpuTime()
    private var diagnosticFrames = 0, diagnosticBytes = 0
    private var diagnosticPreviousArrival: Double?
    private var diagnosticGap = 0.0, diagnosticWork = 0.0, diagnosticMainDelay = 0.0, diagnosticMainWork = 0.0
    private func recordPerformance(arrival: Double, bytes: Int, work: Double) {
        diagnosticFrames += 1; diagnosticBytes += bytes
        if let previous = diagnosticPreviousArrival { diagnosticGap = max(diagnosticGap, arrival - previous) }
        diagnosticPreviousArrival = arrival; diagnosticWork = max(diagnosticWork, work)
        let elapsed = arrival - diagnosticStarted
        guard elapsed >= 5 else { return }
        let cpu = TailingPerformanceDiagnostics.cpuTime()
        log(String(format: "接收性能：输入 %.1f FPS / %.0f KiB/s，最大帧间隔 %.0f ms，转发最大 %.1f ms，本机队列 %d，主线程排队/处理最大 %.1f/%.1f ms，CPU %.0f%%（单核100%%），热状态 %d，低电量模式 %d",
            Double(diagnosticFrames) / elapsed, Double(diagnosticBytes) / elapsed / 1024,
            diagnosticGap * 1000, diagnosticWork * 1000, localInFlight,
            diagnosticMainDelay * 1000, diagnosticMainWork * 1000,
            (cpu - diagnosticCPU) / elapsed * 100, ProcessInfo.processInfo.thermalState.rawValue,
            ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0))
        diagnosticStarted = arrival; diagnosticCPU = cpu; diagnosticFrames = 0; diagnosticBytes = 0
        diagnosticGap = 0; diagnosticWork = 0; diagnosticMainDelay = 0; diagnosticMainWork = 0
    }
    #endif
    // forceKeyFrame state: throttled sends, resent every second until a keyframe arrives.
    private var keyframeWantedSince: DispatchTime?
    private var keyframeLastSent: DispatchTime?
    /// 只报一次“伴音开关没开”，免得每个音频包都刷日志。
    private var loggedCarLifeAudioBlocked = false
    private var keyframeAttempts = 0
    private var keyframeReason = ""
    private var touchSlots = TouchSlots(count: CarPlayInfo.touchContacts)
    /// 抬起报告是否被压后（见 sendTouch），以及按下时刻/上次日志时刻。
    private var pendingRelease: [CarPlayInfo.TouchContact]?
    private var touchDownAt = 0.0
    private var lastTouchLog = 0.0
    /// 上一次发出的音乐状态，用来决定"播放/暂停"该明确发哪一个键。
    private var assumedPlaying = true
    private var displaySize: (width: Int, height: Int)?
    private var nightMode: Bool?
    /// 主线程：最近一次车机网页上报的真实视口（工具栏收起后的全屏尺寸）。
    private var headUnitScreen: BrowserDisplay?
    /// 浏览器接收页是否在跑；它与 CarPlay 会话解耦，会话停止后页面仍在。
    private var browserRunning = false
    private var browserPort: UInt16?
    private var generation = UUID()
    private var airPlayIdentity: AirPlayCredentials?
    private let videoOutput = VideoOutputServer()
    private let carLife = CarLifeOutput()
    /// 从最近一个 IDR 到当前的全部帧。iPhone 只在会话开始送一个关键帧，之后 forceKeyFrame
    /// 会被 iOS 16 回 408；车机连进来时把这段缓存按顺序回放，就能从第一帧起连续解码。
    private var carLifeGOP: [Data] = []
    private var carLifeGOPBytes = 0
    private var carLifeGOPCodec: VideoCodec = .h264
    private var carLifeParamSets: [Data] = []
    private let carLifeGOPLimit = 12 * 1024 * 1024
    private let zeeho = ZeehoOutput()
    var onZeehoState: ((String) -> Void)?
    private let ninebot = NinebotOutput()
    var onNinebotState: ((String) -> Void)?
    private let tailing = TailingOutput()
    var onTailingState: ((String) -> Void)?
    private lazy var carLink = CarLinkRelay(queue: queue)
    var onCarLifeState: ((String) -> Void)?
    var onCarLinkState: ((String) -> Void)?
    /// Main thread: the primary browser's screen changed.
    var onBrowserDisplay: ((BrowserDisplay?, UUID?) -> Void)?
    /// Main thread: the car page tapped "开始投屏"; the peer is the browser address.
    var onBrowserStart: ((String) -> Void)?
    /// Main thread: the car page asked to reconnect CarPlay at the current window size.
    var onBrowserRefit: ((String) -> Void)?
    /// Main thread: a browser keeps hitching.
    var onBrowserStruggling: ((String, String) -> Void)?
    /// Main thread: the CarPlay car button was tapped (requestUI).
    var onCarUIRequested: (() -> Void)?
    // NetService must be published/stopped on a thread with a run loop (main).
    private var discoveryService: NetService?
    var onLog: ((String) -> Void)?
    var onListening: ((UInt16) -> Void)?
    var onControlConnected: (() -> Void)?
    var onControlDisconnected: (() -> Void)?
    var onVideo: ((Data, VideoCodec) -> Void)?
    var onAirPlayReady: ((UUID) -> Void)?
    var onVideoOutputState: ((String) -> Void)?
    var onFailure: (() -> Void)?

    /// 浏览器接收页在会话启动前就常驻（CarMode 的做法，端口 8787 那一版的等效实现）。
    func startBrowserOnly(_ configuration: ReceiverConfiguration) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let port = configuration.videoOutputPort else { return }
            // 已经在同一端口常驻就不用重启，否则车机页面会白屏重连一次。
            if self.browserRunning, self.browserPort == port { return }
            self.stopOnQueue(keepingBrowser: false)
            self.wireBrowserOutput()
            self.displaySize = (configuration.width, configuration.height)
            self.startVideoOutput(port: port, securePort: configuration.secureVideoOutputPort,
                                  width: configuration.width, height: configuration.height, fps: configuration.maxFPS,
                                  performance: configuration.browserPerformance, showTouches: configuration.showTouches,
                                  preferredViewer: nil, browserAudio: configuration.browserAudio, airPlayStreamID: nil)
            self.log("浏览器接收页已常驻（端口 \(port)），可在车机页面上点“开始投屏”")
        }
    }
    private func startVideoOutput(port: UInt16, securePort: UInt16?, width: Int, height: Int, fps: Int,
                                  performance: BrowserPerformance, showTouches: Bool,
                                  preferredViewer: UUID?, browserAudio: Bool, airPlayStreamID: UUID?) {
        browserRunning = true
        browserPort = port
        videoOutput.start(port: port, securePort: securePort, width: width, height: height, fps: fps,
                          performance: performance, showTouches: showTouches, preferredViewer: preferredViewer,
                          browserAudio: browserAudio, airPlayStreamID: airPlayStreamID)
    }
    private func wireBrowserOutput() {
        videoOutput.onLog = { [weak self] in self?.log($0) }
        videoOutput.onAirPlayReady = { [weak self] id in
            DispatchQueue.main.async { [weak self] in self?.onAirPlayReady?(id) }
        }
        videoOutput.onState = { [weak self] in self?.onVideoOutputState?($0) }
        videoOutput.onKeyframeRequest = { [weak self] in self?.requestKeyFrame(reason: $0) }
        videoOutput.onTouches = { [weak self] source, points in self?.touches(source: source, points) }
        videoOutput.onControl = { [weak self] in self?.press($0) }
        videoOutput.onDisplay = { [weak self] display, viewerID in
            DispatchQueue.main.async {
                guard let self else { return }
                if let display, display.height >= 500,
                   display.width * display.height > (self.headUnitScreen.map { $0.width * $0.height } ?? 0) {
                    // 桌面上也打开接收页时，先接上的小窗口（比如 Edge 1358×610）不能抢走主屏；
                    // 车机 1922×858 面积更大，等它上报后按它建立会话。
                    self.headUnitScreen = display
                }
                self.onBrowserDisplay?(display, viewerID)
            }
        }
        videoOutput.onStruggling = { [weak self] peer, reason in DispatchQueue.main.async { self?.onBrowserStruggling?(peer, reason) } }
        videoOutput.onStartRequest = { [weak self] peer in
            DispatchQueue.main.async { self?.onBrowserStart?(peer) }
        }
        videoOutput.onRefitRequest = { [weak self] peer in
            DispatchQueue.main.async { self?.onBrowserRefit?(peer) }
        }
    }
    func start(configuration: ReceiverConfiguration, identity: AccessoryIdentity, advertise: Bool = true,
               preferredViewer: UUID? = nil) {
        let listening = onListening
        queue.async { [weak self] in
            guard let self else { return }
            // 浏览器接收页常驻（CarMode 的做法）：车机网页在会话启动前就能打开、上报尺寸、
            // 并由页面上的"开始投屏"按钮发起会话，所以这里不能顺手把页面服务一起停掉。
            self.stopOnQueue(keepingBrowser: self.browserRunning)
            self.wireBrowserOutput()
            self.displaySize = (configuration.width, configuration.height)
            if let target = configuration.zeehoAddress {
                let phone = configuration.tailingPhoneInfo ?? TailingPhoneInfo(package: Bundle.main.bundleIdentifier ?? "CarWithin",
                    versionCode: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0,
                    model: "iPhone", systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    width: configuration.width, height: configuration.height, rotation: 1)
                self.zeeho.start(localAddress: configuration.address, targetAddress: target, phone: phone,
                    onState: { [weak self] in self?.onZeehoState?($0) },
                    onLog: { [weak self] in self?.log($0) },
                    requestKeyframe: { [weak self] in self?.requestKeyFrame(reason: "极核解码恢复") })
            }
            if let target = configuration.ninebotAddress {
                self.ninebot.start(localAddress: configuration.address, targetAddress: target,
                    onState: { [weak self] in self?.onNinebotState?($0) },
                    onLog: { [weak self] in self?.log($0) },
                    requestKeyframe: { [weak self] in self?.requestKeyFrame(reason: "九号解码恢复") })
            }
            if let target = configuration.tailingAddress {
                self.tailing.onLog = { [weak self] in self?.log($0) }
                self.tailing.onState = { [weak self] in self?.onTailingState?($0) }
                self.tailing.onKeyframeRequest = { [weak self] in self?.requestKeyFrame(reason: "台铃解码恢复") }
                let phone = configuration.tailingPhoneInfo ?? TailingPhoneInfo(package: Bundle.main.bundleIdentifier ?? "CarWithin",
                    versionCode: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0,
                    model: "iPhone", systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    width: configuration.width, height: configuration.height, rotation: 1)
                self.tailing.start(localAddress: configuration.address, targetAddress: target, phone: phone)
            }
            if configuration.carLifeEnabled {
                self.carLifeGOP = []; self.carLifeGOPBytes = 0; self.carLifeParamSets = []
                self.carLife.onLog = { [weak self] in self?.log($0) }
                self.carLife.onState = { [weak self] in self?.onCarLifeState?($0) }
                self.carLife.onTouches = { [weak self] in self?.touches(source: "carlife", $0) }
                self.carLife.onControl = { [weak self] in self?.press($0) }
                self.carLife.onKeyframeRequest = { [weak self] in self?.requestKeyFrame(reason: $0) }
                self.carLife.onStartFrameNeeded = { [weak self] in self?.sendCachedCarLifeKeyFrame() }
                self.carLife.start(targetAddress: configuration.carLifeAddress, width: configuration.width,
                                   height: configuration.height, fps: configuration.maxFPS)
            }
            if let address = configuration.carLinkRelayAddress {
                self.carLink.onState = { [weak self] status in
                    self?.log(status)
                    DispatchQueue.main.async { [weak self] in self?.onCarLinkState?(status) }
                }
                self.carLink.onTouches = { [weak self] in self?.touches(source: "carlink-relay", $0) }
                self.carLink.onControl = { [weak self] in self?.press($0) }
                self.carLink.onKeyframe = { [weak self] in self?.requestKeyFrame(reason: "CarLink 中继") }
                self.carLink.start(host: address, port: ReceiverConfiguration.carLinkRelayPort, fps: configuration.maxFPS)
            }
            if let port = configuration.videoOutputPort, !self.browserRunning || self.browserPort != port {
                self.startVideoOutput(port: port, securePort: configuration.secureVideoOutputPort,
                                      width: configuration.width, height: configuration.height, fps: configuration.maxFPS,
                                      performance: configuration.browserPerformance, showTouches: configuration.showTouches,
                                      preferredViewer: preferredViewer, browserAudio: configuration.browserAudio,
                                      airPlayStreamID: configuration.airPlayStreamID)
            }
            do { self.airPlayIdentity = advertise ? try AirPlayCredentials() : nil }
            catch { self.fail("AirPlay 身份创建失败：\(error.localizedDescription)"); return }
            if configuration.audioEnabled {
                do {
                    for bits: UInt64 in [0x10000000, 0x20000000, 0x40000000] {
                        let format = try ReceiverAudioFormat(bits: bits)
                        _ = try NativeAudioDecoder(format: format)
                        _ = try NativeOpusEncoder(rate: format.sampleRate)
                    }
                    self.log("原生 Opus 语音编解码器可用（16/24/48 kHz）")
                } catch { self.fail("无线音频编解码器不可用：\(error.localizedDescription)"); return }
            }
            self.log("请求 \(configuration.width)×\(configuration.height) @ \(configuration.maxFPS) FPS，\(configuration.videoCodec.displayName)；音频\(configuration.audioEnabled ? "已启用（PCM/AAC/Opus）" : "已关闭")")
            self.startSessionAfterHeadUnitScreen(configuration: configuration, identity: identity, onReady: listening)
        }
    }
    /// CarMode 的顺序：车机网页先接入并上报全屏尺寸，之后才建 CarPlay 会话。
    /// iPhone 从 /info 里读配件屏幕尺寸，再决定要不要建 110 主屏视频流。我们之前用
    /// 1922×320（宽高比 6:1 的占位值）开局，iPhone 只回 RECORD、从不发视频，车机就一直停在
    /// "正在准备兼容画面"。这里等到网页上报 ≥500 高的真实尺寸，再用它建会话。
    private func startSessionAfterHeadUnitScreen(configuration: ReceiverConfiguration, identity: AccessoryIdentity,
                                                onReady: ((UInt16) -> Void)?) {
        guard configuration.videoOutputPort != nil else {
            listen(configuration: configuration, identity: identity, port: configuration.port, onReady: onReady)
            return
        }
        let generation = self.generation
        let deadline = Date().addingTimeInterval(25)
        // 桌上电脑也开着接收页时，它往往先连上（Edge 1358×610）。给它几秒宽限，等车机
        // 那种大屏（≥1600 宽、≥700 高）上报后再建会话，免得按小窗口的画面尺寸开局。
        let grace = Date().addingTimeInterval(4)
        self.log("等待车机网页上报全屏尺寸后再建立 CarPlay 会话（最多 25 秒；车机先打开接收页会更快）")
        func attempt() {
            guard self.generation == generation else { return }
            let reported = self.headUnitScreen
            if let reported, reported.height >= 500,
               reported.width >= 1600 || Date() > grace {
                var updated = configuration
                updated.width = reported.width; updated.height = reported.height
                self.queue.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.displaySize = (updated.width, updated.height)
                    self.log("车机网页已上报 \(reported.width)×\(reported.height)，开始建立 CarPlay 会话")
                    self.listen(configuration: updated, identity: identity, port: updated.port, onReady: onReady)
                }
                return
            }
            guard Date() < deadline else {
                self.log("未等到车机网页上报尺寸，按 \(configuration.width)×\(configuration.height) 直接建会话")
                self.queue.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.listen(configuration: configuration, identity: identity, port: configuration.port, onReady: onReady)
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { attempt() }
        }
        // headUnitScreen 只在主线程写入，轮询也放主线程，避免跨队列读取。
        DispatchQueue.main.async { attempt() }
    }
    private func listen(configuration: ReceiverConfiguration, identity: AccessoryIdentity, port: UInt16?, onReady: ((UInt16) -> Void)?) {
        let generation = self.generation
        do {
            let candidate = try NWListener(using: .tcp, on: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
            if let airPlayIdentity {
                let features = CarPlayInfo.features(audio: configuration.audioEnabled)
                let txt: [String: String] = ["deviceid": configuration.deviceID,
                    "features": String(format: "0x%x,0x%x", UInt32(truncatingIfNeeded: features), UInt32(truncatingIfNeeded: features >> 32)),
                    "flags": "0x4", "model": "TDSCarKit1,1", "srcvers": "509.11", "protovers": "1.1",
                    "pi": airPlayIdentity.identifier, "pk": airPlayIdentity.signingKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()]
                candidate.service = NWListener.Service(name: configuration.name, type: "_airplay._tcp", txtRecord: NWTXTRecord(txt))
                candidate.serviceRegistrationUpdateHandler = { [weak self] change in self?.log("Bonjour 注册状态：\(change)") }
            }
            listener = candidate
            candidate.stateUpdateHandler = { [weak self, weak candidate] state in
                guard let self, let candidate, self.generation == generation, self.listener === candidate else { return }
                switch state {
                case .ready:
                    guard let actualPort = candidate.port?.rawValue else { self.fail("监听器未获得端口"); return }
                    self.log("原生 RTSP 监听器已在端口 \(actualPort) 就绪")
                    let advertiseDiscovery = self.airPlayIdentity != nil
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if advertiseDiscovery {
                            let service = NetService(domain: "local.", type: ReceiverConfiguration.discoveryType,
                                name: configuration.name, port: Int32(actualPort))
                            service.setTXTRecord(NetService.data(fromTXTRecord: [
                                "app": Data("TDSCarKit".utf8), "deviceid": Data(configuration.deviceID.utf8)]))
                            self.discoveryService?.stop(); self.discoveryService = service; service.publish()
                            self.onLog?("正在通过 \(ReceiverConfiguration.discoveryType) 发布 \(configuration.name)")
                        }
                        onReady?(actualPort)
                    }
                case .failed(let error):
                    if port != nil, case .posix(.EADDRINUSE) = error {
                        self.log("端口 \(port!) 已被占用，正在申请可用端口")
                        candidate.cancel(); self.listener = nil
                        self.listen(configuration: configuration, identity: identity, port: nil, onReady: onReady)
                    } else { self.fail("监听器失败：\(error.localizedDescription)") }
                default: break
                }
            }
            candidate.newConnectionHandler = { [weak self, weak candidate] connection in
                guard let self, self.generation == generation, self.listener === candidate,
                      self.connections.count < 8 else { connection.cancel(); return }
                let id = UUID(); self.connections[id] = connection
                let state = SessionState(credentials: self.airPlayIdentity)
                self.sessions[id] = state
                if case .hostPort(let host, _) = connection.endpoint { state.peerAddress = "\(host)" }
                connection.stateUpdateHandler = { [weak self, weak connection] update in
                    guard let self, let connection else { return }
                    switch update {
                    case .ready:
                        self.log("收到控制连接")
                        DispatchQueue.main.async { [weak self] in self?.onControlConnected?() }
                        self.receive(connection, id: id, state: state, configuration: configuration, identity: identity)
                    case .failed, .cancelled:
                        state.media?.stop(); self.sessions.removeValue(forKey: id); self.connections.removeValue(forKey: id)
                        self.log("CarPlay 控制连接已断开")
                        DispatchQueue.main.async { [weak self] in self?.onControlDisconnected?() }
                    default: break
                    }
                }
                connection.start(queue: self.queue)
            }
            candidate.start(queue: queue)
        } catch let error as NWError {
            if port != nil, case .posix(.EADDRINUSE) = error {
                log("端口 \(port!) 已被占用，正在申请可用端口")
                listen(configuration: configuration, identity: identity, port: nil, onReady: onReady)
            } else { fail("无法创建监听器：\(error.localizedDescription)") }
        } catch { fail("无法创建监听器：\(error)") }
    }
    private func fail(_ message: String) {
        log(message); stopOnQueue()
        DispatchQueue.main.async { [weak self] in self?.onFailure?() }
    }
    /// 只停 CarPlay 会话，浏览器接收页继续常驻（车机那边会退回"开始投屏"）。
    func stop() { queue.async { [weak self] in self?.stopOnQueue(keepingBrowser: true) } }
    /// 连同浏览器接收页一起关掉（关应用、切换输出方式时用）。
    func stopAll() { queue.async { [weak self] in self?.stopOnQueue() } }
    private var activeMedia: CarPlayMediaSession? { sessions.values.first(where: { $0.media != nil })?.media }
    /// All fingers currently held by `source` (normalized 0…1); an empty list releases them.
    func touches(source: String, _ points: [TouchPoint]) {
        queue.async { [weak self] in
            guard let self, let size = self.displaySize else { return }
            let report = self.touchSlots.update(source: source, points: points)
            guard !report.isEmpty else { return }
            let contacts = report.map { entry in
                CarPlayInfo.TouchContact(slot: entry.slot,
                    x: UInt16(clamping: Int((min(max(entry.x, 0), 1) * Double(max(size.width - 1, 0))).rounded())),
                    y: UInt16(clamping: Int((min(max(entry.y, 0), 1) * Double(max(size.height - 1, 0))).rounded())),
                    down: entry.down)
            }
            if contacts.contains(where: { $0.down }),
               let first = contacts.first(where: { $0.down }),
               ProcessInfo.processInfo.systemUptime - self.lastTouchLog > 0.5 {
                self.lastTouchLog = ProcessInfo.processInfo.systemUptime
                self.log("触控按下 (\(first.x),\(first.y)) / \(size.width)×\(size.height)")
            }
            self.sendTouch(contacts)
        }
    }
    /// 按下和抬起之间至少隔 80 ms 再上报。太快的一对报告会被 iOS 当成双击/手势，
    /// 在 CarPlay 的音乐界面上的表现就是"点播放跳到下一曲"。
    private func sendTouch(_ contacts: [CarPlayInfo.TouchContact]) {
        flushPendingRelease()
        guard let media = activeMedia else { return }
        let pressed = contacts.contains { $0.down }
        let now = ProcessInfo.processInfo.systemUptime
        if pressed {
            touchDownAt = now
            media.touch(contacts)
            return
        }
        // 还有手指没抬起来时不做延时，避免把别人的手指一起放掉。
        guard !contacts.isEmpty else { return }
        let elapsed = now - touchDownAt
        let hold = 0.08
        if elapsed < hold {
            pendingRelease = contacts
            queue.asyncAfter(deadline: .now() + (hold - elapsed)) { [weak self] in
                self?.flushPendingRelease()
            }
            return
        }
        media.touch(contacts)
    }
    private func flushPendingRelease() {
        guard let pending = pendingRelease else { return }
        pendingRelease = nil
        activeMedia?.touch(pending)
    }
    func press(_ control: CarPlayControl) {
        queue.async { [weak self] in
            guard let self, let media = self.activeMedia else { self?.log("CarPlay 尚未连接，无法发送「\(control.title)」"); return }
            let knobUp = CarPlayInfo.knobReport()
            switch control {
            case .home: media.pressHID(CarPlayInfo.HID.knob, CarPlayInfo.knobReport(home: true), release: knobUp)
            case .back: media.pressHID(CarPlayInfo.HID.knob, CarPlayInfo.knobReport(back: true), release: knobUp)
            case .select: media.pressHID(CarPlayInfo.HID.knob, CarPlayInfo.knobReport(select: true), release: knobUp)
            case .knobPrevious: media.pressHID(CarPlayInfo.HID.knob, CarPlayInfo.knobReport(wheel: -1), release: knobUp)
            case .knobNext: media.pressHID(CarPlayInfo.HID.knob, CarPlayInfo.knobReport(wheel: 1), release: knobUp)
            case .previous: media.pressHID(CarPlayInfo.HID.media, Data([CarPlayInfo.MediaKey.previous.rawValue]), release: Data([0]))
            case .playPause:
                // 先发标准的"播放/暂停"切换键（usage 0xCD）。描述符已改成"值即 usage"，0xCD 就是播放/暂停，
                // 不再是旧描述符下被解析成下一曲的那个含糊序号。
                media.pressHID(CarPlayInfo.HID.media, Data([CarPlayInfo.MediaKey.playPause.rawValue]), release: Data([0]))
                self.assumedPlaying.toggle()
                self.log("音乐键：播放/暂停")
            case .next: media.pressHID(CarPlayInfo.HID.media, Data([CarPlayInfo.MediaKey.next.rawValue]), release: Data([0]))
            case .siri: media.requestSiri()
            case .hookSwitch: media.pressHID(CarPlayInfo.HID.telephony, Data([CarPlayInfo.TelephonyKey.hookSwitch.rawValue]), release: Data([0]))
            }
        }
    }
    /// Day/night appearance for CarPlay. Remembered across sessions and sent once the event channel is up.
    func setNightMode(_ night: Bool) {
        queue.async { [weak self] in
            guard let self, self.nightMode != night else { return }
            self.nightMode = night
            self.sessions.values.forEach { $0.media?.setNightMode(night) }
        }
    }
    /// Thread-safe entry for decoders (local display, browser viewers) that need a fresh keyframe.
    func requestKeyFrame(reason: String) {
        queue.async { [weak self] in self?.requestKeyFrameOnQueue(reason: reason) }
    }
    /// 车机（CarLife）刚请求画面时调用：把缓存的那段（关键帧开头，一直到当前）按顺序回放，
    /// 车机解码器就能从第一帧起连续解码；不用等 iPhone 再造新关键帧（iOS 16 那条会被 408 拒绝）。
    private func sendCachedCarLifeKeyFrame() {
        queue.async { [weak self] in
            guard let self, !self.carLifeGOP.isEmpty else { return }
            self.log("CarLife：回放缓存的 \(self.carLifeGOP.count) 帧给车机开画")
            self.carLife.replay(self.carLifeGOP, codec: self.carLifeGOPCodec, parameterSets: self.carLifeParamSets)
        }
    }

    private func requestKeyFrameOnQueue(reason: String) {
        let now = DispatchTime.now()
        if keyframeWantedSince == nil { keyframeWantedSince = now; keyframeAttempts = 0; keyframeReason = reason }
        // 250 ms throttle: several viewers recovering together share one request.
        if let last = keyframeLastSent, now.uptimeNanoseconds - last.uptimeNanoseconds < 250_000_000 { return }
        sendKeyFrameRequest()
    }
    private func sendKeyFrameRequest() {
        guard keyframeWantedSince != nil else { return }
        guard let media = sessions.values.first(where: { $0.media?.hasEventChannel == true })?.media else { return }
        keyframeAttempts += 1
        keyframeLastSent = .now()
        guard media.requestKeyFrame() else { return }
        if keyframeAttempts == 1 { log("已请求关键帧（\(keyframeReason)）") }
        guard keyframeAttempts < 8 else {
            log("iPhone 未响应关键帧请求（已重试 \(keyframeAttempts) 次），等待自然关键帧")
            keyframeWantedSince = nil; return
        }
        let run = generation
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.generation == run, self.keyframeWantedSince != nil else { return }
            self.sendKeyFrameRequest()
        }
    }
    private func keyframeArrived() {
        guard let since = keyframeWantedSince else { return }
        keyframeWantedSince = nil
        let ms = (DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1_000_000
        log("关键帧已到达（\(ms) ms，\(keyframeAttempts) 次请求）")
    }
    private static func containsRandomAccess(_ accessUnit: Data, codec: VideoCodec) -> Bool {
        (try? AnnexB.units(in: accessUnit))?.contains { codec.isRandomAccess($0) } ?? false
    }
    private func stopOnQueue(keepingBrowser: Bool = false) {
        DispatchQueue.main.async { [weak self] in self?.discoveryService?.stop(); self?.discoveryService = nil }
        generation = UUID(); listener?.cancel(); listener = nil
        if !keepingBrowser { videoOutput.stop(); browserRunning = false }
        carLife.stop()
        zeeho.stop()
        ninebot.stop()
        tailing.stop()
        carLink.stop()
        #if DEBUG
        diagnosticStarted = ProcessInfo.processInfo.systemUptime
        diagnosticCPU = TailingPerformanceDiagnostics.cpuTime()
        diagnosticFrames = 0; diagnosticBytes = 0; diagnosticPreviousArrival = nil
        diagnosticGap = 0; diagnosticWork = 0; diagnosticMainDelay = 0; diagnosticMainWork = 0
        #endif
        localSkipping = false; keyframeWantedSince = nil; keyframeLastSent = nil; keyframeAttempts = 0
        touchSlots.reset()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        sessions.values.forEach { $0.media?.stop() }; sessions.removeAll()
    }
    private final class SessionState {
        var parser = RTSPParser()
        var authenticated = false
        var setup: PairSetup?
        var verify: PairVerify?
        var cipher: ControlCipher?
        var media: CarPlayMediaSession?
        var peerAddress = ""
        init(credentials: AirPlayCredentials?) {
            if let credentials {
                setup = PairSetup(identifier: credentials.identifier, signingKey: credentials.signingKey) {
                    try credentials.saveController($0, key: $1)
                }
                verify = PairVerify(identifier: credentials.identifier, signingKey: credentials.signingKey) {
                    try? credentials.controller($0)
                }
            }
        }
    }
    private func receive(_ connection: NWConnection, id: UUID, state: SessionState,
                         configuration: ReceiverConfiguration, identity: AccessoryIdentity) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            do {
                if let data, !data.isEmpty {
                    var input = data
                    while true {
                        let plaintext = try state.cipher?.receive(input) ?? input
                        guard let request = try state.parser.append(plaintext, maximumRequests: 1).first else { break }
                        self.log("\(request.method) \(request.target.prefix(100)) [\(request.body.count) 字节]")
                        let response = try self.respond(request, state: state, configuration: configuration, identity: identity)
                        let encoded = response.encoded(for: request)
                        let wire = try state.cipher?.encrypt(encoded) ?? encoded
                        connection.send(content: wire, completion: .contentProcessed { [weak self] error in
                            if let error { self?.log("控制通道写入失败：\(error.localizedDescription)"); connection.cancel() }
                        })
                        input = Data()
                        if state.cipher == nil, let keys = state.verify?.keys {
                            // M4 is plaintext. Only subsequent bytes use the negotiated record keys.
                            state.cipher = ControlCipher(readKey: keys.read, writeKey: keys.write)
                            input = state.parser.takeBufferedData()
                            self.log("Pair-Verify 已通过，已启用加密控制")
                        }
                    }
                }
                if complete || error != nil { connection.cancel(); self.connections.removeValue(forKey: id) }
                else { self.receive(connection, id: id, state: state, configuration: configuration, identity: identity) }
            } catch {
                self.log("控制连接被拒绝：\(error)"); connection.cancel(); self.connections.removeValue(forKey: id)
            }
        }
    }
    private func respond(_ request: RTSPRequest, state: SessionState, configuration: ReceiverConfiguration,
                         identity: AccessoryIdentity) throws -> RTSPResponse {
        switch (request.method, request.target.components(separatedBy: "?")[0]) {
        case ("OPTIONS", _): return RTSPResponse()
        case ("SETUP", _):
            guard state.cipher != nil, state.authenticated, let secret = state.verify?.mediaSecret else {
                throw ProtocolError.malformed("在配件会话通过验证前收到 SETUP")
            }
            if state.media == nil {
                let media = CarPlayMediaSession(queue: queue, secret: secret, peerAddress: state.peerAddress,
                                                audioEnabled: configuration.audioEnabled, hevc: configuration.videoCodec == .h265)
                media.onLog = { [weak self] in self?.log($0) }
                // 原来这里用 configuration.browserAudio 才挂音频回调：JPEG 兼容模式下这个标志
                // 一旦是 false，iPhone 的音频连送都进不来。音频要不要给页面由页面自己点，
                // 这里无条件接住，最多是没客户端要时白白丢掉。
                media.onBrowserAudio = { [weak self] stream, buffer, stamp in
                    self?.videoOutput.appendAudio(buffer, stream: stream, stamp: stamp)
                }
                // CarLife 车机端的伴音：把每一路解码后的 PCM 直接喂给车机的音频模块。
                media.onAudioPCM = { [weak self] _, buffer in
                    guard let self else { return }
                    guard self.configuration.carLifeEnabled, self.configuration.carLifeAudio else {
                        if !self.loggedCarLifeAudioBlocked {
                            self.loggedCarLifeAudioBlocked = true
                            self.log("CarLife 伴音：音频没送去车机（CarLife 模式=\(self.configuration.carLifeEnabled ? "开" : "关")，「随画面传输」=\(self.configuration.carLifeAudio ? "开" : "关")）")
                        }
                        return
                    }
                    self.carLife.appendAudio(buffer)
                }
                media.browserAudioWanted = { [weak self] in self?.videoOutput.hasAudioViewers ?? false }
                if let nightMode { media.setNightMode(nightMode) }
                media.onVideo = { [weak self] data, codec in
                    guard let self else { return }
                    #if DEBUG
                    let diagnosticArrival = ProcessInfo.processInfo.systemUptime
                    defer { self.recordPerformance(arrival: diagnosticArrival, bytes: data.count,
                        work: ProcessInfo.processInfo.systemUptime - diagnosticArrival) }
                    #endif
                    let keyframe = Self.containsRandomAccess(data, codec: codec)
                    if keyframe { self.keyframeArrived() }
                    self.videoOutput.append(data, codec: codec)
                    if configuration.zeehoAddress != nil { self.zeeho.append(data, codec: codec, keyframe: keyframe) }
                    if configuration.ninebotAddress != nil { self.ninebot.append(data, codec: codec, keyframe: keyframe) }
                    if configuration.tailingAddress != nil { self.tailing.append(data, codec: codec) }
                    if configuration.carLifeEnabled {
                        // 只留最近一个 GOP：车机后连时靠它从关键帧起连续解码。
                        if keyframe {
                            self.carLifeGOP = [data]; self.carLifeGOPBytes = data.count
                            self.carLifeGOPCodec = codec
                        } else if self.carLifeGOPBytes + data.count <= self.carLifeGOPLimit, !self.carLifeGOP.isEmpty {
                            self.carLifeGOP.append(data); self.carLifeGOPBytes += data.count
                        }
                        if self.carLifeParamSets.count < 2, let units = try? AnnexB.units(in: data) {
                            // 缓存原始 NAL 单元（SPS/PPS），会话重建后参数集丢失时用它补回来。
                            let sets = units.filter { codec.parameterSet($0) != nil }
                            if sets.count >= 2 { self.carLifeParamSets = sets }
                        }
                        self.carLife.append(data, codec: codec)
                    }
                    if configuration.carLinkRelayAddress != nil { self.carLink.append(data, codec: codec) }
                    if self.localSkipping {
                        guard keyframe, self.localInFlight < self.maximumLocalInFlight / 2 else { return }
                        self.localSkipping = false
                    } else if self.localInFlight >= self.maximumLocalInFlight, !keyframe {
                        self.localSkipping = true
                        self.requestKeyFrameOnQueue(reason: "本机显示积压")
                        return
                    }
                    self.localInFlight += 1
                    DispatchQueue.main.async { [weak self] in
                        #if DEBUG
                        let mainStarted = ProcessInfo.processInfo.systemUptime
                        #endif
                        self?.onVideo?(data, codec)
                        #if DEBUG
                        let mainElapsed = ProcessInfo.processInfo.systemUptime - mainStarted
                        #endif
                        self?.queue.async { [weak self] in
                            if let self {
                                self.localInFlight = max(0, self.localInFlight - 1)
                                #if DEBUG
                                self.diagnosticMainDelay = max(self.diagnosticMainDelay, mainStarted - diagnosticArrival)
                                self.diagnosticMainWork = max(self.diagnosticMainWork, mainElapsed)
                                #endif
                            }
                        }
                    }
                }
                state.media = media
            }
            return RTSPResponse(body: try state.media!.setup(request.body), contentType: "application/x-apple-binary-plist")
        case ("RECORD", _):
            guard state.media != nil else { throw ProtocolError.malformed("在 SETUP 前收到 RECORD") }
            log("已接受 CarPlay RECORD，正在等待视频")
            return RTSPResponse()
        case ("POST", "/pair-setup"):
            guard state.cipher == nil, let setup = state.setup else { throw ProtocolError.malformed("pair-setup 不可用") }
            let fields = try TLV8.decode(request.body)
            log("Pair-Setup 状态 \(fields[6]?.first ?? 0)，方法 \(fields[0]?.first.map(String.init) ?? "缺失")")
            let body = try setup.handle(request.body)
            if setup.complete { log("Pair-Setup 已完成，已保存通过验证的控制端") }
            return RTSPResponse(body: body, contentType: "application/pairing+tlv8")
        case ("POST", "/pair-verify"):
            guard state.cipher == nil, let verify = state.verify else { throw ProtocolError.malformed("pair-verify 不可用") }
            return RTSPResponse(body: try verify.handle(request.body), contentType: "application/pairing+tlv8")
        case ("GET", "/info"), ("POST", "/info"):
            let info = CarPlayInfo.build(configuration)
            return RTSPResponse(body: try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0),
                                contentType: "application/x-apple-binary-plist")
        case ("POST", "/auth-setup"):
            let body = try MFiSAP.respond(to: request.body, identity: identity)
            state.authenticated = true
            log("已生成 MFiSAP 响应，正在等待 iPhone 接受")
            return RTSPResponse(body: body)
        case ("POST", "/feedback"):
            if let feedback = try state.media?.feedback() {
                return RTSPResponse(body: feedback, contentType: "application/x-apple-binary-plist")
            }
            return RTSPResponse()
        case ("POST", "/command"):
            guard state.cipher != nil else { throw ProtocolError.malformed("验证完成前收到 command") }
            if let command = try PropertyListSerialization.propertyList(from: request.body, format: nil) as? [String: Any] {
                let type = command["type"] as? String ?? "未知"
                log("CarPlay 命令：\(type)；字段：\(command.keys.sorted().joined(separator: ", "))")
                if type == "requestUI" {
                    let url = (command["params"] as? [String: Any])?["url"] as? String
                    // "videoplayback:" is the parked-video player, which CarWithin does not offer.
                    if url == nil || url?.hasPrefix("videoplayback") == false {
                        DispatchQueue.main.async { [weak self] in self?.onCarUIRequested?() }
                    }
                }
                if type == "modesChanged", let params = command["params"] as? [String: Any] {
                    for resource in params["resources"] as? [[String: Any]] ?? [] {
                        let fields = ["resourceID", "entity", "permanentEntity"].compactMap { key -> String? in
                            guard let value = resource[key] as? NSNumber else { return nil }
                            return "\(key)=\(value)"
                        }
                        log("CarPlay 资源：\(fields.joined(separator: ", "))")
                    }
                }

            }
            return RTSPResponse()
        case ("TEARDOWN", _):
            if try state.media?.teardown(request.body) == true { state.media = nil }
            return RTSPResponse()
        default:
            log("尚未实现：\(request.method) \(request.target.prefix(80))；未占用会话")
            return RTSPResponse(status: 501, reason: "Not Implemented")
        }
    }
    private func log(_ message: String) { DispatchQueue.main.async { [weak self] in self?.onLog?(message) } }
}
