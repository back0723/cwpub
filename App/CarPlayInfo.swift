// SPDX-License-Identifier: GPL-3.0-or-later
// Capability profile adapted from PlayPort AirPlayInfoPlist/AirPlayHid.
import Foundation

enum CarPlayInfo {
    static let displayID = "b7e6c5a0-1111-4000-8000-000000000001"
    /// HID device uuids; reports name them in hidSendReport.
    enum HID {
        static let touch = "2a2a2a2a"
        static let knob = "2a2a2a2b"
        static let media = "2a2a2a2c"
        static let telephony = "2a2a2a2d"
    }
    /// Touch slots declared in the descriptor. CarPlay Maps uses two for pinch and rotate.
    static let touchContacts = 2
    private static let displayFeatureKnobs = 0x02
    private static let displayFeatureHighFidelityTouch = 0x08
    static let defaultWidthPhysicalMM = 200

    static func features(audio: Bool) -> UInt64 { audio ? 0x615653aee2 : 0x615653aee2 & ~UInt64(0x10004540a00) }

    /// 设置 → CarPlay → 声音 里的开关「声明 CarPlay 通话能力」。
    /// 关（默认）= 模式A：/info 里既没有 100 telephony 条目，也没有 HID 电话键。
    ///   推理依据：v5.42/43（有电话键、无 telephony）时 0 条音频流；v5.44（电话键 + telephony 完整）
    ///   音乐有声但通话被拉走；本版（电话键 + telephony 输入=0）连音频流都不建。
    ///   三次实测合起来的共同点：**只要声明里出现"电话键"，iPhone 就要求整套通话能力**，
    ///   给不全就整体不建音频图。所以这次把电话键和 telephony 一起摘掉，看 iPhone 是否
    ///   只为媒体/导航建图——那样音乐有声、通话完全留在手机/蓝牙。
    /// 开 = 模式B：完整 telephony(0x70000150/0x70000150) + 电话键。实测音乐有声，
    ///   但通话被拉进 CarPlay，配件没有麦克风 → 通话双方都没声。作为"至少音乐有声"的退路。
    static var telephonyCompat: Bool {
        UserDefaults.standard.object(forKey: "telephonyCompat") as? Bool ?? false
    }
    /// 是否在 /info 里声明通话能力（telephony 条目 + HID 电话键），两者必须同进同退。
    static var declaresTelephony: Bool { telephonyCompat }

    /// 30–60 in steps of 5 (round half up), as the iPhone expects for maxFPS.
    static func sanitizedFPS(_ fps: Int) -> Int {
        let clamped = min(60, max(30, fps))
        return ((clamped - 30) + 2) / 5 * 5 + 30
    }

