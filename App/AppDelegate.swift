import UIKit
import Darwin

/// 缓存日志文件路径（C 字符串），供 signal handler 使用——handler 里不能调 Foundation。
private var crashLogPath: UnsafeMutablePointer<CChar>? = {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let url = dir.appendingPathComponent("ycarwith.log")
    return strdup((url.path as NSString).fileSystemRepresentation)
}()

/// 纯 C 的 signal handler：只 open/write/close，async-signal-safe。
private func carwithSignalHandler(_ code: Int32) {
    guard let path = crashLogPath else { return }
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, mode_t(0o644))
    guard fd >= 0 else { return }
    let header = "\n===== 崩溃信号 \(code) =====\n"
    header.withCString { _ = write(fd, $0, strlen($0)) }
    close(fd)
}

/// 日志持久化：写到 App 沙盒 Documents/ycarwith.log，App 退出/闪退后仍可读取。
/// 最多 500 条轮转；崩溃信号处理器会把最后一段堆栈追加进去，供重启后排查。
final class PersistentLog {
    static let shared = PersistentLog()
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("ycarwith.log")
    }()
    private let lock = NSLock()
    private(set) var lines: [String] = []

    init() {
        load()
        installCrashHandlers()
    }

    private func load() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let all = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        lines = Array(all.suffix(500))
    }

    /// 追加一条；同步落盘，保证闪退前最后一条也留在磁盘上。
    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
        lock.unlock()
    }

    private func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            let reason = exception.reason ?? ""
            let symbols = exception.callStackSymbols.joined(separator: "\n")
            PersistentLog.writeCrash("未捕获异常：\(exception.name.rawValue) \(reason)\n\(symbols)")
        }
        for sig in [SIGABRT, SIGILL, SIGTRAP, SIGBUS, SIGFPE, SIGSEGV] {
            signal(sig, carwithSignalHandler)
        }
    }

    private static func writeCrash(_ text: String) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("ycarwith.log")
        let fd = open((url.path as NSString).fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, mode_t(0o644))
        guard fd >= 0 else { return }
        let line = "\n===== 崩溃 \(Date().description) =====\n\(text)\n"
        line.withCString { _ = write(fd, $0, strlen($0)) }
        close(fd)
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        _ = PersistentLog.shared
        return true
    }
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Receiver", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let navigation = UINavigationController(rootViewController: ReceiverViewController())
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.titleTextAttributes = [.foregroundColor: UIColor.label]
        navigation.navigationBar.standardAppearance = appearance
        navigation.navigationBar.scrollEdgeAppearance = appearance
        navigation.navigationBar.tintColor = .systemBlue
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        self.window = window
    }
}
