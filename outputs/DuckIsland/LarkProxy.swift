import Cocoa
import Combine
import SwiftUI

// MARK: - Lark targets

let larkBundleIDs: Set<String> = ["com.larksuite.larkApp", "com.bytedance.lark", "com.electron.lark"]
func isLarkTarget(_ target: ScreenTarget) -> Bool { larkBundleIDs.contains(target.bundleID) }

// MARK: - Models

struct LarkChat: Identifiable, Equatable { let id: String; let name: String; let isP2P: Bool }
struct LarkMessage: Identifiable, Equatable {
    let id: String
    let chatID: String
    let text: String
    let time: Date
    let senderID: String
    let senderIDType: String
    let senderName: String
    let senderType: String
    let msgType: String
    let mentionIDs: [String]
    let deleted: Bool
}
struct LarkError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Bounded process runner

private final class LarkPipeBuffer: @unchecked Sendable {
    private let lock = NSLock(); private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// Runs a process with a hard timeout. Output is collected through readability handlers (never a blocking read), the
/// child tree is killed on timeout, and pipes are drained non-blockingly and closed, so a grandchild that keeps a pipe
/// open cannot hang the caller. Returns nil when the executable cannot be launched.
func larkRunProcess(executable: String, arguments: [String], timeout: TimeInterval) -> (status: Int32, out: Data, err: Data, timedOut: Bool)? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    let extra = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/node/bin"]
    environment["PATH"] = (extra + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
    process.environment = environment
    let out = Pipe(), err = Pipe()
    process.standardOutput = out; process.standardError = err; process.standardInput = FileHandle.nullDevice
    let outBuffer = LarkPipeBuffer(), errBuffer = LarkPipeBuffer()
    for (pipe, buffer) in [(out, outBuffer), (err, errBuffer)] {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { buffer.append(chunk) }
        }
    }
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    do { try process.run() } catch {
        out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
        try? out.fileHandleForReading.close(); try? err.fileHandleForReading.close()
        return nil
    }
    var timedOut = false
    if done.wait(timeout: .now() + timeout) == .timedOut {
        timedOut = true
        let pid = process.processIdentifier
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killer.arguments = ["-KILL", "-P", String(pid)]
        try? killer.run(); killer.waitUntilExit()
        process.terminate()
        if done.wait(timeout: .now() + 1) == .timedOut { kill(pid, SIGKILL); _ = done.wait(timeout: .now() + 1) }
    }
    for (pipe, buffer) in [(out, outBuffer), (err, errBuffer)] {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = nil
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true { let n = read(fd, &chunk, chunk.count); if n <= 0 { break }; buffer.append(Data(chunk[0..<n])) }
        try? handle.close()
    }
    return (process.isRunning ? -1 : process.terminationStatus, outBuffer.value, errBuffer.value, timedOut)
}

// MARK: - Reply sanitising

