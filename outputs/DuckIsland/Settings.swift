import Cocoa
import SwiftUI

// MARK: - Lark proxy shared settings (read by the Lark proxy session as well)

enum LarkProxySettings {
    static let autoReplyKey = "larkProxyAutoReply"
    static let maxRepliesKey = "larkProxyMaxRepliesPer10Min"
    static let pollIntervalKey = "larkProxyPollInterval"
    static let cliPathKey = "larkProxyCLIPath"
    static let defaultAutoReply = true
    static let defaultMaxReplies = 3
    static let defaultPollInterval: TimeInterval = 15
    static let pollRange: ClosedRange<TimeInterval> = 10...120
    static let maxRepliesRange: ClosedRange<Int> = 1...30

    static func clampPoll(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultPollInterval }
        return min(max(value, pollRange.lowerBound), pollRange.upperBound)
    }
    static func clampReplies(_ value: Int) -> Int { min(max(value, maxRepliesRange.lowerBound), maxRepliesRange.upperBound) }

    static var autoReply: Bool {
        get { UserDefaults.standard.object(forKey: autoReplyKey) as? Bool ?? defaultAutoReply }
        set { UserDefaults.standard.set(newValue, forKey: autoReplyKey) }
    }
    static var maxRepliesPer10Min: Int {
        get { clampReplies(UserDefaults.standard.object(forKey: maxRepliesKey) as? Int ?? defaultMaxReplies) }
        set { UserDefaults.standard.set(clampReplies(newValue), forKey: maxRepliesKey) }
    }
    static var pollInterval: TimeInterval {
        get { clampPoll(UserDefaults.standard.object(forKey: pollIntervalKey) as? Double ?? defaultPollInterval) }
        set { UserDefaults.standard.set(clampPoll(newValue), forKey: pollIntervalKey) }
    }
    static var cliPath: String? {
        get {
            let value = UserDefaults.standard.string(forKey: cliPathKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        set {
            let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value.isEmpty { UserDefaults.standard.removeObject(forKey: cliPathKey) } else { UserDefaults.standard.set(value, forKey: cliPathKey) }
        }
    }
}

// MARK: - lark-cli detection and auth status probe (read-only)

struct LarkAuthStatus: Equatable {
    var loggedIn: Bool
    var identity: String
    var brand: String
    var userName: String
    var message: String
    static let unknown = LarkAuthStatus(loggedIn: false, identity: "", brand: "", userName: "", message: "尚未检测")

    /// Parses `lark-cli auth status --json`. Only non-secret fields are read; tokens are never exposed.
    static func parse(_ data: Data) -> LarkAuthStatus {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return LarkAuthStatus(loggedIn: false, identity: "", brand: "", userName: "", message: "无法解析 lark-cli 输出")
        }
        let identity = root["identity"] as? String ?? ""
        let brand = root["brand"] as? String ?? ""
        let user = (root["identities"] as? [String: Any])?["user"] as? [String: Any]
        let available = user?["available"] as? Bool ?? false
        let token = user?["tokenStatus"] as? String ?? ""
        let valid = available && (token.isEmpty || token == "valid" || token == "needs_refresh")
        let name = user?["userName"] as? String ?? ""
        let message = valid ? "已登录" : (token == "expired" ? "登录已过期，请在终端执行 lark-cli auth login" : "未登录，请在终端执行 lark-cli auth login")
        return LarkAuthStatus(loggedIn: valid, identity: identity, brand: brand, userName: name, message: message)
    }
}

enum LarkCLIDetector {
    static func candidates(home: String = NSHomeDirectory(), path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> [String] {
        let fixed = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/node/bin", home + "/.local/bin", home + "/.npm-global/bin"]
        var seen = Set<String>(); var result: [String] = []
        for dir in fixed + path.split(separator: ":").map(String.init) where !dir.isEmpty {
            let full = dir + "/lark-cli"
            if seen.insert(full).inserted { result.append(full) }
        }
        return result
    }
    static func detect(isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        candidates().first(where: isExecutable)
    }
    /// Manual path wins when it is executable; otherwise fall back to auto-detection.
    static func resolve(manual: String?, isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        if let manual, !manual.isEmpty { return isExecutable(manual) ? manual : nil }
        return detect(isExecutable: isExecutable)
    }
}

typealias LarkProbeRunner = (_ executable: String, _ arguments: [String]) -> (status: Int32, output: Data)

enum LarkAuthProbe {
    /// Real runner: blocking, 10s timeout. Only used with the read-only `auth status` command.
    static let processRunner: LarkProbeRunner = { executable, arguments in
        guard let result = larkRunProcess(executable: executable, arguments: arguments, timeout: 10) else { return (-1, Data()) }
        return (result.timedOut ? -1 : result.status, result.out)
    }
    static func status(executable: String, runner: LarkProbeRunner = processRunner) -> LarkAuthStatus {
        let result = runner(executable, ["auth", "status", "--json"])
        if result.status == -1 && result.output.isEmpty { return LarkAuthStatus(loggedIn: false, identity: "", brand: "", userName: "", message: "无法运行 lark-cli") }
        var status = LarkAuthStatus.parse(result.output)
        if result.status != 0 && !status.loggedIn && status.identity.isEmpty && status.brand.isEmpty { status.message = "lark-cli 返回错误（\(result.status)）" }
        return status
    }
}

// MARK: - Window

enum SettingsSection: String, CaseIterable { case general, live, meeting, lark }

@MainActor final class SettingsNavigator: ObservableObject {
    @Published var target: SettingsSection?
}

@MainActor final class SettingsWindow: NSObject {
    static let shared = SettingsWindow()
    static let contentSize = CGSize(width: 520, height: 640)
    weak var model: Recorder?
    private(set) var window: NSWindow?
    let navigator = SettingsNavigator()
    private var liveOverride: MoLiveSession?

