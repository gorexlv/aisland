// Renders the game companion orb and record panel with a few records. Never starts listening (no microphone).
import Cocoa
import SwiftUI
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let destination = URL(fileURLWithPath: CommandLine.arguments[1])
    let session = GameSession()
    session.active = true; session.inBattle = true
    session.add(said: "小莫小莫骑兵冲锋", result: "重骑兵 冲锋；骑射营 冲锋", kind: .done)
    session.add(said: "弓箭手冲锋", result: "弓兵1营 自由行动（冲锋改）", kind: .done)
    session.add(said: "随便说说", result: "没听懂：随便说说", kind: .unknown)
    session.add(said: "剑盾兵三营前进", result: "跳过 剑盾兵3营：已经不在场", kind: .skipped)
    session.panels.position(CGRect(x: 100, y: 100, width: 900, height: 620))
    precondition(session.panels.toolbar != nil && session.panels.record != nil)
    precondition(session.panels.toolbar!.contentView!.acceptsFirstMouse(for: nil), "Hosting window must accept the first click")
    precondition(!session.listening && !session.preparing, "render test must not open the microphone")
    precondition(session.statusLine == "麦克风已关")
    session.setRecordsShown(false)
    precondition(session.panels.record?.isVisible != true, "record panel must collapse")
    session.setRecordsShown(true)
    precondition(session.panels.record?.isVisible == true, "record panel must reopen")
    @MainActor func render<V: View>(_ name: String, scheme: ColorScheme, size: CGSize, _ view: V) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        host.frame = CGRect(origin: .zero, size: size)
        let panel = NSPanel(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        panel.contentView = host; host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let layer = NSImage(data: bitmap.representation(using: .png, properties: [:])!)!
        let picture = NSImage(size: size, flipped: false) { rect in
            NSColor(calibratedWhite: scheme == .dark ? 0.055 : 0.94, alpha: 1).setFill(); rect.fill(); layer.draw(in: rect); return true
        }
        try reviewPNG(picture).write(to: destination.appendingPathComponent(name + ".png"))
        panel.close()
    }
    let orbit = CGSize(width: 128, height: 124)
    try render("game-orb-dark", scheme: .dark, size: orbit, GameOrbitView(session: session))
    try render("game-orb-light", scheme: .light, size: orbit, GameOrbitView(session: session))
    let preview = session.panels.record!.frame.size
    try render("game-record-dark", scheme: .dark, size: preview, GameRecordView(session: session))
    try render("game-record-light", scheme: .light, size: preview, GameRecordView(session: session))
    session.status = "请先结束会议"
    try render("game-record-status", scheme: .dark, size: preview, GameRecordView(session: session))
    session.status = ""; session.listening = true; session.online = true   // flags only; nothing opens the microphone
    precondition(session.statusLine == "在听 · 使用 Apple 在线识别", session.statusLine)
    try render("game-record-online", scheme: .dark, size: preview, GameRecordView(session: session))
    session.listening = false; session.online = false
    session.end()
    precondition(session.panels.toolbar == nil && session.panels.record == nil && !session.active)
    print("PASS: game render")
    exit(0)
}
Task { try await Task.sleep(nanoseconds: 15_000_000_000); fatalError("Game render test timed out") }
app.run()
