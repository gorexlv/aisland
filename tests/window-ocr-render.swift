import Cocoa
import SwiftUI
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let destination = URL(fileURLWithPath:CommandLine.arguments[1])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("window-ocr-render-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let session = WindowOCRSession(voice:VoiceInput(),storageRoot:root)
    let fixture = ScreenTarget(id:1,pid:-1,app:"Fixture",bundleID:"fixture",title:"Doc")
    session.target = fixture; session.active = true; session.note = "查标题是否正确"
    session.reader.text = "Quarterly report\n第二季度营收同比增长 12%\nTotal: 1,234,567"
    session.reader.status = "已保存：fixture"
    var clicks = 0
    session.panels.reframeAction = { clicks += 1 }
    session.panels.position(CGRect(x:100,y:100,width:900,height:620))
    let toolbar = session.panels.toolbar!
    precondition(toolbar.contentView!.acceptsFirstMouse(for:nil), "Hosting window must accept the first click")
    precondition(session.panels.record != nil)
    toolbar.contentView!.layoutSubtreeIfNeeded()
    try await Task.sleep(nanoseconds:100_000_000)
    let location = CGPoint(x:64,y:40)
    let down = NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:toolbar.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
    let up = NSEvent.mouseEvent(with:.leftMouseUp,location:location,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime+0.05,windowNumber:toolbar.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0)!
    toolbar.sendEvent(down); toolbar.sendEvent(up)
    try await Task.sleep(nanoseconds:150_000_000)
    precondition(clicks == 1, "Orb click must call reframe once, got \(clicks)")
    @MainActor func render<V:View>(_ name:String, scheme:ColorScheme, size:CGSize, bg:Bool = true, _ view:V) throws {
        let host = NSHostingView(rootView:view.environment(\.colorScheme,scheme))
        host.frame = CGRect(origin:.zero,size:size)
        let panel = NSPanel(contentRect:host.frame,styleMask:.borderless,backing:.buffered,defer:false)
        panel.appearance = NSAppearance(named:scheme == .dark ? .darkAqua : .aqua)
        panel.contentView = host; host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds)!
        host.cacheDisplay(in:host.bounds,to:bitmap)
        let layer = NSImage(data:bitmap.representation(using:.png,properties:[:])!)!
        let picture = NSImage(size:size,flipped:false) { rect in
            NSColor(calibratedWhite:scheme == .dark ? 0.055 : 0.94,alpha:1).setFill(); rect.fill(); layer.draw(in:rect); return true
        }
        try reviewPNG(picture).write(to:destination.appendingPathComponent(name+".png"))
        panel.close()
    }
    let orbit = CGSize(width:128,height:124)
    try render("ocr-orb-dark",scheme:.dark,size:orbit,WindowOCROrbitView(session:session,voice:session.voice))
    try render("ocr-orb-light",scheme:.light,size:orbit,WindowOCROrbitView(session:session,voice:session.voice))
    let preview = session.panels.record!.frame.size
    try render("ocr-record-dark",scheme:.dark,size:preview,WindowOCRRecordView(session:session))
    session.panels.close()
    precondition(session.panels.toolbar == nil && session.panels.record == nil)
    print("PASS: window ocr render")
    exit(0)
}
Task { try await Task.sleep(nanoseconds:15_000_000_000); fatalError("Window OCR render test timed out") }
app.run()