    static func screen(containing point: NSPoint, in screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main ?? screens.first
    }
    static func centeredFrame(size: CGSize, in visible: CGRect) -> CGRect {
        CGRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(), width: size.width, height: size.height)
    }

    func makeWindowIfNeeded() -> NSWindow {
        if let window { return window }
        let live = liveOverride ?? model?.review.live
        let host = NSHostingView(rootView: SettingsRoot(model: model, live: live, navigator: navigator))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: Self.contentSize), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Mo · 墨 设置"
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.setContentSize(Self.contentSize)
        window.contentMinSize = Self.contentSize
        self.window = window
        return window
    }

    /// Centres on the visibleFrame of the screen containing `mouse`; called on every show.
    @discardableResult func recenter(mouse: NSPoint = NSEvent.mouseLocation, screens: [NSScreen] = NSScreen.screens) -> CGRect? {
        guard let window, let screen = Self.screen(containing: mouse, in: screens) else { return nil }
        let size = window.frame.size
        let frame = Self.centeredFrame(size: size, in: screen.visibleFrame)
        window.setFrame(frame, display: true)
        return frame
    }

    func show(section: SettingsSection? = nil, live: MoLiveSession? = nil, mouse: NSPoint = NSEvent.mouseLocation, activate: Bool = true) {
        if let live, live !== liveOverride {
            liveOverride = live
            window?.close(); window = nil   // rebuild so the content observes the right session
        }
        let window = makeWindowIfNeeded()
        recenter(mouse: mouse)
        navigator.target = section
        if activate { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Content

@MainActor final class LarkProbeModel: ObservableObject {
    @Published var status = LarkAuthStatus.unknown
    @Published var detected: String?
    @Published var checking = false
    static var defaultRunner: LarkProbeRunner = LarkAuthProbe.processRunner   // tests inject a fake
    var runner: LarkProbeRunner = LarkProbeModel.defaultRunner
    func refresh(manual: String?) {
        guard !checking else { return }
        checking = true
        let runner = self.runner
        Task {
            let result: (String?, LarkAuthStatus) = await Task.detached {
                guard let path = LarkCLIDetector.resolve(manual: manual) else {
                    return (nil, LarkAuthStatus(loggedIn: false, identity: "", brand: "", userName: "", message: "未找到 lark-cli，请安装或手动填写路径"))
                }
                return (path, LarkAuthProbe.status(executable: path, runner: runner))
            }.value
            detected = result.0; status = result.1; checking = false
        }
    }
}

struct SettingsRoot: View {
    let model: Recorder?
    let live: MoLiveSession?
    @ObservedObject var navigator: SettingsNavigator
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                SettingsContent(model: model, live: live).padding(20)
            }
            .onChange(of: navigator.target) { _, target in
                if let target { withAnimation { proxy.scrollTo(target, anchor: .top) } }
            }
        }.frame(width: SettingsWindow.contentSize.width, height: SettingsWindow.contentSize.height)
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            content
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }
}

struct SettingsContent: View {
    let model: Recorder?
    let live: MoLiveSession?
    @StateObject private var placeholderLive = MoLiveSession()   // keeps the form observing something when no session is injected
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: "通用", symbol: "keyboard") {
                shortcut("⌥⇧ Enter", "唤起 Mo")
                shortcut("⌥ Enter", "当前工作主操作")
                shortcut("⌥ E", "结束当前工作")
                shortcut("小墨小墨", "唤醒词")
            }.id(SettingsSection.general)
            SettingsCard(title: "GPT-Live", symbol: "waveform") {
                MoLiveSettingsForm(live: live ?? placeholderLive)
            }.id(SettingsSection.live)
            SettingsCard(title: "会议", symbol: "person.2") {
                if let model { MeetingSettingsForm(model: model) }
            }.id(SettingsSection.meeting)
            #if !APP_STORE
            SettingsCard(title: "Lark 代发", symbol: "paperplane") { LarkSettingsForm() }.id(SettingsSection.lark)
            #endif
        }
    }
    private func shortcut(_ key: String, _ label: String) -> some View {
        HStack { Text(label).font(.system(size: 12)); Spacer(); Text(key).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary) }
    }
}