    static func build(_ config: ReceiverConfiguration) -> [String: Any] {
        let area: [String: Any] = ["widthPixels": config.width, "heightPixels": config.height, "originXPixels": 0, "originYPixels": 0]
        var view = area; var safe = area; safe["drawUIOutsideSafeArea"] = true; view["safeArea"] = safe
        let widthPhysical = config.widthPhysicalMM
        let heightPhysical = max(1, Int((Double(widthPhysical) * Double(config.height) / Double(config.width)).rounded()))
        let display: [String: Any] = ["uuid": displayID, "type": 110, "maxFPS": sanitizedFPS(config.maxFPS),
            "widthPixels": config.width, "heightPixels": config.height,
            "widthPhysical": widthPhysical, "heightPhysical": heightPhysical,
            "features": displayFeatureHighFidelityTouch | displayFeatureKnobs, "primaryInputDevice": 1,
            // 0 = automatic; the live day/night state follows with setNightMode.
            "uiAppearanceMode": 0, "uiAppearanceSetting": 0, "mapAppearanceMode": 0, "mapAppearanceSetting": 0,
            "viewAreas": [view], "initialViewArea": 0]
        let resource: [String: Any] = ["resourceID": 1, "transferType": 1, "transferPriority": 100,
            "takeConstraint": 100, "borrowConstraint": 100, "unborrowConstraint": 100]
        var resources = [resource]
        if config.audioEnabled { var audio = resource; audio["resourceID"] = 2; resources.append(audio) }
        let modes: [String: Any] = ["resources": resources, "appStates": [
            ["appStateID": 2, "state": false], ["appStateID": 1, "speechMode": -1], ["appStateID": 3, "state": false]]]
        var hidDevices = [
            hidDevice(HID.touch, name: "CarWithin 触控屏", descriptor: touchDescriptor(width: config.width, height: config.height)),
            hidDevice(HID.knob, name: "CarWithin 旋钮", descriptor: knobDescriptor),
            hidDevice(HID.media, name: "CarWithin 多媒体键", descriptor: mediaDescriptor)
        ]
        // 电话键只在声明通话能力时才出现。它是 iPhone 判定"这配件能打电话"的入口：
        // 有它就要求整套通话能力（telephony 输入/输出都得全），给不全时 iPhone 干脆一条
        // 音频流都不建（v5.42/43 与大 telephony 输入=0 两版都栽在这）。所以默认不声明，
        // 让 CarPlay 只当"第二块屏 + 扬声器"，通话回到手机本身或车机蓝牙。
        if declaresTelephony {
            hidDevices.append(hidDevice(HID.telephony, name: "CarWithin 电话键", descriptor: telephonyDescriptor))
        }
        var info: [String: Any] = ["sourceVersion": "509.11", "features": NSNumber(value: features(audio: config.audioEnabled)), "statusFlags": 4,
            "model": "CarWithin1,1", "manufacturer": "CarWithin", "deviceID": config.deviceID,
            "bluetoothIDs": [config.deviceID], "name": config.name, "rightHandDrive": config.rightHandDrive,
            "keepAliveLowPower": false, "keepAliveSendStatsAsBody": false, "modes": modes,
            // vocoderInfo 不能省：我们仍声明 default / speechRecognition 这类语音通道的输入输出格式，
            // 少了 vocoderInfo，iPhone 认为配件不懂语音编解码，整个音频图（含 media/alert）都不建，
            // 实测表现为 SETUP 只有 110 视频流、100/101/102 一条都不发，车机全程无声。
            "extendedFeatures": ["vocoderInfo", "enhancedRequestCarUI"],
            "displays": [display], "hidDevices": hidDevices]
        if config.videoCodec == .h265 { info["hevcInfo"] = [String: Any]() }
        if let icon = config.oemIconPNG, let size = vehicleButtonSize(in: config) {
            // The car button on the CarPlay home screen; tapping it sends requestUI.
            info["oemIconVisible"] = true
            info["oemIconLabel"] = config.oemIconLabel
            info["oemIcons"] = [["imageData": icon, "widthPixels": size, "heightPixels": size, "prerendered": true] as [String: Any]]
        }
        if config.audioEnabled {
            // 完整声明 telephony（输入/输出都非零）：这是 iPhone 建立 CarPlay 音频图、发媒体流102、
            // 推送通话流100 的必要条件。通话双向都走 CarPlay WiFi：对方声音送车机通道3、
            // 你的声音由麦克风采集经 dataPort 上行回 iPhone。不回 415（会拆会话卡屏）、
            // 不做来电静音干预（曾卡在恢复分支致挂断后车机哑）。
            // Siri：default / speechRecognition 是无线 CarPlay 音频协商的一部分，保留声明
            //（删了 iPhone 会连一条音乐流都不建），但 App 内没有 Siri 入口、不发 requestSiri。
            var types: [(Int, String)] = [(100,"compatibility"),(101,"compatibility"),(100,"default"),
                (100,"media"),(100,"alert"),(100,"speechRecognition"),(101,"default")]
            var profiles: [(Int, String, Int, Int)] = [
                (100, "compatibility", 0x8854, 0x54),
                (101, "compatibility", 0x8800, 0),
                (100, "default", 0x30000050, 0x30000050),
                (100, "media", 0x8800, 0),
                (100, "alert", 0x40008800, 0),
                (100, "speechRecognition", 0x20000040, 0x20000040),
                (101, "default", 0x40008800, 0),
                // type 102 是无线 CarPlay 的媒体音频通道，不能省：去掉它 iPhone 会直接不发媒体音频。
                // v5.26 试过只声明 PCM(0x8800)，iPhone 连 102 的 SETUP 都不发（日志里只剩「已请求媒体流 110，
                // 音频格式 无」），音乐全留在手机扬声器上，所以声明必须回到 AAC（0xc00000）。
                (102, "media", 0xc00000, 0)]
            // 【模式B，仅在开关打开时】完整声明 telephony（输入/输出都非零）：这是 v5.44 实测
            // "音乐有声"的那份配置，同时也把通话拉进 CarPlay（配件无麦 → 通话双方无声）。
            // 默认（模式A）不写这条，也不发电话键。
            if declaresTelephony {
                types.insert((100, "telephony"), at: 5)
                profiles.insert((100, "telephony", 0x70000150, 0x70000150), at: 5)
            }
            info["audioFormats"] = profiles.map { type, audioType, output, input -> [String: Any] in
                var entry: [String: Any] = ["type": type, "audioType": audioType, "audioOutputFormats": output]
                if input != 0 { entry["audioInputFormats"] = input }
                return entry
            }
            // A type-only latency entry is the fallback for requests without an audioType.
            // Non-zero output latency matches the real prebuffer in CarPlayAudio (40 ms PCM/Opus, 180 ms AAC).
            info["audioLatencies"] = (types + [(102,"media"),(102,"default")]).map { ["type": $0.0, "audioType": $0.1, "inputLatencyMicros": 0, "outputLatencyMicros": $0.0 == 102 ? 200000 : 50000] as [String: Any] }
                + [100, 101, 102].map { ["type": $0, "inputLatencyMicros": 0, "outputLatencyMicros": $0 == 102 ? 200000 : 50000] as [String: Any] }
        }
        return info
    }

