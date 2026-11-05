import Cocoa
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-region-edit-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let model = ReviewModel(storageRoot:root)
    model.active = true; model.paused = true
    model.voice.unavailableReason = "fixture: microphone disabled"
    let image = NSImage(size:CGSize(width:800,height:600),flipped:false) { rect in NSColor.white.setFill();rect.fill();return true }
    let shot = ReviewSnapshot(id:UUID(),image:image,png:try reviewPNG(image),frame:CGRect(x:100,y:100,width:800,height:600))
    let region = ReviewRegion(snapshotID:shot.id,number:1,rect:CGRect(x:0.2,y:0.2,width:0.3,height:0.3),feedback:"Keep this opinion",isText:true)
    model.current = shot; model.snapshots = [shot]; model.regions = [region]; model.selectedID = region.id
    model.panels.showOverlay(shot)
    @MainActor func canvas() -> ReviewCanvas { model.panels.selectionOverlay!.contentView as! ReviewCanvas }
    @MainActor func rect() -> CGRect { let r = model.regions[0].rect, size = canvas().bounds.size; return CGRect(x:r.minX*size.width,y:r.minY*size.height,width:r.width*size.width,height:r.height*size.height) }
    @MainActor func input(_ type:NSEvent.EventType,_ point:CGPoint) {
        let view = canvas(), window = view.window!
        let event = NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:0)!
        window.sendEvent(event)
    }
    @MainActor func drag(_ from:CGPoint,_ to:CGPoint) {
        input(.leftMouseDown,from); input(.leftMouseDragged,to); input(.leftMouseUp,to)
    }
    canvas().layoutSubtreeIfNeeded()
    var r = rect()
    drag(CGPoint(x:r.minX+5,y:r.minY+5),CGPoint(x:r.minX+65,y:r.minY+45))
    precondition(model.regions.count == 1 && abs(rect().minX-r.minX-60) < 0.1 && abs(rect().minY-r.minY-40) < 0.1)
    precondition(model.regions[0].feedback == region.feedback && model.canUndo)
    model.updateOpinion(region.id,text:"Edited after move")
    await model.undoEdit()
    precondition(model.regions[0].rect == region.rect && model.regions[0].feedback == "Edited after move")
    r = rect()
    drag(CGPoint(x:r.maxX,y:r.midY),CGPoint(x:r.maxX+80,y:r.midY+45))
    precondition(abs(rect().width-r.width-80) < 0.1 && abs(rect().height-r.height) < 0.1 && rect().origin == r.origin)
    await model.undoEdit()
    r = rect()
    drag(CGPoint(x:r.midX,y:r.maxY),CGPoint(x:r.midX+100,y:r.maxY+60))
    precondition(abs(rect().height-r.height-60) < 0.1 && abs(rect().width-r.width) < 0.1)
    await model.undoEdit()
    r = rect()
    drag(CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:1200,y:1000))
    precondition(abs(model.regions[0].rect.maxX-1) < 0.001 && abs(model.regions[0].rect.maxY-1) < 0.001)
    await model.undoEdit()
    r = rect()
    input(.leftMouseDown,CGPoint(x:r.maxX-8,y:r.minY+8)); input(.leftMouseUp,CGPoint(x:r.maxX-8,y:r.minY+8))
    try await Task.sleep(nanoseconds:50_000_000)
    while model.busy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(model.regions.isEmpty, "Close deletes both region and opinion")
    await model.undoEdit()
    precondition(model.regions.count == 1 && model.regions[0].id == region.id && model.regions[0].feedback == "Edited after move")
    r = rect()
    drag(CGPoint(x:r.minX+5,y:r.minY+5),CGPoint(x:-200,y:-200))
    precondition(model.regions[0].rect.minX == 0 && model.regions[0].rect.minY == 0)
    let field = canvas().subviews.compactMap { $0 as? NSTextField }.first!
    precondition(abs(field.frame.minX-6) < 0.1 && abs(field.frame.minY-25) < 0.1)
    let view = canvas(), bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
    view.cacheDisplay(in:view.bounds,to:bitmap)
    try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("region-edit.png"))
    model.panels.close()
    print("PASS: native badge drag, right/bottom/corner resize, bounds, close, undo and text preservation")
    exit(0)
}
Task { try await Task.sleep(nanoseconds:20_000_000_000); fatalError("Region edit test timed out") }
app.run()