/// GPT-Live settings (moved from the chat popover). Keychain and proxy behaviour are unchanged.
struct MoLiveSettingsForm: View {
    @ObservedObject var live: MoLiveSession
    @State private var key = ""
    @State private var notice = ""
    @State private var proxyURL = UserDefaults.standard.string(forKey: MoLiveNetwork.proxyKey) ?? ""
    private var busy: Bool { live.active }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("gpt-live-1 · Marin\n填写自己的 OpenAI API Key，保存在本机钥匙串。开始后语音会发送至 OpenAI，按 API 用量计费。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("OpenAI API Key", text: $key).textFieldStyle(.roundedBorder).disabled(busy)
            Button("从 ~/.config/env 导入") {
                do { _ = try MoLiveKeychain.importEnvironment(); notice = "已导入钥匙串" } catch { notice = error.localizedDescription }
            }.disabled(busy)
            TextField("HTTP 代理（可选，如 http://127.0.0.1:7897）", text: $proxyURL).textFieldStyle(.roundedBorder).disabled(busy)
            if !notice.isEmpty { Text(notice).font(.system(size: 11)).foregroundStyle(.secondary) }
            HStack {
                Button("删除密钥") { do { try MoLiveKeychain.remove(); notice = "已删除" } catch { notice = error.localizedDescription } }.disabled(busy)
                Spacer()
                Button("保存") {
                    do {
                        _ = try MoLiveNetwork.proxyDictionary(proxyURL)
                        if !key.isEmpty { try MoLiveKeychain.save(key); key = "" }
                        UserDefaults.standard.set(proxyURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: MoLiveNetwork.proxyKey)
                        notice = "设置已保存"
                    } catch { notice = error.localizedDescription }
                }.disabled(busy)
            }
            if busy { Text("请先结束对话再修改凭据。").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }
}

struct MeetingSettingsForm: View {
    @ObservedObject var model: Recorder
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            #if !APP_STORE
            Toggle("结束后生成 AI 总结", isOn: Binding(get: { model.automaticSummary }, set: { model.setAutomaticSummary($0) }))
            Text("开启时会确认授权；关闭后不发送会议文字。").font(.system(size: 12)).foregroundStyle(.secondary)
            #else
            Text("会议文字保存在本机，可同步到备忘录。").font(.system(size: 13))
            #endif
        }
    }
}

struct LarkSettingsForm: View {
    @StateObject private var probe = LarkProbeModel()
    @AppStorage(LarkProxySettings.autoReplyKey) private var autoReply = LarkProxySettings.defaultAutoReply
    @AppStorage(LarkProxySettings.maxRepliesKey) private var maxReplies = LarkProxySettings.defaultMaxReplies
    @AppStorage(LarkProxySettings.pollIntervalKey) private var poll = LarkProxySettings.defaultPollInterval
    @State private var path = LarkProxySettings.cliPath ?? ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(probe.detected ?? "lark-cli 路径（留空自动探测）", text: $path).textFieldStyle(.roundedBorder)
                    .onSubmit { commitPath() }
                    .onChange(of: path) { commitPath() }
                Button("重新检测") { commitPath(); probe.refresh(manual: LarkProxySettings.cliPath) }.disabled(probe.checking)
            }
            if let detected = probe.detected { Text("使用：" + detected).font(.system(size: 11)).foregroundStyle(.secondary) }
            HStack(spacing: 6) {
                if probe.checking { ProgressView().controlSize(.small) }
                else { Image(systemName: probe.status.loggedIn ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(probe.status.loggedIn ? Color.green : Color.orange) }
                Text(statusLine).font(.system(size: 12))
            }
            Divider()
            Toggle("被 @ 或私聊时自动回复", isOn: $autoReply)
            Stepper(value: $maxReplies, in: LarkProxySettings.maxRepliesRange) {
                Text("每会话 10 分钟内最多自动回复 \(LarkProxySettings.clampReplies(maxReplies)) 条").font(.system(size: 12))
            }
            Stepper(value: $poll, in: LarkProxySettings.pollRange, step: 5) {
                Text("轮询间隔 \(Int(LarkProxySettings.clampPoll(poll))) 秒（10–120）").font(.system(size: 12))
            }
            Text("开启代发后，私聊和 @ 你的消息及最近 20 条上下文会发送给本机 Codex 生成回复。").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("以你本人身份通过 lark-cli 发送；凭据由 lark-cli 管理，Mo 不读取也不保存。").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .onAppear { probe.refresh(manual: LarkProxySettings.cliPath) }
    }
    private var statusLine: String {
        let s = probe.status
        if probe.checking { return "检测中…" }
        guard s.loggedIn || !s.identity.isEmpty || !s.brand.isEmpty else { return s.message }
        var parts = [s.message]
        if !s.identity.isEmpty { parts.append("身份 " + s.identity + (s.userName.isEmpty ? "" : "（\(s.userName)）")) }
        if !s.brand.isEmpty { parts.append("品牌 " + s.brand) }
        return parts.joined(separator: " · ")
    }
    private func commitPath() { LarkProxySettings.cliPath = path }
}
