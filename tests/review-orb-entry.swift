import Cocoa
import SwiftUI
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let model = ReviewModel()
    let recorder = Recorder(review:model)
    let indicator = IslandActivityIndicator(model:recorder,review:model,voice:model.voice,reader:recorder.screenReader)
    precondition(indicator.title == "就绪")
    model.voice.voicePreparing = true; precondition(indicator.title == "启动录音")
    model.voice.voicePreparing = false; model.voice.dictating = true; precondition(indicator.title == "正在录音")
    model.voice.dictating = false; model.voice.voiceFinishing = true; precondition(indicator.title == "正在转写")
    model.voice.voiceFinishing = false; recorder.screenReader.busy = true; precondition(indicator.title == "正在读屏")
    recorder.screenReader.busy = false
    model.active = true
    model.target = ScreenTarget(id:1,pid:-1,app:"Fixture",bundleID:"fixture",title:"Entry")
    model.panels.positionSidebar(CGRect(x:100,y:100,width:900,height:620))
    let host = model.panels.toolbar!.contentView!
    precondition(host.acceptsFirstMouse(for:nil), "Hosting window must accept the first click")
    let identity = ObjectIdentifier(host)
    model.panels.refreshChrome(); model.panels.refreshChrome()
    precondition(ObjectIdentifier(model.panels.toolbar!.contentView!) == identity)
    model.paused = true
    try await Task.sleep(nanoseconds:100_000_000)
    host.layoutSubtreeIfNeeded()
    let window = model.panels.toolbar!
    let location = CGPoint(x:64,y:40)
    let down = NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
    let up = NSEvent.mouseEvent(with:.leftMouseUp,location:location,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime+0.05,windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0)!
    window.sendEvent(down); window.sendEvent(up)
    try await Task.sleep(nanoseconds:150_000_000)
    while model.busy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(!model.paused, "Visible orb button must toggle review through mouse events")
    let destination = URL(fileURLWithPath:CommandLine.arguments[1])
    @MainActor func render(_ name:String, scheme:ColorScheme) throws {
        let host = NSHostingView(rootView:ReviewOrbitView(model:model,voice:model.voice).environment(\.colorScheme,scheme))
        host.frame = CGRect(x:0,y:0,width:128,height:124)
        let panel = NSPanel(contentRect:host.frame,styleMask:.borderless,backing:.buffered,defer:false)
        panel.appearance = NSAppearance(named:scheme == .dark ? .darkAqua : .aqua)
        panel.contentView = host; host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds)!
        host.cacheDisplay(in:host.bounds,to:bitmap)
        let layer = NSImage(data:bitmap.representation(using:.png,properties:[:])!)!
        let picture = NSImage(size:host.bounds.size,flipped:false) { rect in
            NSColor(calibratedWhite:scheme == .dark ? 0.055 : 0.94,alpha:1).setFill(); rect.fill(); layer.draw(in:rect); return true
        }
        try reviewPNG(picture).write(to:destination.appendingPathComponent(name+".png"))
        panel.close()
    }
    try render("orb-empty-dark",scheme:.dark)
    try render("orb-empty-light",scheme:.light)
    await model.setInputMode(.text)
    precondition(model.inputMode == .text, "Mode can switch before an opinion exists")
    try render("orb-text-dark",scheme:.dark)
    try render("orb-text-light",scheme:.light)
    await model.setInputMode(.audio)
    let image = NSImage(size:CGSize(width:100,height:100))
    model.snapshots = (0..<3).map { _ in ReviewSnapshot(id:UUID(),image:image,png:Data(),frame:.zero) }
    model.current = model.snapshots.last; model.paused = true
    try render("orb-history-dark",scheme:.dark)
    try render("orb-history-light",scheme:.light)
    model.panels.close()
    print("PASS: native orb action toggles review, first-click acceptance, empty/history light/dark render fixtures")
    exit(0)
}
Task { try await Task.sleep(nanoseconds:15_000_000_000); fatalError("Entry test timed out") }
app.run()
