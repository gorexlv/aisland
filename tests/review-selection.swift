// Route actual AppKit window events; speech is disabled in this synthetic fixture.
import Cocoa
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-selection-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let model = ReviewModel(storageRoot:root)
    model.active = true; model.paused = true; model.chatPanelShowsTranscript = true
    model.voice.unavailableReason = "fixture: microphone disabled"
    let image = NSImage(size:CGSize(width:600,height:400),flipped:false) { rect in NSColor.white.setFill();rect.fill();return true }
    let shot = ReviewSnapshot(id:UUID(),image:image,png:try reviewPNG(image),frame:CGRect(x:100,y:100,width:900,height:620))
    model.current = shot; model.snapshots = [shot]
    model.panels.showOverlay(shot)
    let window = model.panels.selectionOverlay!
    window.contentView!.layoutSubtreeIfNeeded()
    func findCanvas(_ view:NSView) -> ReviewCanvas? {
        if let canvas = view as? ReviewCanvas { return canvas }
        return view.subviews.compactMap { findCanvas($0) }.first
    }
    let canvas = findCanvas(window.contentView!)!
    func event(_ type:NSEvent.EventType,_ point:CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with:type,location:canvas.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseUp ? 0 : 1)!
    }
    window.sendEvent(event(.leftMouseDown,CGPoint(x:20,y:20)))
    window.sendEvent(event(.leftMouseDragged,CGPoint(x:120,y:90)))
    window.sendEvent(event(.leftMouseUp,CGPoint(x:120,y:90)))
    try await Task.sleep(nanoseconds:100_000_000)
    while model.busy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(model.regions.count == 1, "Dragging in the target window must create an opinion")
    let rect = model.regions[0].rect
    precondition(abs(rect.minX-20/canvas.bounds.width) < 0.001 && abs(rect.minY-20/canvas.bounds.height) < 0.001)
    precondition(abs(rect.width-100/canvas.bounds.width) < 0.001 && abs(rect.height-70/canvas.bounds.height) < 0.001)
    precondition(canvas.acceptsFirstMouse(for:nil), "Target canvas must accept the first drag from another app")
    precondition(model.voice.status == model.voice.unavailableReason, "Selection must request automatic voice")
    model.voice.status = "fixture: idle"
    let voicePoint = CGPoint(x:(rect.midX)*canvas.bounds.width,y:rect.minY*canvas.bounds.height+11)
    window.sendEvent(event(.leftMouseDown,voicePoint)); window.sendEvent(event(.leftMouseUp,voicePoint))
    try await Task.sleep(nanoseconds:50_000_000)
    while model.busy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(model.regions.count == 1 && model.voice.status == model.voice.unavailableReason, "Region microphone must request recording without creating another opinion")
    precondition(!canvas.rendersMarkersOnly, "Target-window selections must stay visible after mouse-up and during recording")
    let selectedRect = model.regions[0].rect
    model.voice.dictating = true
    try await Task.sleep(nanoseconds:30_000_000)
    precondition(model.paused && model.regions[0].rect == selectedRect && !canvas.rendersMarkersOnly)
    let bitmap = canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds)!
    canvas.cacheDisplay(in:canvas.bounds,to:bitmap)
    try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("persistent-target-selection.png"))
    precondition(window.frame == reviewScreenRect(shot.frame,desktopTop:model.panels.desktopTop))
    precondition(model.panels.overlay!.frame.width <= 350)
    precondition(model.panels.glow!.ignoresMouseEvents && model.panels.glow!.level.rawValue > window.level.rawValue)
    precondition(model.panels.toolbar!.level.rawValue > window.level.rawValue)
    model.voice.finishVoice(cancel:true)
    precondition(model.paused && model.regions[0].rect == selectedRect, "Ending voice must not discard the selection or exit review")
    let preview = model.panels.overlay!
    precondition(findCanvas(preview.contentView!) == nil, "Live Transcript must replace the screenshot preview")
    precondition(preview.title == "Chat Messages")
    precondition(model.transcriptFeed.count == 1 && model.transcriptFeed[0].regionID == model.selectedID)
    model.voice.draft = "Live synthetic transcription"
    precondition(model.transcriptFeed.last?.text == "Live synthetic transcription")
    canvas.layoutSubtreeIfNeeded()
    precondition(!canvas.subviews.contains(where:{$0 is NSSegmentedControl}), "Screenshot must not contain mode controls")
    precondition(model.inputMode == .audio, "Audio is the default")
    let controls = model.panels.toolbar!
    func clickMode() {
        for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
            let input = NSEvent.mouseEvent(with:type,location:CGPoint(x:91,y:19),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:controls.windowNumber,context:nil,eventNumber:3,clickCount:1,pressure:0)!
            controls.sendEvent(input)
        }
    }
    controls.contentView!.layoutSubtreeIfNeeded()
    await model.setInputMode(.text)
    try await Task.sleep(nanoseconds:50_000_000)
    while model.busy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(model.inputMode == .text && !model.voice.voiceActive)
    let point = CGPoint(x:canvas.bounds.width-10,y:canvas.bounds.height-10)
    window.sendEvent(event(.leftMouseDown,point)); window.sendEvent(event(.leftMouseUp,point))
    precondition(model.regions.count == 1, "Text single click must not create a region")
    window.sendEvent(event(.leftMouseDown,CGPoint(x:point.x-160,y:point.y-90)))
    window.sendEvent(event(.leftMouseDragged,point))
    window.sendEvent(event(.leftMouseUp,point))
    precondition(model.regions.count == 2 && model.regions.last?.isText == true)
    let textRegion = model.regions.last!
    precondition(textRegion.rect.maxX <= 1 && textRegion.rect.maxY <= 1, "Text input stays within screenshot")
    let field = canvas.subviews.compactMap { $0 as? NSTextField }.first!
    precondition(field.isEditable)
    window.makeKeyAndOrderFront(nil); window.makeFirstResponder(field)
    let editor = field.currentEditor() as! NSTextView
    editor.insertText("Text opinion typed on screenshot",replacementRange:NSRange(location:0,length:0))
    try await Task.sleep(nanoseconds:30_000_000)
    precondition(model.regions.last?.feedback == "Text opinion typed on screenshot")
    precondition(model.transcriptFeed.count == 2 && model.transcriptFeed.last?.text == "Text opinion typed on screenshot")
    precondition(model.transcriptFeed.first?.text == "Live synthetic transcription", "Switching must keep the previous transcript entry")
    model.toggleOpinionVoice()
    precondition(!model.voice.voiceActive && model.paused, "Text opinions never start recording")
    let encoded = try JSONEncoder().encode(model.regions)
    let decoded = try JSONDecoder().decode([ReviewRegion].self,from:encoded)
    precondition(decoded.last?.isText == true && decoded.last?.feedback == model.regions.last?.feedback)
    let textBitmap = canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds)!
    canvas.cacheDisplay(in:canvas.bounds,to:textBitmap)
    try textBitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("text-opinion-input.png"))
    await model.setInputMode(.audio)
    try await Task.sleep(nanoseconds:50_000_000)
    while model.busy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(model.inputMode == .audio && !field.isEditable)
    precondition(model.voice.status == model.voice.unavailableReason, "Returning to Audio must request recording for the selected opinion")
    let liveWindow = model.panels.overlay!, liveView = liveWindow.contentView!
    liveView.layoutSubtreeIfNeeded()
    precondition(liveView.acceptsFirstMouse(for:nil))
    liveWindow.makeKeyAndOrderFront(nil)
    let beforeBitmap = liveView.bitmapImageRepForCachingDisplay(in:liveView.bounds)!
    liveView.cacheDisplay(in:liveView.bounds,to:beforeBitmap)
    try beforeBitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("live-before-click.png"))
    let livePoint = CGPoint(x:30,y:liveView.isFlipped ? 61 : liveView.bounds.height-61)
    for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
        let input = NSEvent.mouseEvent(with:type,location:liveView.convert(livePoint,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:liveWindow.windowNumber,context:nil,eventNumber:9,clickCount:1,pressure:0)!
        liveWindow.sendEvent(input)
    }
    try await Task.sleep(nanoseconds:50_000_000)
    while model.busy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(model.selectedID == model.regions.first?.id, "Clicking the transcript number must switch opinions")
    precondition(model.transcriptFeed.count == 3, "Returning to an earlier opinion appends a transcript record")
    model.voice.draft = "Live synthetic transcription continued"
    precondition(model.transcriptFeed.first?.text == "Live synthetic transcription")
    precondition(model.transcriptFeed.last?.text == "Live synthetic transcription continued")
    try await Task.sleep(nanoseconds:50_000_000)
    let liveBitmap = liveView.bitmapImageRepForCachingDisplay(in:liveView.bounds)!
    liveView.cacheDisplay(in:liveView.bounds,to:liveBitmap)
    try liveBitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("live-transcript.png"))
    model.panels.hideForWorkspace(); precondition(!window.isVisible)
    model.panels.positionSidebar(shot.frame); precondition(window.isVisible)
    let escape = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!
    NSApp.sendEvent(escape)
    try await Task.sleep(nanoseconds:50_000_000)
    while model.busy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(model.active && !model.paused, "Escape exits review without ending the bound session")
    precondition(model.panels.selectionOverlay == nil, "Exit must return mouse input to the target app")
    model.panels.close()
    print("PASS: native Audio drag, Text insertion/editing, edge clamping, persistence and mode switching")
    exit(0)
}
Task { try await Task.sleep(nanoseconds:15_000_000_000); fatalError("Selection test timed out") }
app.run()
