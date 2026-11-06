// Lark proxy: chat detection, polling, auto-reply rules, drafts, errors, capability. All lark-cli calls go through an injected fake runner; nothing real is sent.
import Cocoa
import SwiftUI
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

final class FakeLark: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var _messages: [[String: Any]] = []
    private var _error: String?
    private var _replyError: String?
    private var _sentCount = 0
    private var _replyRaw: Data?
    private var _onRecent: ((Int) -> Void)?
    private var _recentCount = 0
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
    var replies: [[String]] { calls.filter { $0.count > 1 && $0[1] == "+messages-reply" } }
    func setMessages(_ value: [[String: Any]]) { lock.lock(); _messages = value; lock.unlock() }
    func setError(_ value: String?) { lock.lock(); _error = value; lock.unlock() }
    func setReplyRaw(_ value: Data?) { lock.lock(); _replyRaw = value; lock.unlock() }
    func setOnRecent(_ value: ((Int) -> Void)?) { lock.lock(); _onRecent = value; _recentCount = 0; lock.unlock() }
    func setReplyError(_ value: String?) { lock.lock(); _replyError = value; lock.unlock() }
    static let me = "ou_me"
    static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    static func msg(_ id: String, _ text: String, at time: String, from sender: String = "ou_other", type: String = "user", idType: String = "open_id", mentions: [String] = [], kind: String = "text") -> [String: Any] {
        var m: [String: Any] = ["message_id": id, "chat_id": "oc_chat", "content": text, "create_time": time, "deleted": false, "msg_type": kind,
                                "sender": ["id": sender, "id_type": idType, "name": sender == me ? "我" : "小李", "sender_type": type]]
        if !mentions.isEmpty { m["mentions"] = mentions.enumerated().map { ["id": $1, "key": "@_user_\($0 + 1)", "name": "x"] } }
        return m
    }
    var cli: LarkCLI {
        LarkCLI(run: { [self] args in
            lock.lock(); _calls.append(args); let error = _error; let replyError = _replyError; let messages = _messages; _sentCount += args.count > 1 && args[1] == "+messages-reply" ? 1 : 0; let sentN = _sentCount; lock.unlock()
            if args[0] == "auth" { return Self.json(["identity": "user", "brand": "lark", "identities": ["user": ["available": true, "tokenStatus": "valid", "openId": Self.me, "userName": "Me"]]]) }
            if args.count > 1, args[1] == "+chat-messages-list", !args.contains(where: { $0.hasPrefix("--start=") }) {
                lock.lock(); _recentCount += 1; let n = _recentCount; let hook = _onRecent; lock.unlock()
                hook?(n)
            }
            lock.lock(); let raw = _replyRaw; lock.unlock()
            if let raw, args.count > 1, args[1] == "+messages-reply" { return raw }
            if let replyError, args.count > 1, args[1] == "+messages-reply" { throw LarkError(message: replyError) }
            if let error { throw LarkError(message: error) }
            switch args[1] {
            case "+chat-list": return Self.json(["ok": true, "data": ["chats": [["chat_id": "oc_chat", "chat_mode": "p2p", "name": "小李"], ["chat_id": "oc_group", "chat_mode": "group", "name": "Mo 项目群"], ["chat_id": "oc_g2", "chat_mode": "group", "name": "Mo 设计群"]], "has_more": false]])
            case "+chat-search": return Self.json(["ok": true, "data": ["chats": [["chat_id": "oc_s", "chat_mode": "DEFAULT", "name": "搜索结果"]]]])
            case "+chat-messages-list": return Self.json(["ok": true, "data": ["messages": messages, "has_more": false]])
            case "+messages-reply": return Self.json(["ok": true, "data": ["message_id": "om_sent_\(sentN)"]])
            default: throw LarkError(message: "unexpected \(args)")
            }
        })
    }
}