/// Strips constructs that lark-cli would act on (mentions of everyone, remote images, links) and caps the length.
func larkSanitizeReply(_ text: String) -> String {
    var result = text
    let rules: [(String, String)] = [
        (#"<at\b[^>]*>.*?</at\s*>"#, ""),
        (#"<at\b[^>]*/?>"#, ""),
        (#"!\[[^\]]*\]\([^)]*\)"#, ""),
        (#"https?://[^\s<>)\]]+"#, "（链接已省略）"),
    ]
    for (pattern, replacement) in rules {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
        result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
    }
    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
    return result.count > 500 ? String(result.prefix(500)) : result
}

/// Process-wide count of auto-send attempts per chat (survives chat switches and re-attach).
@MainActor final class LarkSendLedger {
    static let shared = LarkSendLedger()
    private var stamps: [String: [Date]] = [:]
    func count(chat: String, now: Date, window: TimeInterval = 600) -> Int {
        stamps[chat] = (stamps[chat] ?? []).filter { now.timeIntervalSince($0) <= window }
        return stamps[chat]?.count ?? 0
    }
    func record(chat: String, now: Date) { stamps[chat, default: []].append(now) }
}

// MARK: - lark-cli wrapper

/// Runs `lark-cli` with the given arguments (without the executable) and returns stdout. Injectable for tests.
typealias LarkRunner = @Sendable (_ arguments: [String]) async throws -> Data

/// Maps raw CLI output to a short Chinese status; never includes credentials.
func larkFriendlyError(_ raw: String) -> String {
    let text = raw.lowercased()
    if text.contains("expired") || text.contains("not logged") || text.contains("login") || text.contains("unauthorized") || text.contains("token") {
        return "lark-cli 登录已失效，请在终端执行 lark-cli auth login"
    }
    if text.contains("permission") || text.contains("scope") || text.contains("forbidden") { return "lark-cli 权限不足，请检查授权范围" }
    if text.contains("rate") && text.contains("limit") { return "飞书请求过于频繁，稍后重试" }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
    return trimmed.isEmpty ? "lark-cli 出错，请重试" : "lark-cli 出错：" + String(trimmed.prefix(80))
}

func larkParseTime(_ text: String) -> Date? {
    for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current; formatter.dateFormat = format
        if let date = formatter.date(from: text) { return date }
    }
    return ISO8601DateFormatter().date(from: text)
}
func larkFormatISO(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter(); formatter.timeZone = .current
    return formatter.string(from: date)
}
func larkFloorMinute(_ date: Date) -> Date { Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60) }

struct LarkCLI {
    let run: LarkRunner

    /// Real runner: 30s timeout, stdout returned, stderr only used to build a Chinese error.
    static func process(executable: String, timeout: TimeInterval = 30) -> LarkCLI {
        LarkCLI(run: { arguments in
            try await Task.detached { try runBlocking(executable: executable, arguments: arguments, timeout: timeout) }.value
        })
    }
    private static func runBlocking(executable: String, arguments: [String], timeout: TimeInterval) throws -> Data {
        guard let result = larkRunProcess(executable: executable, arguments: arguments, timeout: timeout) else { throw LarkError(message: "无法运行 lark-cli，请检查路径") }
        if result.timedOut { throw LarkError(message: "lark-cli 响应超时（\(Int(timeout)) 秒）") }
        guard result.status == 0 else {
            let raw = String(decoding: result.err.isEmpty ? result.out : result.err, as: UTF8.self)
            throw LarkError(message: larkFriendlyError(larkErrorText(raw)))
        }
        return result.out
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw LarkError(message: "无法解析 lark-cli 输出") }
        if root["ok"] as? Bool == false { throw LarkError(message: larkFriendlyError(larkErrorText(String(decoding: data, as: UTF8.self)))) }
        return root
    }
    private func payload(_ data: Data) throws -> [String: Any] { (try object(data))["data"] as? [String: Any] ?? [:] }

    func authStatus() async throws -> LarkAuthStatus { LarkAuthStatus.parse(try await run(["auth", "status", "--json"])) }
    /// open_id of the logged-in user: `auth status` -> identities.user.openId.
    func currentUserID() async throws -> String {
        let data = try await run(["auth", "status", "--json"])
        let status = LarkAuthStatus.parse(data)
        guard status.loggedIn else { throw LarkError(message: status.message) }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let user = (root?["identities"] as? [String: Any])?["user"] as? [String: Any]
        guard let id = user?["openId"] as? String, !id.isEmpty else { throw LarkError(message: "无法获取当前用户，请重新登录 lark-cli") }
        return id
    }
    private func chats(_ data: Data) throws -> [LarkChat] {
        let list = (try payload(data))["chats"] as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let id = item["chat_id"] as? String, !id.isEmpty else { return nil }
            let mode = (item["chat_mode"] as? String ?? "").lowercased()
            return LarkChat(id: id, name: item["name"] as? String ?? "", isP2P: mode == "p2p")
        }
    }
    func recentChats(limit: Int = 100) async throws -> [LarkChat] {
        try chats(try await run(["im", "+chat-list", "--as", "user", "--types=p2p,group", "--sort=active_time", "--page-size=" + String(min(max(limit, 1), 100)), "--format=json"]))
    }
    func searchChats(_ query: String) async throws -> [LarkChat] {
        try chats(try await run(["im", "+chat-search", "--as", "user", "--query=" + query, "--page-size=20", "--format=json"]))
    }
    private func messages(_ data: Data) throws -> (items: [LarkMessage], more: Bool, token: String?) {
        let body = try payload(data)
        let list = body["messages"] as? [[String: Any]] ?? []
        let items: [LarkMessage] = list.compactMap { item in
            guard let id = item["message_id"] as? String, let time = larkParseTime(item["create_time"] as? String ?? "") else { return nil }
            let sender = item["sender"] as? [String: Any] ?? [:]
            let mentions = (item["mentions"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            return LarkMessage(id: id, chatID: item["chat_id"] as? String ?? "", text: item["content"] as? String ?? "", time: time,
                               senderID: sender["id"] as? String ?? "", senderIDType: sender["id_type"] as? String ?? "", senderName: sender["name"] as? String ?? "",
                               senderType: sender["sender_type"] as? String ?? "", msgType: item["msg_type"] as? String ?? "",
                               mentionIDs: mentions, deleted: item["deleted"] as? Bool ?? false)
        }
        return (items, body["has_more"] as? Bool ?? false, body["page_token"] as? String)
    }
    /// Messages at or after `since` (minute resolution), oldest first. Follows up to 4 pages.
    func messages(chatID: String, since: Date) async throws -> [LarkMessage] {
        var result: [LarkMessage] = []
        var token: String?
        for _ in 0..<4 {
            var args = ["im", "+chat-messages-list", "--as", "user", "--chat-id=" + chatID, "--start=" + larkFormatISO(since), "--order=asc", "--page-size=50", "--no-reactions", "--format=json"]
            if let token { args.append("--page-token=" + token) }
            let page = try messages(try await run(args))
            result += page.items
            guard page.more, let next = page.token, !next.isEmpty else { break }
            token = next
        }
        return result
    }
    /// Latest messages (oldest first) used as reply context.
    func recentMessages(chatID: String, limit: Int = 20) async throws -> [LarkMessage] {
        let page = try messages(try await run(["im", "+chat-messages-list", "--as", "user", "--chat-id=" + chatID, "--order=desc", "--page-size=" + String(limit), "--no-reactions", "--format=json"]))
        return Array(page.items.reversed())
    }
    /// Sends with `--text=` (never --markdown: lark-cli would fetch remote images and parse <at>). Returns the new message id if reported.
    @discardableResult
    func reply(messageID: String, text: String, idempotencyKey: String) async throws -> String? {
        let root = try object(try await run(["im", "+messages-reply", "--as", "user", "--message-id=" + messageID, "--text=" + text, "--idempotency-key=" + idempotencyKey, "--format=json"]))
        func find(_ value: Any?) -> String? {
            if let dict = value as? [String: Any] {
                if let id = dict["message_id"] as? String { return id }
                for child in dict.values { if let id = find(child) { return id } }
            }
            return nil
        }
        return find(root["data"])
    }
}

/// Extracts `error.message` from a lark-cli JSON error envelope when present.
func larkErrorText(_ raw: String) -> String {
    if let data = raw.data(using: .utf8), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       let error = root["error"] as? [String: Any] {
        return [error["type"], error["subtype"], error["message"]].compactMap { $0 as? String }.joined(separator: " ")
    }
    return raw
}

/// "mo-" + message id, kept within lark-cli's 50-character limit.
func larkIdempotencyKey(_ messageID: String) -> String { "mo-" + String(messageID.suffix(47)) }

// MARK: - Chat detection

enum LarkChatMatch: Equatable { case matched(LarkChat), ambiguous([LarkChat]), none }

private func larkNormalize(_ text: String) -> String { text.lowercased().filter { !$0.isWhitespace } }

/// Longest chat name contained in any OCR line wins; equally long distinct candidates are ambiguous.
func larkMatchChat(ocrLines: [String], chats: [LarkChat]) -> LarkChatMatch {
    let lines = ocrLines.map(larkNormalize).filter { !$0.isEmpty }
    var hits: [(LarkChat, Int)] = []
    for chat in chats {
        let name = larkNormalize(chat.name)
        guard name.count >= 2, lines.contains(where: { $0.contains(name) }) else { continue }
        hits.append((chat, name.count))
    }
    guard let best = hits.map(\.1).max() else { return .none }
    let top = hits.filter { $0.1 == best }.map(\.0)
    var unique: [LarkChat] = []
    for chat in top where !unique.contains(where: { $0.id == chat.id }) { unique.append(chat) }
    return unique.count == 1 ? .matched(unique[0]) : .ambiguous(unique)
}

let larkOCRRegion = CGRect(x: 0.3, y: 0, width: 0.7, height: 0.14)

/// OCR of the right-hand conversation header band (x 0.3-1.0, top 14%), one string per line.
func larkDetectChatLines(_ target: ScreenTarget) async throws -> [String] {
    let (png, _) = try await captureScreenWindow(target, purpose: .ocr)
    let result = try recognizeScreenRegion(png: png, region: larkOCRRegion)
    return result.text.split(separator: "\n").map(String.init)
}

// MARK: - Reply context

/// JSON context for `moLarkReply`: up to 20 recent messages and the one being answered. Chat text is untrusted data.
func larkReplyContext(chat: LarkChat, me: String, history: [LarkMessage], target: LarkMessage) -> String {
    func clip(_ text: String) -> String { text.count > 500 ? String(text.prefix(500)) + "…" : text }
    let recent = history.suffix(20).map { ["from": $0.senderID == me ? "我" : ($0.senderName.isEmpty ? "对方" : $0.senderName), "text": clip($0.text)] }
    let object: [String: Any] = ["chat": chat.name, "chatType": chat.isP2P ? "私聊" : "群聊", "recentMessages": recent,
                                 "messageToReply": ["from": target.senderName.isEmpty ? "对方" : target.senderName, "text": clip(target.text)]]
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    return "\n" + String(decoding: data, as: UTF8.self)
}

// MARK: - Session

enum LarkReplyState: Equatable {
    case recorded, recordedEarly, generating, draft, sending, sentAuto, sentManual, failed(String), discarded, skipped(String)
    var label: String {
        switch self {
        case .recorded: return "仅记录"
        case .recordedEarly: return "仅记录（attach 当分钟内的消息不自动回复）"
        case .skipped(let reason): return reason
        case .generating: return "生成回复中…"
        case .draft: return "草稿待发"
        case .sending: return "发送中…"
        case .sentAuto: return "已自动回复"
        case .sentManual: return "已发送"
        case .failed(let reason): return reason
        case .discarded: return "已丢弃"
        }
    }
}
struct LarkProxyRecord: Identifiable, Equatable {
    let id: String
    let sender: String
    let time: Date
    let text: String
    var state: LarkReplyState
    var draft = ""
}

@MainActor final class LarkProxyPanels: OrbitPanels {
    weak var session: LarkProxySession? { didSet { configure() } }
    override init() { super.init(); configure() }
    private func configure() {
        toolbarTitle = "代发呼吸灯"; recordTitle = "代发记录"
        isActive = { [weak self] in self?.session?.active == true }
        makeOrbit = { [weak self] _ in
            guard let session = self?.session else { return AnyView(EmptyView()) }
            return AnyView(LarkProxyOrbitView(session: session))
        }
        makeRecord = { [weak self] in
            guard let session = self?.session else { return AnyView(EmptyView()) }
            return AnyView(LarkProxyRecordView(session: session))
        }
    }
}

@MainActor final class LarkProxySession: ObservableObject {
    var panels = LarkProxyPanels()
    @Published var active = false
    @Published var target: ScreenTarget?
    @Published var chat: LarkChat?
    @Published var needsPicker = false
    @Published var chats: [LarkChat] = []
    @Published var searchResults: [LarkChat] = []
    @Published var records: [LarkProxyRecord] = []
    @Published var status = ""
    @Published var lastPoll: Date?
    @Published var paused = false
    @Published var generating = false

    // Injection points (tests replace all of them; production defaults are below).
    var makeCLI: () -> LarkCLI? = {
        guard let path = LarkCLIDetector.resolve(manual: LarkProxySettings.cliPath) else { return nil }
        return LarkCLI.process(executable: path)
    }
    var resolveFrame: (ScreenTarget) async throws -> CGRect = { try await resolveScreenWindow($0).frame }
    var detectLines: (ScreenTarget) async throws -> [String] = larkDetectChatLines
    var generate: (String) async throws -> String = { context in
        let cancellation = SaveCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached { try moLarkReply(context: context, cancellation: cancellation) }.value
        } onCancel: { cancellation.cancel() }
    }
    var now: () -> Date = { Date() }
    var autoReplyEnabled: () -> Bool = { LarkProxySettings.autoReply }
    var maxReplies: () -> Int = { LarkProxySettings.maxRepliesPer10Min }
    var pollInterval: () -> TimeInterval = { LarkProxySettings.pollInterval }
    var autoStart = true
    var ledger = LarkSendLedger.shared
    /// Auto-send stays off until the user confirms an auto-detected conversation (manual picker selection confirms).
    @Published var confirmed = false

    private var cli: LarkCLI?
    private var me = ""
    private var baseline = Date.distantFuture
    private var cursor = Date.distantFuture
    private var seen = Set<String>()
    private var ownSent = Set<String>()
    private var token = UUID()
    private var trackFailures = 0
    private var tracking: Timer?
    private var pollTask: Task<Void, Never>?
    private var polling = false

    init() { panels.session = self }

    var visibleChats: [LarkChat] { searchResults.isEmpty ? chats : searchResults }
    var headline: String { "代发 · " + (chat?.name ?? "未选择会话") }
    var autoReplyOn: Bool { autoReplyEnabled() && !paused }

    func attach(_ item: ScreenTarget, note: String) async -> Bool {
        guard !active else { status = "请先结束当前代发"; return false }
        guard let cli = makeCLI() else { status = "未找到 lark-cli，请在设置中填写路径"; return false }
        let frame: CGRect
        do { frame = try await resolveFrame(item) } catch { status = error.localizedDescription; return false }
        do { me = try await cli.currentUserID() } catch { status = (error as? LarkError)?.message ?? error.localizedDescription; return false }
        self.cli = cli
        token = UUID()
        target = item; active = true; trackFailures = 0
        chat = nil; needsPicker = false; chats = []; searchResults = []; records = []; paused = false; status = "正在识别会话…"; lastPoll = nil
        tracking?.invalidate()
        if autoStart {
            tracking = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in Task { @MainActor in await self?.track() } }
        }
        panels.position(frame)
        let current = token
        if autoStart { Task { await detectChat(token: current) } }   // tests drive detectChat() themselves
        return true
    }

    /// Loads recent chats, OCRs the window title area and picks the conversation, else asks the user.
    func detectChat(token current: UUID? = nil) async {
        let current = current ?? token
        guard active, let cli, let target else { return }
        do { chats = try await cli.recentChats() } catch {
            guard current == token else { return }
            status = message(error); needsPicker = true; return
        }
        guard current == token else { return }
        let lines = (try? await detectLines(target)) ?? []
        guard current == token, chat == nil else { return }
        switch larkMatchChat(ocrLines: lines, chats: chats) {
        case .matched(let found): select(found, confirmed: false)
        case .ambiguous(let options): chats = options + chats.filter { c in !options.contains(where: { $0.id == c.id }) }; needsPicker = true; status = "请选择会话"
        case .none: needsPicker = true; status = "没有识别到会话，请选择会话"
        }
    }

    func showPicker() {
        guard active else { return }
        needsPicker = true; searchResults = []
        if chats.isEmpty, let cli {
            let current = token
            Task { if let list = try? await cli.recentChats(), current == token { chats = list } }
        }
    }
    func search(_ query: String) async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cli, !text.isEmpty else { searchResults = []; return }
        let current = token
        do { let found = try await cli.searchChats(text); if current == token { searchResults = found; if found.isEmpty { status = "没有找到匹配的会话" } } }
        catch { if current == token { status = message(error) } }
    }

    /// Starts watching a conversation. Only messages after this moment are handled; history is never answered.
    func select(_ item: LarkChat, confirmed confirm: Bool = true) {
        guard active else { return }
        token = UUID()
        pollTask?.cancel(); pollTask = nil
        chat = item; needsPicker = false; searchResults = []
        records = []; seen = []; ownSent = []; generating = false; confirmed = confirm
        baseline = larkFloorMinute(now()); cursor = baseline
        status = "已选择会话，等待新消息"
        guard autoStart else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self {
                await self.pollOnce()
                let seconds = LarkProxySettings.clampPoll(self.pollInterval())
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    func confirmChat() { if chat != nil { confirmed = true } }
    func pollNow() { Task { await pollOnce() } }

    func pollOnce() async {
        guard active, let cli, let chat, !polling else { return }
        polling = true; defer { polling = false }
        let current = token
        do {
            let fetched = try await cli.messages(chatID: chat.id, since: cursor)
            guard current == token else { return }
            lastPoll = now()
            status = ""
            await ingest(fetched, chat: chat, cli: cli, token: current)
        } catch {
            guard current == token else { return }
            lastPoll = now()
            status = message(error)
        }
    }

    private func ingest(_ fetched: [LarkMessage], chat: LarkChat, cli: LarkCLI, token current: UUID) async {
        var qualifying: [LarkMessage] = []
        for item in fetched.sorted(by: { $0.time < $1.time }) {
            guard seen.insert(item.id).inserted else { continue }
            cursor = max(cursor, item.time)
            guard item.time >= baseline, !item.deleted, item.msgType != "system", item.senderID != me, !ownSent.contains(item.id) else { continue }
            let early = item.time <= baseline   // sent within the attach minute: cannot tell whether it predates attach
            let qualifies = !early && item.senderIDType == "open_id" && item.senderType == "user" && ["text", "post"].contains(item.msgType) && (chat.isP2P || item.mentionIDs.contains(me))
            records.append(LarkProxyRecord(id: item.id, sender: item.senderName.isEmpty ? "对方" : item.senderName, time: item.time, text: item.text, state: qualifies ? .generating : (early ? .recordedEarly : .recorded)))
            if records.count > 100 { records.removeFirst(records.count - 100) }
            if qualifies { qualifying.append(item) }
        }
        // One reply per sender per poll: only the latest qualifying message is answered.
        var latest: [String: String] = [:]
        for item in qualifying { latest[item.senderID] = item.id }
        for item in qualifying where latest[item.senderID] != item.id { update(item.id) { $0.state = .skipped("已合并") } }
        for item in qualifying where latest[item.senderID] == item.id {
            guard current == token else { return }
            await respond(to: item, chat: chat, cli: cli, token: current)
        }
    }

    private func respond(to item: LarkMessage, chat: LarkChat, cli: LarkCLI, token current: UUID) async {
        generating = true
        defer { generating = false }
        let history = (try? await cli.recentMessages(chatID: chat.id)) ?? []
        guard current == token else { return }
        let text: String
        do { text = larkSanitizeReply(try await generate(larkReplyContext(chat: chat, me: me, history: history, target: item))) } catch {
            guard current == token else { return }
            update(item.id) { $0.state = .failed("生成回复失败：" + message(error)) }
            return
        }
        guard current == token else { return }
        update(item.id) { $0.draft = text; $0.state = .draft }
        // Auto-send gates: setting/pause, user confirmation, freshness, per-chat rate limit, and nobody replied meanwhile.
        guard autoReplyOn, confirmed, !text.isEmpty, now().timeIntervalSince(item.time) <= 300,
              ledger.count(chat: chat.id, now: now()) < maxReplies() else { return }
        guard let latestHistory = try? await cli.recentMessages(chatID: chat.id), current == token else { return }
        if latestHistory.contains(where: { $0.senderID == me && $0.id != item.id && !ownSent.contains($0.id) && $0.time >= item.time }) {
            update(item.id) { $0.state = .skipped("你已回复，跳过"); $0.draft = "" }
            return
        }
        await send(item.id, auto: true)
    }

    private func update(_ id: String, _ change: (inout LarkProxyRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
    }
    func setDraft(_ id: String, _ text: String) { update(id) { if $0.state == .draft || $0.state.isFailed { $0.draft = text } } }

    /// Sends the (possibly edited) draft as a reply. Failed records can be retried; the idempotency key prevents duplicates.
    func send(_ id: String, auto: Bool = false) async {
        guard let cli, let chat, let record = records.first(where: { $0.id == id }), record.state == .draft || record.state.isFailed else { return }
        let text = larkSanitizeReply(record.draft)
        guard !text.isEmpty else { update(id) { $0.state = .failed("回复为空，无法发送") }; return }
        let current = token
        update(id) { $0.state = .sending; $0.draft = text }
        if auto { ledger.record(chat: chat.id, now: now()) }   // every automatic attempt counts, success or not
        do {
            let sent = try await cli.reply(messageID: id, text: text, idempotencyKey: larkIdempotencyKey(id))
            if let sent { ownSent.insert(sent) }
            guard current == token else { return }
            update(id) { $0.state = auto ? .sentAuto : .sentManual }
        } catch {
            guard current == token else { return }
            update(id) { $0.state = .failed("发送失败：" + message(error)) }
        }
    }
    func discard(_ id: String) {
        update(id) { if $0.state == .draft || $0.state.isFailed { $0.state = .discarded; $0.draft = "" } }
    }
    func togglePaused() { paused.toggle(); status = paused ? "已暂停自动回复，新回复将存为草稿" : "" }

    private func message(_ error: Error) -> String { (error as? LarkError)?.message ?? (error as? NotesFailure)?.detail ?? error.localizedDescription }

    func track() async {
        guard active, let target else { return }
        let current = token
        do {
            let frame = try await resolveFrame(target)
            guard current == token, self.target == target else { return }
            trackFailures = 0
            let visible = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []).contains { ($0[kCGWindowNumber as String] as? UInt32) == target.id }
            if visible { panels.position(frame) } else { panels.hideForWorkspace() }
        } catch {
            guard current == token, self.target == target else { return }
            trackFailures += 1
            guard trackFailures >= 2 else { return }
            _ = await end()
        }
    }

    func end() async -> Bool {
        token = UUID()
        tracking?.invalidate(); tracking = nil
        pollTask?.cancel(); pollTask = nil
        panels.close()
        active = false; target = nil; chat = nil; needsPicker = false; chats = []; searchResults = []; records = []
        status = ""; lastPoll = nil; paused = false; generating = false; cli = nil; seen = []; ownSent = []; confirmed = false
        return true
    }
}

extension LarkReplyState {
    var isFailed: Bool { if case .failed = self { return true }; return false }
}

// MARK: - Views

struct LarkProxyOrbitView: View {
    @ObservedObject var session: LarkProxySession
    @Environment(\.colorScheme) private var colorScheme
    @State private var dragStart: (anchor: CGPoint, mouse: CGPoint)?
    @GestureState private var isDragging = false
    private var ringColor: Color { colorScheme == .dark ? Color(red: 0.69, green: 0.86, blue: 0.97) : Color(red: 0.35, green: 0.52, blue: 0.68) }
    var body: some View {
        ZStack {
            Button { session.showPicker() } label: {
                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(colorScheme == .dark ? Color(red: 0.77, green: 0.93, blue: 0.89) : Color(red: 0.13, green: 0.47, blue: 0.39))
                    .background(colorScheme == .dark ? Color(red: 0.18, green: 0.27, blue: 0.29) : Color(red: 0.92, green: 0.98, blue: 0.96), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
            }.accessibilityLabel("选择或切换会话").help("选择或切换会话")
                .position(x: 37, y: 105).zIndex(1)
            Button { session.pollNow() } label: {
                MoOrb(ringColor: ringColor, busy: session.generating, listening: false)
            }.accessibilityLabel("立即检查新消息").help("点击立即检查新消息；拖动移动呼吸灯")
                .highPriorityGesture(DragGesture(minimumDistance: 6).updating($isDragging) { _, state, _ in state = true }.onChanged { value in
                    let mouse = NSEvent.mouseLocation
                    if dragStart == nil { dragStart = (session.panels.orbAnchor, CGPoint(x: mouse.x - value.translation.width, y: mouse.y + value.translation.height)) }
                    if let origin = dragStart { session.panels.moveOrb(to: CGPoint(x: origin.anchor.x + mouse.x - origin.mouse.x, y: origin.anchor.y + mouse.y - origin.mouse.y)) }
                }.onEnded { _ in dragStart = nil })
                .onChange(of: isDragging) { if !isDragging { dragStart = nil } }
                .contextMenu {
                    Button("立即检查") { session.pollNow() }
                    Button("切换会话") { session.showPicker() }
                    Divider()
                    Button("结束并撤下") { Task { _ = await session.end() } }
                }.position(x: 64, y: 84)
            Button { session.togglePaused() } label: {
                Image(systemName: session.autoReplyOn ? "paperplane.fill" : "pause.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(session.autoReplyOn ? Color(red: 0.08, green: 0.45, blue: 0.94) : Color(red: 0.30, green: 0.35, blue: 0.39), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
            }.help(session.paused ? "已暂停自动回复；点击恢复" : "点击暂停自动回复（新回复存为草稿）")
                .accessibilityLabel(session.paused ? "恢复自动回复" : "暂停自动回复")
                .position(x: 91, y: 105)
        }.frame(width: 128, height: 124).buttonStyle(.plain)
    }
}

struct LarkChatPicker: View {
    @ObservedObject var session: LarkProxySession
    @State private var query = ""
    private var rows: [LarkChat] {
        let base = session.visibleChats
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? base : base.filter { $0.name.localizedCaseInsensitiveContains(text) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("搜索会话，回车在飞书中查找", text: $query).textFieldStyle(.roundedBorder).font(.system(size: 12))
                .onSubmit { Task { await session.search(query) } }
            if rows.isEmpty { Text("没有匹配的会话").font(.system(size: 11)).foregroundStyle(IslandStyle.secondary).padding(.vertical, 6) }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(rows) { chat in
                        Button { session.select(chat) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: chat.isP2P ? "person" : "person.2").font(.system(size: 11)).frame(width: 16)
                                Text(chat.name.isEmpty ? "（未命名）" : chat.name).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 2)
                            }.padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct LarkProxyRecordView: View {
    @ObservedObject var session: LarkProxySession
    private func color(_ state: LarkReplyState) -> Color {
        switch state {
        case .sentAuto, .sentManual: return Color.green
        case .draft, .generating, .sending: return Color.orange
        case .failed: return Color.red
        case .recorded, .recordedEarly, .discarded, .skipped: return IslandStyle.secondary
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(session.headline).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 2)
                Text(session.autoReplyOn ? "自动回复 开" : (session.paused ? "已暂停" : "自动回复 关"))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(session.autoReplyOn ? Color.green : IslandStyle.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Color.white.opacity(0.1), in: Capsule())
            }
            Divider().overlay(IslandStyle.line)
            if let chat = session.chat, !session.confirmed, !session.needsPicker {
                Button("确认代发 · " + chat.name) { session.confirmChat() }.buttonStyle(PrimaryActionStyle())
                Text("确认前，新回复只存为草稿，不会自动发送。").font(.system(size: 10)).foregroundStyle(IslandStyle.secondary)
            }
            if session.needsPicker || session.chat == nil { LarkChatPicker(session: session) }
            else if session.records.isEmpty {
                Text("等待新消息…").font(.system(size: 11)).foregroundStyle(IslandStyle.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(session.records.reversed()) { record in recordRow(record) }
                    }
                }
            }
            footer
        }.padding(10).buttonStyle(.plain).modifier(IslandSurface())
    }
    private func recordRow(_ record: LarkProxyRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(record.sender).font(.system(size: 11, weight: .medium))
                Text(record.time.formatted(date: .omitted, time: .shortened)).font(.system(size: 10, design: .monospaced)).foregroundStyle(IslandStyle.secondary)
                Spacer(minLength: 2)
                Text(record.state.label).font(.system(size: 10)).foregroundStyle(color(record.state)).lineLimit(1)
            }
            Text(record.text.count > 80 ? String(record.text.prefix(80)) + "…" : record.text).font(.system(size: 11)).foregroundStyle(IslandStyle.secondary).lineLimit(2)
            if record.state == .draft || record.state.isFailed {
                TextEditor(text: Binding(get: { session.records.first(where: { $0.id == record.id })?.draft ?? "" }, set: { session.setDraft(record.id, $0) }))
                    .font(.system(size: 11)).scrollContentBackground(.hidden).padding(3)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6)).frame(height: 44)
                HStack(spacing: 8) {
                    Spacer(minLength: 2)
                    Button("丢弃") { session.discard(record.id) }.font(.system(size: 11)).foregroundStyle(IslandStyle.secondary)
                    Button("发送") { Task { await session.send(record.id) } }.font(.system(size: 11, weight: .medium)).foregroundStyle(Color.blue)
                }
            } else if record.state == .sentAuto || record.state == .sentManual || record.state == .sending {
                if !record.draft.isEmpty { Text("小墨：" + record.draft).font(.system(size: 11)).lineLimit(2) }
            }
        }
    }
    private var footer: some View {
        HStack(spacing: 6) {
            if session.generating { ProgressView().controlSize(.mini) }
            Text(footerText).font(.system(size: 10)).foregroundStyle(session.status.isEmpty || session.status.hasPrefix("已选择") ? IslandStyle.secondary : Color.orange).lineLimit(2)
            Spacer(minLength: 2)
        }
    }
    private var footerText: String {
        let poll = session.lastPoll.map { "上次轮询 " + $0.formatted(date: .omitted, time: .standard) } ?? "尚未轮询"
        return session.status.isEmpty ? poll : session.status + (session.lastPoll == nil ? "" : " · " + poll)
    }
}
