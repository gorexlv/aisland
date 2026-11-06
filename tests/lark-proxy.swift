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
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
    var replies: [[String]] { calls.filter { $0.count > 1 && $0[1] == "+messages-reply" } }
    func setMessages(_ value: [[String: Any]]) { lock.lock(); _messages = value; lock.unlock() }
    func setError(_ value: String?) { lock.lock(); _error = value; lock.unlock() }
    static let me = "ou_me"
    static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    static func msg(_ id: String, _ text: String, at time: String, from sender: String = "ou_other", type: String = "user", mentions: [String] = [], kind: String = "text") -> [String: Any] {
        var m: [String: Any] = ["message_id": id, "chat_id": "oc_chat", "content": text, "create_time": time, "deleted": false, "msg_type": kind,
                                "sender": ["id": sender, "id_type": "open_id", "name": sender == me ? "我" : "小李", "sender_type": type]]
        if !mentions.isEmpty { m["mentions"] = mentions.enumerated().map { ["id": $1, "key": "@_user_\($0 + 1)", "name": "x"] } }
        return m
    }
    var cli: LarkCLI {
        LarkCLI(run: { [self] args in
            lock.lock(); _calls.append(args); let error = _error; let messages = _messages; lock.unlock()
            if args[0] == "auth" { return Self.json(["identity": "user", "brand": "lark", "identities": ["user": ["available": true, "tokenStatus": "valid", "openId": Self.me, "userName": "Me"]]]) }
            if let error { throw LarkError(message: error) }
            switch args[1] {
            case "+chat-list": return Self.json(["ok": true, "data": ["chats": [["chat_id": "oc_chat", "chat_mode": "p2p", "name": "小李"], ["chat_id": "oc_group", "chat_mode": "group", "name": "Mo 项目群"], ["chat_id": "oc_g2", "chat_mode": "group", "name": "Mo 设计群"]], "has_more": false]])
            case "+chat-search": return Self.json(["ok": true, "data": ["chats": [["chat_id": "oc_s", "chat_mode": "DEFAULT", "name": "搜索结果"]]]])
            case "+chat-messages-list": return Self.json(["ok": true, "data": ["messages": messages, "has_more": false]])
            case "+messages-reply": return Self.json(["ok": true, "data": ["message_id": "om_sent"]])
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
    @MainActor func makeSession(_ fake: FakeLark, chat: LarkChat? = nil, auto: Bool = true, max: Int = 3, lines: [String] = []) async -> LarkProxySession {
        let s = LarkProxySession()
        s.autoStart = false
        s.makeCLI = { fake.cli }
        s.resolveFrame = { _ in CGRect(x: 100, y: 100, width: 900, height: 620) }
        s.detectLines = { _ in lines }
        s.now = { attachTime }
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
        precondition(s.chat == group && !s.needsPicker && s.chats.count == 3, "detected")
        let s2 = await makeSession(fake, lines: ["Mo 项目群", "Mo 设计群"])
        await s2.detectChat()
        precondition(s2.chat == nil && s2.needsPicker, "ambiguous -> picker")
        let s3 = await makeSession(fake, lines: ["nothing"])
        await s3.detectChat()
        precondition(s3.chat == nil && s3.needsPicker && !s3.status.isEmpty)
        await s3.search("搜")
        precondition(s3.searchResults.map(\.name) == ["搜索结果"] && s3.visibleChats.first?.id == "oc_s")
        s3.select(s3.searchResults[0]); precondition(s3.chat?.id == "oc_s" && !s3.needsPicker)
        for x in [s, s2, s3] { _ = await x.end() }
    }

    // --- first poll: no history, dedupe, own ignored; one reply with exact args ---
    do {
        let fake = FakeLark(); generated = []
        let s = await makeSession(fake, chat: p2p)
        fake.setMessages([history, F.msg("om_own", "我自己说的", at: "2026-11-06 08:31", from: F.me), F.msg("om_1", "晚上吃饭吗", at: "2026-11-06 08:31")])
        await s.pollOnce()
        precondition(s.records.map(\.id) == ["om_1"], "history and own messages never recorded: \(s.records.map(\.id))")
        precondition(s.records[0].state == .sentAuto && s.records[0].draft == "好的，收到", "\(s.records[0].state)")
        precondition(fake.replies == [["im", "+messages-reply", "--as", "user", "--message-id", "om_1", "--markdown", "好的，收到", "--idempotency-key", "mo-om_1"]], "\(fake.replies)")
        precondition(generated.count == 1 && generated[0].contains("晚上吃饭吗") && generated[0].contains("messageToReply"))
        precondition(s.lastPoll != nil && s.status.isEmpty)
        await s.pollOnce(); await s.pollOnce()
        precondition(fake.replies.count == 1 && s.records.count == 1, "dedupe by message_id")
        let listCall = fake.calls.first { $0.count > 1 && $0[1] == "+chat-messages-list" && $0.contains("--start") }!
        precondition(listCall.contains("--as") && listCall.contains("user") && listCall.contains("oc_chat"))
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
        precondition(fake.replies.count == 1 && fake.replies[0].contains("om_g2"))
        _ = await s.end()
    }

    // --- autoReply off / paused -> draft; edit + send; discard ---
    do {
        let fake = FakeLark()
        let s = await makeSession(fake, chat: p2p, auto: false)
        fake.setMessages([F.msg("om_d1", "有空吗", at: "2026-11-06 08:31"), F.msg("om_d2", "在吗", at: "2026-11-06 08:31")])
        await s.pollOnce()
        precondition(s.records.allSatisfy { $0.state == .draft } && fake.replies.isEmpty)
        s.setDraft("om_d1", "有空，几点？")
        await s.send("om_d1")
        precondition(fake.replies.count == 1 && fake.replies[0] == ["im", "+messages-reply", "--as", "user", "--message-id", "om_d1", "--markdown", "有空，几点？", "--idempotency-key", "mo-om_d1"])
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
        fake.setMessages((1...4).map { F.msg("om_r\($0)", "问题\($0)", at: "2026-11-06 08:3\($0)") })
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

    // --- render ---
    do {
        let fake = FakeLark(); generatorFails = false
        let s = await makeSession(fake, chat: group, auto: true, max: 1)
        s.makeCLI = { fake.cli }
        fake.setMessages([F.msg("om_v1", "周五的评审改到下午三点了，大家注意一下时间", at: "2026-11-06 08:31"),
                          F.msg("om_v2", "@我 方案文档看了吗？有几处想确认", at: "2026-11-06 08:32", mentions: [F.me]),
                          F.msg("om_v3", "@我 上线窗口能不能提前", at: "2026-11-06 08:33", mentions: [F.me])])
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