    /// 打印给日志看的能力摘要：in/out 都写出来，便于对照 iPhone 到底接受了哪条。
    static func audioFormatSummary(audio: Bool) -> String {
        guard audio else { return "音频未声明" }
        var text = "100 compatibility(0x8854/0x54) · 101 compatibility(0x8800/0) · 100 default(0x30000050/0x30000050)"
            + " · 100 media(0x8800/0) · 100 alert(0x40008800/0)"
        if declaresTelephony {
            text += " · 100 telephony(0x70000150/0x70000150)［兼容模式·通话进 CarPlay］"
        } else {
            text += " · 无电话键、无 telephony［通话不接管，留给手机/蓝牙］"
        }
        return text + " · 100 speechRecognition(0x20000040/0x20000040)"
            + " · 101 default(0x40008800/0) · 102 media(AAC 0xc00000/0)"
    }

    /// Width of a square PNG from its IHDR chunk; nil unless it is square and at most 192 px.
    static func vehicleButtonSize(in config: ReceiverConfiguration) -> Int? {
        guard let png = config.oemIconPNG else { return nil }
        let bytes = [UInt8](png.prefix(24))
        guard bytes.count == 24, bytes[0] == 0x89, bytes[1] == 0x50 else { return nil }
        let width = bytes[16..<20].reduce(0) { $0 << 8 | Int($1) }, height = bytes[20..<24].reduce(0) { $0 << 8 | Int($1) }
        return width == height && (1...192).contains(width) ? width : nil
    }

    private static func hidDevice(_ uuid: String, name: String, descriptor: Data) -> [String: Any] {
        ["hidProductID": 1, "hidVendorID": 2, "hidCountryCode": 0, "uuid": uuid, "name": name,
         "displayUUID": displayID, "hidDescriptor": descriptor]
    }

    // MARK: HID reports

    struct TouchContact { let slot: Int; let x: UInt16; let y: UInt16; let down: Bool }
    /// 6 bytes per slot: [slot, tip, xL, xH, yL, yH]. Slots without a contact report up.
    static func touchReport(_ contacts: [TouchContact]) -> Data {
        var report = Data(count: 6 * touchContacts)
        for slot in 0..<touchContacts {
            let offset = slot * 6
            report[offset] = UInt8(slot)
            guard let contact = contacts.first(where: { $0.slot == slot }) else { continue }
            report[offset + 1] = contact.down ? 1 : 0
            report[offset + 2] = UInt8(truncatingIfNeeded: contact.x); report[offset + 3] = UInt8(truncatingIfNeeded: contact.x >> 8)
            report[offset + 4] = UInt8(truncatingIfNeeded: contact.y); report[offset + 5] = UInt8(truncatingIfNeeded: contact.y >> 8)
        }
        return report
    }
    /// [select | home<<1 | back<<2, x, y, wheel].
    static func knobReport(select: Bool = false, home: Bool = false, back: Bool = false, wheel: Int8 = 0) -> Data {
        Data([(select ? 1 : 0) | (home ? 2 : 0) | (back ? 4 : 0), 0, 0, UInt8(bitPattern: wheel)])
    }
    /// HID 消费类 usage ID（不是数组下标）。0xB0 播放、0xB1 暂停、0xCD 播放/暂停、
    /// 0xB5 下一曲、0xB6 上一曲。
    enum MediaKey: UInt8 { case play = 0xb0, pause = 0xb1, playPause = 0xcd, next = 0xb5, previous = 0xb6 }
    /// Indices into the telephony descriptor's usage array.
    enum TelephonyKey: UInt8 { case hookSwitch = 1, flash = 2, drop = 3, mute = 4 }

