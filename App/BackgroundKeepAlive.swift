import AVFoundation

/// Keeps CarWithin running after the user leaves the app or locks the phone.
///
/// iOS suspends a backgrounded app about 10 seconds after it stops doing declared background
/// work, which kills the CarPlay session, the browser receiver and every socket. CarPlay audio
/// only runs while the iPhone actually plays sound, and Picture in Picture is not shown on the
/// lock screen. Looping silent audio counts as playback for the `audio` background mode.
///
/// It starts in the foreground before requesting CarPlay and stays active for the session.
/// Waiting for the app to resign active can fail once the virtual CarAudio route is selected.
/// It uses `AVAudioPlayer` rather than a second
/// `AVAudioEngine`: an extra engine that restarted on configuration changes stalled every CarPlay
/// audio stream SETUP for ~8 s and broke the connection. It never changes an audio session
/// category that CarPlay audio or PiP has already chosen.
///
/// The shared audio session is the weak point: when the last CarPlay audio stream ends (a
/// navigation prompt, paused music) `CarPlayAudio` used to deactivate the session, which also
/// stopped this player, and the app was suspended ~10 s later. `CarPlayAudio` now checks
/// `holdsAudioSession` before deactivating, and a watchdog restarts the player if anything
/// else stops it.
final class BackgroundKeepAlive {
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    private var watchdog: Timer?
    private var restarts = 0
    private var lastReviveAt = Date.distantPast
    /// 音频中断（来电/微信/FaceTime）期间为 true。微信 VoIP 不一定把
    /// isOtherAudioPlaying 置 true，光靠那个标志拦不住 revive，必须自己记状态。
    private var interrupted = false
    private(set) var isRunning = false
    var onLog: ((String) -> Void)?

    private static let lock = NSLock()
    private static var holding = false
    /// True while the keep-alive needs the shared audio session active. Read from any queue.
    static var holdsAudioSession: Bool {
        lock.lock(); defer { lock.unlock() }
        return holding
    }
    private static func setHolding(_ value: Bool) { lock.lock(); holding = value; lock.unlock() }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        Self.setHolding(true)
        interrupted = false
        guard play(reason: nil) else { Self.setHolding(false); return false }
        isRunning = true; restarts = 0
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .began {
                    // 来电 / 微信语音 / FaceTime：先暂停，但不放弃音频会话。
                    // 一旦让出，iOS 约 10 秒后就挂起 App，CarLife 与 CarPlay 一起断。
                    self.interrupted = true
                    self.player?.pause()
                    self.onLog?("通话占用了音频，暂停后台保活重试（不抢麦、不碰路由，让手机系统通话稳定进行）")
                    // 仍在 0.8 秒后尝试一次；但 revive() 内会检查 isOtherAudioPlaying，
                    // 通话未结束时直接跳过，避免搅乱手机系统通话的音频会话。通话结束后由"中断结束"事件恢复。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        self?.revive(reason: "通话中断后重试")
                    }
                    return
                }
                // Resume whether or not iOS sets shouldResume: staying silent means being suspended.
                self.interrupted = false
                self.revive(reason: "音频中断结束")
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                // Every player is invalid after a media services reset; build a new one.
                self?.player = nil
                self?.revive(reason: "系统媒体服务重置")
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.isRunning, self.player?.isPlaying != true else { return }
                self.revive(reason: "音频路由变化")
            }
        ]
        // Catches every other way the player can be stopped (session deactivated, category change).
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.isRunning, self.player?.isPlaying != true else { return }
            self.revive(reason: "检测到静音播放已停止")
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        onLog?("后台保持已开启")
        return true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        Self.setHolding(false)
        watchdog?.invalidate(); watchdog = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        player?.stop()
        onLog?("后台保持已关闭")
    }

    private func revive(reason: String) {
        guard isRunning else { return }
        // 【通话期间不抢会话】通话/微信语音占用期间绝不 revive。
        // 旧逻辑在通话中仍 setActive(true)+播静音，会把手机系统通话的会话搅乱、路由改成 Speaker，
        // 进而顶断通话和 CarPlay 会话（22:27:45 DefunctConnection）。本版上行交给手机系统通话，
        // 更要保证 App 不碰它的会话。保住后台是"锦上添花"，冲突时让位给通话。
        // 用自己记的 interrupted 为主判据：微信 VoIP 通话期间 isOtherAudioPlaying 常为 false，
        // 只看它会漏拦。通话中的 revive 会 setActive(true)+播静音，正是顶断会话的元凶。
        if interrupted || AVAudioSession.sharedInstance().isOtherAudioPlaying { return }
        // 事件会成串来（一次路由变化 + 看门狗），节流到 3 秒内最多一次。
        guard Date().timeIntervalSince(lastReviveAt) >= 3 else { return }
        lastReviveAt = Date()
        restarts += 1
        let ok = play(reason: reason)
        // Log the first few and then every 10th so a flapping session cannot flood the log.
        if restarts <= 3 || restarts % 10 == 0 {
            onLog?(ok ? "后台保持已恢复（\(reason)，第 \(restarts) 次）" : "后台保持恢复失败（\(reason)）")
        }
    }

    private func play(reason: String?) -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            if reason == nil {
                onLog?("后台保持准备：类别 \(session.category.rawValue)，模式 \(session.mode.rawValue)，选项 \(session.categoryOptions.rawValue)，路由 \(session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","))")
            }
            if session.category != .playback && session.category != .playAndRecord {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            } else if session.category == .playback && !session.categoryOptions.contains(.mixWithOthers) {
                // CarPlay playback may have selected this category without mixing. Silent
                // keep-alive must not request exclusive audio focus from the source iPhone.
                try session.setCategory(.playback, mode: session.mode,
                                        options: session.categoryOptions.union(.mixWithOthers))
            }
            try session.setActive(true)
            let player = try player ?? AVAudioPlayer(data: Self.silentWAV)
            player.numberOfLoops = -1
            player.volume = 0
            self.player = player
            guard player.play() else {
                self.player = nil
                if reason == nil {
                    onLog?("后台保持开启失败：系统拒绝播放（类别 \(session.category.rawValue)，模式 \(session.mode.rawValue)，选项 \(session.categoryOptions.rawValue)，路由 \(session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","))）")
                }
                return false
            }
            return true
        } catch {
            if reason == nil { onLog?("后台保持开启失败：\(error.localizedDescription)") }
            return false
        }
    }

    /// One second of 8 kHz mono 16-bit silence.
    private static let silentWAV: Data = {
        let rate: UInt32 = 8_000, samples = rate
        let dataBytes = samples * 2
        var wav = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        wav.append(Data(count: Int(dataBytes)))
        return wav
    }()

    deinit { stop() }
}
