// Unified settings window: centring, LarkProxySettings, auth status parsing, render.
import Cocoa
import SwiftUI
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let destination = URL(fileURLWithPath:CommandLine.arguments[1])
    // LarkProxySettings defaults and clamping
    let d = UserDefaults.standard
    [LarkProxySettings.autoReplyKey,LarkProxySettings.maxRepliesKey,LarkProxySettings.pollIntervalKey,LarkProxySettings.cliPathKey].forEach { d.removeObject(forKey:$0) }
    precondition(LarkProxySettings.autoReply == true)
    precondition(LarkProxySettings.maxRepliesPer10Min == 3)
    precondition(LarkProxySettings.pollInterval == 15)
    precondition(LarkProxySettings.cliPath == nil)
    LarkProxySettings.pollInterval = 1; precondition(LarkProxySettings.pollInterval == 10)
    LarkProxySettings.pollInterval = 999; precondition(LarkProxySettings.pollInterval == 120)
    LarkProxySettings.pollInterval = 30; precondition(LarkProxySettings.pollInterval == 30)
    d.set(2.0,forKey:LarkProxySettings.pollIntervalKey); precondition(LarkProxySettings.pollInterval == 10)
    precondition(LarkProxySettings.clampPoll(.nan) == 15)
    LarkProxySettings.maxRepliesPer10Min = 0; precondition(LarkProxySettings.maxRepliesPer10Min == 1)
    LarkProxySettings.autoReply = false; precondition(LarkProxySettings.autoReply == false)
    LarkProxySettings.cliPath = "  /x/lark-cli "; precondition(LarkProxySettings.cliPath == "/x/lark-cli")
    LarkProxySettings.cliPath = "  "; precondition(LarkProxySettings.cliPath == nil)
    [LarkProxySettings.autoReplyKey,LarkProxySettings.maxRepliesKey,LarkProxySettings.pollIntervalKey,LarkProxySettings.cliPathKey].forEach { d.removeObject(forKey:$0) }

    // Auth status parsing through an injected runner (no real lark-cli)
    let loggedIn = #"{"appId":"cli_x","brand":"lark","defaultAs":"auto","identity":"user","identities":{"bot":{"status":"ready","available":true},"user":{"status":"ready","available":true,"openId":"ou_1","userName":"Rex","tokenStatus":"valid","scope":"a b"}}}"#
    let loggedOut = #"{"brand":"feishu","identity":"bot","identities":{"bot":{"status":"ready","available":true},"user":{"status":"missing","available":false,"message":"not logged in"}}}"#
    var calls: [[String]] = []
    let on = LarkAuthProbe.status(executable:"/fake/lark-cli") { _,args in calls.append(args); return (0,Data(loggedIn.utf8)) }
    precondition(calls == [["auth","status","--json"]])
    precondition(on.loggedIn && on.identity == "user" && on.brand == "lark" && on.userName == "Rex" && on.message == "已登录")
    let off = LarkAuthProbe.status(executable:"/fake/lark-cli") { _,_ in (0,Data(loggedOut.utf8)) }
    precondition(!off.loggedIn && off.identity == "bot" && off.brand == "feishu" && off.message.contains("未登录"))
    let garbage = LarkAuthProbe.status(executable:"/fake/lark-cli") { _,_ in (1,Data("oops".utf8)) }
    precondition(!garbage.loggedIn)
    precondition(LarkCLIDetector.resolve(manual:nil,isExecutable:{ $0 == "/opt/homebrew/bin/lark-cli" }) == "/opt/homebrew/bin/lark-cli")
    precondition(LarkCLIDetector.resolve(manual:"/nope",isExecutable:{ _ in false }) == nil)
    precondition(LarkCLIDetector.resolve(manual:"/m/lark-cli",isExecutable:{ $0 == "/m/lark-cli" }) == "/m/lark-cli")

    LarkProbeModel.defaultRunner = { _,_ in (0,Data(loggedIn.utf8)) }   // never run the real lark-cli

    // Window centring on the screen containing the mouse
    precondition(!NSScreen.screens.isEmpty, "needs a screen")
    for (i,screen) in NSScreen.screens.enumerated() {
        let mouse = NSPoint(x:screen.frame.midX+10,y:screen.frame.midY+10)
        SettingsWindow.shared.show(mouse:mouse,activate:false)
        let window = SettingsWindow.shared.window!
        let visible = screen.visibleFrame
        precondition(abs(window.frame.midX-visible.midX) <= 1 && abs(window.frame.midY-visible.midY) <= 1, "screen \(i) not centred: \(window.frame) vs \(visible)")
        precondition(visible.contains(window.frame))
        // moving the window away then showing again re-centres
        window.setFrameOrigin(NSPoint(x:visible.minX,y:visible.minY))
        SettingsWindow.shared.show(section:.lark,mouse:mouse,activate:false)
        precondition(abs(window.frame.midX-visible.midX) <= 1 && abs(window.frame.midY-visible.midY) <= 1, "re-centre failed")
    }
    precondition(SettingsWindow.shared.window!.title == "Mo · 墨 设置")
    SettingsWindow.shared.window!.close()

    // Render
    let model = Recorder()
    let content = SettingsContent(model:model,live:model.review.live).padding(20).frame(width:520)
    let host = NSHostingView(rootView:content.environment(\.colorScheme,.light))
    host.frame = CGRect(origin:.zero,size:CGSize(width:520,height:host.fittingSize.height))
    host.appearance = NSAppearance(named:.aqua)
    let panel = NSPanel(contentRect:host.frame,styleMask:.borderless,backing:.buffered,defer:false)
    panel.appearance = NSAppearance(named:.aqua); panel.contentView = host; host.layoutSubtreeIfNeeded()
    let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds)!
    host.cacheDisplay(in:host.bounds,to:bitmap)
    let layer = NSImage(data:bitmap.representation(using:.png,properties:[:])!)!
    let picture = NSImage(size:host.bounds.size,flipped:false) { rect in
        NSColor(calibratedWhite:0.94,alpha:1).setFill(); rect.fill(); layer.draw(in:rect); return true
    }
    try reviewPNG(picture).write(to:destination.appendingPathComponent("settings.png"))
    try await Task.sleep(nanoseconds:800_000_000)
    host.layoutSubtreeIfNeeded()
    let bitmap2 = host.bitmapImageRepForCachingDisplay(in:host.bounds)!
    host.cacheDisplay(in:host.bounds,to:bitmap2)
    let layer2 = NSImage(data:bitmap2.representation(using:.png,properties:[:])!)!
    let picture2 = NSImage(size:host.bounds.size,flipped:false) { rect in
        NSColor(calibratedWhite:0.94,alpha:1).setFill(); rect.fill(); layer2.draw(in:rect); return true
    }
    try reviewPNG(picture2).write(to:destination.appendingPathComponent("settings.png"))
    panel.close()
    print("PASS: settings")
    exit(0)
}
Task { try await Task.sleep(nanoseconds:20_000_000_000); fatalError("Settings test timed out") }
app.run()