    // MARK: HID descriptors

    private static func touchDescriptor(width: Int, height: Int) -> Data {
        let finger: [UInt8] = [0x05,0x0d,0x09,0x22,0xa1,0x02,0x09,0x38,0x75,0x08,0x95,0x01,0x81,0x02,
            0x15,0x00,0x25,0x01,0x09,0x33,0x75,0x01,0x95,0x01,0x81,0x02,0x95,0x07,0x81,0x03,
            0x05,0x01,0x26,UInt8(truncatingIfNeeded: width),UInt8(truncatingIfNeeded: width >> 8),
            0x09,0x30,0x75,0x10,0x95,0x01,0x81,0x02,0x26,UInt8(truncatingIfNeeded: height),UInt8(truncatingIfNeeded: height >> 8),
            0x09,0x31,0x81,0x02,0xc0]
        return Data([0x05,0x0d,0x09,0x04,0xa1,0x01] + Array(repeating: finger, count: touchContacts).flatMap { $0 } + [0xc0])
    }
    /// Multi-axis controller: button 1 = select, consumer AC Home / AC Back, 5 pad bits,
    /// absolute X/Y (unused, kept 0) and a relative wheel for focus movement.
    private static let knobDescriptor = Data([
        0x05,0x01,0x09,0x08,0xa1,0x01,
        0x05,0x09,0x09,0x01,0x15,0x00,0x25,0x01,0x75,0x01,0x95,0x01,0x81,0x02,
        0x05,0x0c,0x0a,0x23,0x02,0x0a,0x24,0x02,0x95,0x02,0x81,0x02,
        0x95,0x05,0x81,0x01,
        0x05,0x01,0x09,0x01,0xa1,0x00,
        0x09,0x30,0x09,0x31,0x15,0x81,0x25,0x7f,0x75,0x08,0x95,0x02,0x81,0x02,0xc0,
        0x09,0x38,0x15,0x81,0x25,0x7f,0x75,0x08,0x95,0x01,0x81,0x06,0xc0])
    /// 消费类控制：1 字节上报，**字节值就是 usage ID**。
    /// 旧写法是"usage 数组 + 0x0000 占位 + 逻辑 0…6"，上报值到底按 0 起还是 1 起解释是含糊的：
    /// 按 0 起算 3 是 0xCD（播放/暂停），按 1 起算是 0xB1（暂停），把占位项剔掉就变成 0xB5（下一曲）。
    /// 实测"暂停后再点播放"被 iPhone 当成下一曲，就是踩在这个含糊上。改成标准写法后值即用法。
    private static let mediaDescriptor = Data([
        0x05,0x0c,0x09,0x01,0xa1,0x01,0x15,0x00,0x26,0xff,0x00,0x19,0x00,0x2a,0xff,0x00,
        0x75,0x08,0x95,0x01,0x81,0x00,0xc0])
    /// Telephony, 1-byte array: none, Hook Switch, Flash, Drop, Mute, keypad 0–9 * #, keyboard delete.
    private static let telephonyDescriptor = Data([
        0x05,0x0b,0x09,0x07,0xa1,0x01,0x15,0x00,0x25,0x11,0x05,0x0b,
        0x09,0x00,0x09,0x20,0x09,0x21,0x09,0x26,0x09,0x2f,
        0x09,0xb0,0x09,0xb1,0x09,0xb2,0x09,0xb3,0x09,0xb4,0x09,0xb5,
        0x09,0xb6,0x09,0xb7,0x09,0xb8,0x09,0xb9,0x09,0xba,0x09,0xbb,
        0x05,0x07,0x09,0x2a,
        0x75,0x08,0x95,0x01,0x81,0x00,0xc0])
}