Task { @MainActor in
    let dest = CommandLine.arguments[1]
    typealias F = FakeLark
    let p2p = LarkChat(id: "oc_chat", name: "小李", isP2P: true)
    let group = LarkChat(id: "oc_group", name: "Mo 项目群", isP2P: false)
    let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"; formatter.timeZone = .current
    let attachTime = formatter.date(from: "2026-11-06 08:30:40")!
    let lark = ScreenTarget(id: 5, pid: -1, app: "Lark", bundleID: "com.larksuite.larkApp", title: "Lark")
    let other = ScreenTarget(id: 6, pid: -1, app: "Safari", bundleID: "com.apple.Safari", title: "x")

    // --- capability ---
    precondition(duckCapabilities(for: lark).first == .larkProxy && duckCapabilities(for: lark) == [.larkProxy, .review, .ocr])
    precondition(!duckCapabilities(for: other).contains(.larkProxy))
    for id in ["com.bytedance.lark", "com.electron.lark"] { precondition(isLarkTarget(ScreenTarget(id: 1, pid: -1, app: "飞书", bundleID: id, title: ""))) }
    precondition(DuckCapability.larkProxy.special && DuckCapability.larkProxy.title == "代发")

    // --- chat detection ---
    let chats = [p2p, group, LarkChat(id: "oc_g2", name: "Mo 设计群", isP2P: false), LarkChat(id: "oc_x", name: "A", isP2P: false)]
    precondition(larkMatchChat(ocrLines: ["搜索", "Mo 项目群", "12 人"], chats: chats) == .matched(group))
    precondition(larkMatchChat(ocrLines: ["mo项目群 (外部)"], chats: chats) == .matched(group), "case/space-insensitive, contained")
    precondition(larkMatchChat(ocrLines: ["小李 · 在线"], chats: chats) == .matched(p2p))
    if case .ambiguous(let options) = larkMatchChat(ocrLines: ["Mo 项目群", "Mo 设计群"], chats: chats) { precondition(Set(options.map(\.id)) == ["oc_group", "oc_g2"]) } else { preconditionFailure("equal-length names are ambiguous") }
    precondition(larkMatchChat(ocrLines: ["Mo 项目群 Mo 设计群"], chats: chats) != .none)
    precondition(larkMatchChat(ocrLines: ["完全无关", "A"], chats: chats) == .none, "names shorter than 2 are ignored")
    precondition(larkMatchChat(ocrLines: [], chats: chats) == .none)
    precondition(larkMatchChat(ocrLines: ["Mo 项目群新"], chats: [group, LarkChat(id: "oc_l", name: "Mo 项目群新", isP2P: false)]) == .matched(LarkChat(id: "oc_l", name: "Mo 项目群新", isP2P: false)), "longest wins")

    // --- helpers ---
    var generated: [String] = []
    var generatorFails = false
    @MainActor func makeSession(_ fake: FakeLark, chat: LarkChat? = nil, auto: Bool = true, max: Int = 3, lines: [String] = [], ledger: LarkSendLedger? = nil, now: Date? = nil) async -> LarkProxySession {
        let s = LarkProxySession()
        s.autoStart = false
        s.makeCLI = { fake.cli }
        s.resolveFrame = { _ in CGRect(x: 100, y: 100, width: 900, height: 620) }
        s.detectLines = { _ in lines }
        s.now = { now ?? attachTime }
        s.ledger = ledger ?? LarkSendLedger()
        s.autoReplyEnabled = { auto }
        s.maxReplies = { max }
        s.generate = { context in
            generated.append(context)
            if generatorFails { struct E: Error {}; throw E() }
            return "好的，收到"
        }
        let attached = await s.attach(lark, note: "")
        precondition(attached)
        if let chat { s.select(chat) }
        return s
    }
    let history = F.msg("om_old", "昨天的消息", at: "2026-11-06 08:29")

    // --- detection through the session ---
    do {
        let fake = FakeLark()
        let s = await makeSession(fake, lines: ["Lark", "Mo 项目群"])
        await s.detectChat()
        precondition(s.chat == group && !s.needsPicker && s.chats.count == 3 && !s.confirmed, "detected, unconfirmed")
        let s2 = await makeSession(fake, lines: ["Mo 项目群", "Mo 设计群"])
        await s2.detectChat()
        precondition(s2.chat == nil && s2.needsPicker, "ambiguous -> picker")
        let s3 = await makeSession(fake, lines: ["nothing"])
        await s3.detectChat()
        precondition(s3.chat == nil && s3.needsPicker && !s3.status.isEmpty)
        await s3.search("搜")
        precondition(s3.searchResults.map(\.name) == ["搜索结果"] && s3.visibleChats.first?.id == "oc_s")
        s3.select(s3.searchResults[0]); precondition(s3.chat?.id == "oc_s" && !s3.needsPicker && s3.confirmed, "manual pick confirms")
        for x in [s, s2, s3] { _ = await x.end() }
    }

    // --- first poll: no history, dedupe, own ignored; one reply with exact args ---
    do {
        let fake = FakeLark(); generated = []
        let s = await makeSession(fake, chat: p2p)
        fake.setMessages([history, F.msg("om_own", "我自己说的", at: "2026-11-06 08:30", from: F.me), F.msg("om_1", "晚上吃饭吗", at: "2026-11-06 08:31")])
        await s.pollOnce()
        precondition(s.records.map(\.id) == ["om_1"], "history and own messages never recorded: \(s.records.map(\.id))")
        precondition(s.records[0].state == .sentAuto && s.records[0].draft == "好的，收到", "\(s.records[0].state)")
        precondition(fake.replies == [["im", "+messages-reply", "--as", "user", "--message-id=om_1", "--text=好的，收到", "--idempotency-key=mo-om_1", "--format=json"]], "\(fake.replies)")
        precondition(generated.count == 1 && generated[0].contains("晚上吃饭吗") && generated[0].contains("messageToReply"))
        precondition(s.lastPoll != nil && s.status.isEmpty)
        await s.pollOnce(); await s.pollOnce()
        precondition(fake.replies.count == 1 && s.records.count == 1, "dedupe by message_id")
        let listCall = fake.calls.first { $0.count > 1 && $0[1] == "+chat-messages-list" && $0.contains { $0.hasPrefix("--start=") } }!
        precondition(listCall.contains("--as") && listCall.contains("user") && listCall.contains("--chat-id=oc_chat") && listCall.contains { $0.hasPrefix("--start=") })
        precondition(!fake.calls.contains { $0.contains("--yolo") })
        _ = await s.end()
        precondition(!s.active && s.panels.toolbar == nil)
    }

    // --- group rules ---
    do {
        let fake = FakeLark()
        let s = await makeSession(fake, chat: group)
        fake.setMessages([F.msg("om_g1", "大家看一下", at: "2026-11-06 08:31"), F.msg("om_g2", "@我 你怎么看", at: "2026-11-06 08:32", mentions: [F.me]), F.msg("om_g3", "@别人", at: "2026-11-06 08:33", mentions: ["ou_x"]),
                         F.msg("om_g4", "机器人通知", at: "2026-11-06 08:33", from: "cli_bot", type: "app", mentions: [F.me]), F.msg("om_sys", "x invited y", at: "2026-11-06 08:33", from: "", type: "", kind: "system")])
        await s.pollOnce()
        let states = Dictionary(uniqueKeysWithValues: s.records.map { ($0.id, $0.state) })
        precondition(states["om_g1"] == .recorded && states["om_g2"] == .sentAuto && states["om_g3"] == .recorded && states["om_g4"] == .recorded && states["om_sys"] == nil, "\(states)")
        precondition(fake.replies.count == 1 && fake.replies[0].contains("--message-id=om_g2"))
        _ = await s.end()
    }

    // --- autoReply off / paused -> draft; edit + send; discard ---
    do {
        let fake = FakeLark()
        let s = await makeSession(fake, chat: p2p, auto: false)
        fake.setMessages([F.msg("om_d1", "有空吗", at: "2026-11-06 08:31", from: "ou_d1"), F.msg("om_d2", "在吗", at: "2026-11-06 08:31", from: "ou_d2")])
        await s.pollOnce()
        precondition(s.records.allSatisfy { $0.state == .draft } && fake.replies.isEmpty)
        s.setDraft("om_d1", "有空，几点？")
        await s.send("om_d1")
        precondition(fake.replies.count == 1 && fake.replies[0] == ["im", "+messages-reply", "--as", "user", "--message-id=om_d1", "--text=有空，几点？", "--idempotency-key=mo-om_d1", "--format=json"])
        precondition(s.records.first { $0.id == "om_d1" }?.state == .sentManual)
        await s.send("om_d1"); precondition(fake.replies.count == 1, "no double send")
        s.discard("om_d2"); await s.send("om_d2")
        precondition(s.records.first { $0.id == "om_d2" }?.state == .discarded && fake.replies.count == 1)
        _ = await s.end()
        // paused -> draft even when enabled
        let s2 = await makeSession(fake, chat: p2p)
        s2.togglePaused()
        fake.setMessages([F.msg("om_p1", "hi", at: "2026-11-06 08:31")])
        await s2.pollOnce()
        precondition(s2.records[0].state == .draft && fake.replies.count == 1)
        s2.togglePaused(); precondition(s2.autoReplyOn)
        _ = await s2.end()
    }

    // --- rate limit: 4th within 10 minutes becomes a draft ---
    do {
        let fake = FakeLark()
        let s = await makeSession(fake, chat: p2p, max: 3)
        fake.setMessages((1...4).map { F.msg("om_r\($0)", "问题\($0)", at: "2026-11-06 08:3\($0)", from: "ou_r\($0)") })
        await s.pollOnce()
        precondition(s.records.map(\.state) == [.sentAuto, .sentAuto, .sentAuto, .draft], "\(s.records.map(\.state))")
        precondition(fake.replies.count == 3)
        _ = await s.end()
    }

    // --- errors: Chinese status, no crash, polling continues ---
    do {
        let fake = FakeLark(); generatorFails = false
        let s = await makeSession(fake, chat: p2p)
        fake.setError("lark-cli 登录已失效，请在终端执行 lark-cli auth login")
        await s.pollOnce()
        precondition(s.status.contains("登录已失效") && s.active && s.lastPoll != nil && s.records.isEmpty)
        fake.setError(nil)
        fake.setMessages([F.msg("om_e1", "你好", at: "2026-11-06 08:31")])
        await s.pollOnce()
        precondition(s.status.isEmpty && s.records.count == 1 && s.records[0].state == .sentAuto, "recovered")
        // reply failure -> failed with retry
        fake.setMessages([F.msg("om_e1", "你好", at: "2026-11-06 08:31"), F.msg("om_e2", "再问一个", at: "2026-11-06 08:32")])
        let n = fake.replies.count
        s.generate = { _ in generatorFails = true; struct E: Error {}; throw E() }
        await s.pollOnce()
        precondition(s.records.last?.state.isFailed == true && s.records.last!.state.label.contains("生成回复失败") && fake.replies.count == n)
        _ = await s.end()
        // generator error text
        generatorFails = false
        // CLI parsing: error envelope
        let envelope = LarkCLI(run: { _ in FakeLark.json(["ok": false, "error": ["type": "auth", "subtype": "token_expired", "message": "token expired"]]) })
        do { _ = try await envelope.recentChats(); preconditionFailure("should throw") } catch { precondition((error as? LarkError)?.message.contains("登录已失效") == true) }
        // auth status not logged in
        let loggedOut = LarkCLI(run: { _ in FakeLark.json(["identity": "user", "identities": ["user": ["available": false]]]) })
        do { _ = try await loggedOut.currentUserID(); preconditionFailure() } catch { precondition((error as? LarkError)?.message.contains("未登录") == true) }
    }

    // --- attach failures surface Chinese status ---
    do {
        let s = LarkProxySession(); s.autoStart = false
        s.makeCLI = { nil }
        let failed = await s.attach(lark, note: "")
        precondition(!failed && s.status.contains("lark-cli") && !s.active)
    }
    precondition(larkIdempotencyKey(String(repeating: "x", count: 80)).count == 50 && larkIdempotencyKey("om_1") == "mo-om_1")

    // --- C1/I4 sanitize + argv injection ---
    precondition(larkSanitizeReply("好的 <at user_id=\"all\">所有人</at> 收到<at user_id=\"x\"/>") == "好的  收到")
    precondition(larkSanitizeReply("看图 ![x](https://evil.test/a.png) 好") == "看图  好")
    precondition(larkSanitizeReply("见 https://example.com/a?b=1 和 http://x.y") == "见 （链接已省略） 和 （链接已省略）")
    precondition(larkSanitizeReply(String(repeating: "字", count: 800)).count == 500)
    do {
        let fake = FakeLark()
        let s = await makeSession(fake, chat: p2p)
        s.generate = { _ in "--as bot <at user_id=\"all\">x</at> 见 https://evil.test ![i](http://a/b.png)" }
        fake.setMessages([F.msg("om_i1", "hi", at: "2026-11-06 08:31")])
        await s.pollOnce()
        let call = fake.replies[0]
        precondition(call.filter { $0.hasPrefix("--text=") } == ["--text=--as bot  见 （链接已省略）"], "\(call)")
        precondition(!call.contains("--markdown") && !call.contains { $0.hasPrefix("--markdown") } && call.filter({ $0 == "--as" }).count == 1 && call.contains("--message-id=om_i1"))
        precondition(call.allSatisfy { !$0.hasPrefix("-") || $0.hasPrefix("--as") || $0.contains("=") || $0 == "--no-reactions" })
        let list = fake.calls.first { $0.contains("+chat-messages-list") }!
        precondition(list.contains("--chat-id=oc_chat") && list.contains("--format=json"))
        _ = await s.end()
        let q = FakeLark(); let s2 = await makeSession(q, lines: ["x"])
        await s2.search("--as bot"); precondition(q.calls.last!.contains("--query=--as bot"))
        _ = await s2.end()
    }

    // --- C2: merge, stale, already replied ---
    do {
        let fake = FakeLark()
        let s = await makeSession(fake, chat: p2p)
        fake.setMessages([F.msg("om_m1", "在吗", at: "2026-11-06 08:31"), F.msg("om_m2", "有个事", at: "2026-11-06 08:31"), F.msg("om_m3", "帮忙看下", at: "2026-11-06 08:32", from: "ou_other2")])
        await s.pollOnce()
        let st = Dictionary(uniqueKeysWithValues: s.records.map { ($0.id, $0.state) })
        precondition(st["om_m1"] == .skipped("已合并") && st["om_m2"] == .sentAuto && st["om_m3"] == .sentAuto && fake.replies.count == 2, "\(st)")
        precondition(st["om_m1"]!.label == "已合并")
        _ = await s.end()
        // older than 5 minutes at send time -> draft only
        let f2 = FakeLark()
        let s2 = await makeSession(f2, chat: p2p, now: formatter.date(from: "2026-11-06 08:40:00"))
        s2.select(p2p)
        let later = s2.now
        s2.now = { formatter.date(from: "2026-11-06 08:30:40")! }
        s2.select(p2p); s2.now = later
        f2.setMessages([F.msg("om_o1", "旧消息", at: "2026-11-06 08:32")])
        await s2.pollOnce()
        precondition(s2.records[0].state == .draft && f2.replies.isEmpty, "\(s2.records[0].state)")
        _ = await s2.end()
        // I'm already replied (seen on the re-fetch right before sending, while the generator was slow)
        let f3 = FakeLark()
        let s3 = await makeSession(f3, chat: p2p)
        s3.generate = { _ in
            f3.setMessages([F.msg("om_q1", "吃了吗", at: "2026-11-06 08:31"), F.msg("om_mine", "我自己回了", at: "2026-11-06 08:32", from: F.me)])
            return "吃了"
        }
        f3.setMessages([F.msg("om_q1", "吃了吗", at: "2026-11-06 08:31")])
        await s3.pollOnce()
        precondition(s3.records[0].state == .skipped("你已回复，跳过") && f3.replies.isEmpty && s3.records[0].state.label == "你已回复，跳过", "\(s3.records[0].state)")
        // an own reply that happened BEFORE the target does not block
        f3.setMessages([F.msg("om_old_mine", "之前", at: "2026-11-06 08:30", from: F.me), F.msg("om_q2", "在吗", at: "2026-11-06 08:34")])
        s3.generate = { _ in "在" }
        await s3.pollOnce()
        precondition(s3.records.last?.id == "om_q2" && s3.records.last?.state == .sentAuto, "\(s3.records.map { ($0.id, $0.state) }) \(s3.status)")
        _ = await s3.end()
    }

    // --- I3: attach-minute messages are shown but never auto-sent ---
    do {
        let fake = FakeLark()
        let s = await makeSession(fake, chat: p2p)
        fake.setMessages([F.msg("om_early", "刚好在 attach 那分钟", at: "2026-11-06 08:30")])
        await s.pollOnce()
        precondition(s.records.count == 1 && s.records[0].state == .recordedEarly && fake.replies.isEmpty)
        precondition(s.records[0].state.label == "仅记录（attach 当分钟内的消息不自动回复）")
        _ = await s.end()
    }

    // --- I5: id_type / own-sent ids ---
    do {
        let fake = FakeLark()
        let s = await makeSession(fake, chat: p2p)
        fake.setMessages([F.msg("om_a1", "来自非 open_id 的发送者", at: "2026-11-06 08:31", from: "cli_app", idType: "app_id"), F.msg("om_a2", "你好", at: "2026-11-06 08:31", from: "ou_y")])
        await s.pollOnce()
        precondition(s.records.first { $0.id == "om_a1" }?.state == .recorded && s.records.first { $0.id == "om_a2" }?.state == .sentAuto)
        // our own reply comes back later attributed to someone else: ignored via returned message_id
        fake.setMessages([F.msg("om_sent_1", "好的，收到", at: "2026-11-06 08:32", from: "ou_unknown")])
        await s.pollOnce()
        precondition(s.records.allSatisfy { $0.id != "om_sent_1" } && fake.replies.count == 1)
        _ = await s.end()
    }

    // --- I6: process-wide per-chat ledger; failures count; survives switching ---
    do {
        let fake = FakeLark(); let ledger = LarkSendLedger()
        let s = await makeSession(fake, chat: p2p, max: 3, ledger: ledger)
        fake.setReplyError("lark-cli 响应超时（30 秒）")
        fake.setMessages([F.msg("om_l1", "1", at: "2026-11-06 08:31", from: "ou_1")])
        await s.pollOnce()
        precondition(s.records[0].state.isFailed && ledger.count(chat: "oc_chat", now: attachTime) == 1, "failed attempt counts")
        fake.setReplyError(nil)
        fake.setMessages([F.msg("om_l2", "2", at: "2026-11-06 08:32", from: "ou_2"), F.msg("om_l3", "3", at: "2026-11-06 08:32", from: "ou_3")])
        await s.pollOnce()
        precondition(ledger.count(chat: "oc_chat", now: attachTime) == 3)
        s.select(group); s.select(p2p)   // switch away and back
        fake.setMessages([F.msg("om_l4", "4", at: "2026-11-06 08:33", from: "ou_4")])
        await s.pollOnce()
        precondition(s.records.first { $0.id == "om_l4" }?.state == .draft, "limit survives chat switch")
        _ = await s.end()
        // re-attach with the same ledger
        let again = await makeSession(fake, chat: p2p, max: 3, ledger: ledger)
        fake.setMessages([F.msg("om_l5", "5", at: "2026-11-06 08:33", from: "ou_5")])
        await again.pollOnce()
        precondition(again.records[0].state == .draft && ledger.count(chat: "oc_group", now: attachTime) == 0, "limit survives re-attach, other chats unaffected")
        _ = await again.end()
    }

    // --- I7: unconfirmed auto-detected chat only drafts; OCR band ---
    precondition(larkOCRRegion == CGRect(x: 0.3, y: 0, width: 0.7, height: 0.14))
    do {
        let fake = FakeLark()
        let s = await makeSession(fake, lines: ["小李 · 在线"])
        await s.detectChat()
        precondition(s.chat == p2p && !s.confirmed)
        fake.setMessages([F.msg("om_c1", "在吗", at: "2026-11-06 08:31")])
        await s.pollOnce()
        precondition(s.records[0].state == .draft && fake.replies.isEmpty)
        s.confirmChat()
        fake.setMessages([F.msg("om_c2", "还在吗", at: "2026-11-06 08:32")])
        await s.pollOnce()
        precondition(s.records.last?.state == .sentAuto && fake.replies.count == 1)
        _ = await s.end()
    }

    // --- process runner: timeout kills the child tree and cannot hang ---
    do {
        let start = Date()
        let r = larkRunProcess(executable: "/bin/sh", arguments: ["-c", "sleep 30 & sleep 30"], timeout: 1)
        precondition(r != nil && r!.timedOut && Date().timeIntervalSince(start) < 6, "timeout returns promptly")
        let ok = larkRunProcess(executable: "/bin/sh", arguments: ["-c", "echo out; echo err 1>&2"], timeout: 5)!
        precondition(ok.status == 0 && String(decoding: ok.out, as: UTF8.self) == "out\n" && String(decoding: ok.err, as: UTF8.self) == "err\n" && !ok.timedOut)
        precondition(larkRunProcess(executable: "/nonexistent/x", arguments: [], timeout: 1) == nil)
    }

    // --- N1/N4: angle brackets are always escaped; manual sends keep URLs and length ---
    for bad in ["<a<at></at>t user_id=\"all\">x", "<at user_id=\"all\"></at>", "<<at user_id=\"all\">>", "<at\nuser_id=\"all\">"] {
        let cleaned = larkSanitizeReply(bad)
        precondition(!cleaned.contains("<") && !cleaned.contains(">") && !cleaned.contains("<at"), "\(cleaned)")
        precondition(!larkEscapeAngles(bad).contains("<") && !larkEscapeAngles(bad).contains(">"))
    }
    do {
        let fake = FakeLark()
        let s = await makeSession(fake, chat: p2p, auto: false)
        fake.setMessages([F.msg("om_n1", "hi", at: "2026-11-06 08:31")])
        await s.pollOnce()
        let long = "详见 https://example.com/doc " + String(repeating: "长", count: 700) + " <at user_id=\"all\">x</at>"
        s.setDraft("om_n1", long)
        await s.send("om_n1")
        let text = fake.replies[0].first { $0.hasPrefix("--text=") }!
        precondition(text.contains("https://example.com/doc") && text.count > 600 && !text.contains("<") && !text.contains(">") && text.contains("＜at user_id=\"all\"＞x＜/at＞"), "manual: escape only")
        _ = await s.end()
        // auto path: full sanitize
        let f2 = FakeLark(); let s2 = await makeSession(f2, chat: p2p)
        s2.generate = { _ in "见 https://e.test <a<at></at>t user_id=\"all\">x" }
        f2.setMessages([F.msg("om_n2", "hi", at: "2026-11-06 08:31")])
        await s2.pollOnce()
        let auto = f2.replies[0].first { $0.hasPrefix("--text=") }!
        precondition(!auto.contains("https://") && !auto.contains("<") && !auto.contains(">") && auto.contains("（链接已省略）"), auto)
        _ = await s2.end()
    }

    // --- N5: settings flipped during the slow re-fetch keep the message as a draft ---
    do {
        let fake = FakeLark()
        let s = await makeSession(fake, chat: p2p)
        let flag = NSLock(); nonisolated(unsafe) var enabled = true
        s.autoReplyEnabled = { flag.lock(); defer { flag.unlock() }; return enabled }
        fake.setOnRecent { n in if n == 2 { flag.lock(); enabled = false; flag.unlock() } }   // 1st = context, 2nd = pre-send re-check
        fake.setMessages([F.msg("om_f1", "在吗", at: "2026-11-06 08:31")])
        await s.pollOnce()
        precondition(s.records[0].state == .draft && fake.replies.isEmpty, "toggle off during re-fetch -> draft: \(s.records[0].state)")
        _ = await s.end()
    }

    // --- missing scope ---
    do {
        let envelope = #"{"ok":false,"error":{"type":"permission","subtype":"missing_scope","message":"missing","missing_scopes":["im:message.send_as_user"]}}"#
        let e = larkError(fromRaw: envelope)
        precondition(e.missingScope && e.message == "缺少发送权限 im:message.send_as_user：在终端运行 lark-cli auth login --scope \"im:message.send_as_user\" 完成授权后点重试", e.message)
        precondition(!larkError(fromRaw: "{\"ok\":false,\"error\":{\"subtype\":\"other\"}}").missingScope)
        let fake = FakeLark()
        let s = await makeSession(fake, chat: p2p)
        fake.setReplyRaw(Data(envelope.utf8))
        fake.setMessages([F.msg("om_s1", "1", at: "2026-11-06 08:31", from: "ou_1")])
        await s.pollOnce()
        precondition(s.records[0].state.isFailed && s.records[0].state.label.hasPrefix("缺少发送权限 im:message.send_as_user") && s.status.hasPrefix("缺少发送权限"), s.records[0].state.label)
        precondition(s.records[0].draft == "好的，收到", "draft kept")
        fake.setMessages([F.msg("om_s2", "2", at: "2026-11-06 08:32", from: "ou_2")])
        await s.pollOnce()
        precondition(s.records.last?.state == .draft && fake.replies.count == 1, "auto-reply paused for the chat, no retry each poll")
        fake.setReplyRaw(nil)
        await s.send("om_s1")   // manual retry succeeds and lifts the block
        precondition(s.records[0].state == .sentManual && fake.replies.count == 2)
        fake.setMessages([F.msg("om_s3", "3", at: "2026-11-06 08:33", from: "ou_3")])
        await s.pollOnce()
        precondition(s.records.last?.state == .sentAuto)
        _ = await s.end()
        let granted = #"{"identities":{"user":{"available":true,"scope":"im:message im:message.send_as_user offline_access"}}}"#
        let missing = #"{"identities":{"user":{"available":true,"scope":"im:message offline_access"}}}"#
        precondition(larkScopeCheckMessage(Data(granted.utf8)).hasPrefix("已具备发送权限"))
        precondition(larkScopeCheckMessage(Data(missing.utf8)).hasPrefix("缺少发送权限 im:message.send_as_user") && larkScopeCheckMessage(Data(missing.utf8)).contains("lark-cli auth login --scope"))
        precondition(larkScopeCheckMessage(Data("{}".utf8)).contains("未获取到"))
    }

    // --- process runner stress: no crash on teardown with busy writers ---
    for _ in 0..<20 {
        let r = larkRunProcess(executable: "/bin/sh", arguments: ["-c", "yes | head -c 300000; echo done 1>&2"], timeout: 5)!
        precondition(r.out.count == 300000 && String(decoding: r.err, as: UTF8.self) == "done\n")
    }

    // --- render ---
    do {
        let fake = FakeLark(); generatorFails = false
        let s = await makeSession(fake, chat: group, auto: true, max: 1)
        s.makeCLI = { fake.cli }
        fake.setMessages([F.msg("om_v1", "周五的评审改到下午三点了，大家注意一下时间", at: "2026-11-06 08:31", from: "ou_c"),
                          F.msg("om_v2", "@我 方案文档看了吗？有几处想确认", at: "2026-11-06 08:32", from: "ou_a", mentions: [F.me]),
                          F.msg("om_v3", "@我 上线窗口能不能提前", at: "2026-11-06 08:33", from: "ou_b", mentions: [F.me])])
        await s.pollOnce()
        precondition(s.records.map(\.state) == [.recorded, .sentAuto, .draft], "\(s.records.map(\.state))")
        s.lastPoll = attachTime
        s.panels.position(CGRect(x: 100, y: 100, width: 900, height: 700))
        let toolbar = s.panels.toolbar!
        precondition(toolbar.contentView!.acceptsFirstMouse(for: nil) && s.panels.record != nil)
        @MainActor func render<V: View>(_ name: String, size: CGSize, _ view: V) throws {
            let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
            host.frame = CGRect(origin: .zero, size: size)
            let panel = NSPanel(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            panel.appearance = NSAppearance(named: .darkAqua); panel.contentView = host; host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let layer = NSImage(data: bitmap.representation(using: .png, properties: [:])!)!
            let picture = NSImage(size: size, flipped: false) { rect in NSColor(calibratedWhite: 0.055, alpha: 1).setFill(); rect.fill(); layer.draw(in: rect); return true }
            try reviewPNG(picture).write(to: URL(fileURLWithPath: dest).appendingPathComponent(name + ".png"))
            panel.close()
        }
        try render("lark-orb", size: CGSize(width: 128, height: 124), LarkProxyOrbitView(session: s))
        let preview = s.panels.record!.frame.size
        try render("lark-record", size: preview, LarkProxyRecordView(session: s))
        let picking = await makeSession(fake, lines: ["nothing"])
        await picking.detectChat()
        try render("lark-picker", size: preview, LarkProxyRecordView(session: picking))
        _ = await picking.end()
        let unconfirmed = await makeSession(fake, lines: ["Mo 项目群"])
        await unconfirmed.detectChat(); precondition(!unconfirmed.confirmed)
        try render("lark-unconfirmed", size: preview, LarkProxyRecordView(session: unconfirmed))
        _ = await unconfirmed.end()
        // orb click polls once more
        let before = fake.calls.count
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 64, y: 40), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: toolbar.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: CGPoint(x: 64, y: 40), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.05, windowNumber: toolbar.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        try await Task.sleep(nanoseconds: 100_000_000)
        toolbar.sendEvent(down); toolbar.sendEvent(up)
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(fake.calls.count > before, "orb click triggers an immediate poll")
        _ = await s.end()
        precondition(s.panels.toolbar == nil && s.panels.record == nil)
    }
    print("PASS: lark proxy")
    exit(0)
}
Task { try await Task.sleep(nanoseconds: 30_000_000_000); fatalError("Lark proxy tests timed out") }
app.run()
