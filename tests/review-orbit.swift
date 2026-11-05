// Synthetic windows/audio only: never records, writes Notes or launches Codex.
import Cocoa
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-test-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let model = ReviewModel(storageRoot:root)
    model.voice.unavailableReason = "Synthetic test; microphone disabled"
    model.active = true
    model.target = ScreenTarget(id:1,pid:-1,app:"Fixture",bundleID:"fixture",title:"Orbit")
    let area = NSScreen.main!.visibleFrame
    let target = CGRect(x:area.minX+30,y:area.minY+30,width:min(900,area.width-60),height:min(620,area.height-60))
    model.panels.positionSidebar(reviewScreenRect(target,desktopTop:model.panels.desktopTop))
    precondition(model.panels.sidebar?.isVisible != true, "Selected target must use the orb, not the old sidebar")
    precondition(target.contains(model.panels.toolbar!.frame))
    let picture = NSImage(size:CGSize(width:600,height:400),flipped:false) { rect in
        NSColor(calibratedWhite:0.97,alpha:1).setFill(); rect.fill()
        ("Review fixture" as NSString).draw(at:CGPoint(x:40,y:320),withAttributes:[.font:NSFont.systemFont(ofSize:30),.foregroundColor:NSColor.darkGray])
        for y in [260,220,180] { NSColor.lightGray.setFill(); CGRect(x:40,y:y,width:420,height:8).fill() }
        return true
    }
    let png = try reviewPNG(picture)
    model.snapshots = (0..<5).map { _ in ReviewSnapshot(id:UUID(),image:picture,png:png,frame:reviewScreenRect(target,desktopTop:model.panels.desktopTop)) }
    model.current = model.snapshots.last; model.paused = true
    let first = ReviewRegion(snapshotID:model.current!.id,number:1,rect:CGRect(x:0.1,y:0.1,width:0.2,height:0.2))
    let second = ReviewRegion(snapshotID:model.current!.id,number:2,rect:CGRect(x:0.5,y:0.3,width:0.2,height:0.2))
    model.regions = [first,second]; model.selectedID = first.id
    model.panels.showOverlay(model.current!)
    precondition(model.panels.overlay!.frame.width <= 350 && model.panels.overlay!.frame.height <= 240)
    precondition(model.panels.glow?.isVisible == true && model.panels.glow?.ignoresMouseEvents == true)
    precondition(target.contains(model.panels.overlay!.frame))
    precondition(abs(model.panels.overlay!.frame.maxX-(target.maxX-12)) < 0.01)
    model.panels.moveOrb(to:CGPoint(x:target.minX-500,y:target.maxY+500))
    precondition(target.contains(model.panels.toolbar!.frame))
    precondition(abs(model.panels.overlay!.frame.minX-(target.minX+12)) < 0.01)
    model.panels.moveOrb(to:CGPoint(x:target.maxX-80,y:target.maxY-140))
    for frame in [CGRect(x:-1200,y:-200,width:800,height:600),CGRect(x:0,y:0,width:150,height:120)] {
        for relative in [CGPoint(x:-2,y:-2),CGPoint(x:3,y:3)] {
            let layout = reviewOrbitLayout(target:frame,relative:relative)
            precondition(frame.insetBy(dx:-0.001,dy:-0.001).contains(layout.controls))
            precondition(frame.insetBy(dx:-0.001,dy:-0.001).contains(layout.preview))
            precondition(layout.preview.maxY < layout.anchor.y)
        }
    }
    let currentID = model.current!.id
    model.voice.voicePreparing = true; model.selectSnapshot(model.snapshots[0].id); precondition(model.current!.id == currentID)
    model.voice.voicePreparing = false; model.voice.dictating = true
    model.selectSnapshot(model.snapshots[0].id); precondition(model.current!.id == currentID)
    model.select(second.id)
    while !model.voice.voiceFinishing { try await Task.sleep(nanoseconds:1_000_000) }
    model.voice.receiveTranscript("first final",final:true,failed:false)
    while model.busy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(model.regions[0].feedback == "first final" && model.regions[1].feedback.isEmpty)
    precondition(model.selectedID == second.id && model.voice.status == model.voice.unavailableReason)
    model.selectSnapshot(model.snapshots[0].id); precondition(model.current!.id == model.snapshots[0].id)
    model.selectSnapshot(currentID); model.selectedID = second.id
    model.voice.dictating = true
    try await Task.sleep(nanoseconds:150_000_000)
    @MainActor func viewImage(_ view:NSView) -> NSImage {
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
        view.cacheDisplay(in:view.bounds,to:bitmap)
        return NSImage(data:bitmap.representation(using:.png,properties:[:])!)!
    }
    let layerImages = [model.panels.glow!,model.panels.overlay!,model.panels.toolbar!].map { (viewImage($0.contentView!),$0.frame) }
    let composite = NSImage(size:target.size,flipped:false) { bounds in
        NSColor(calibratedWhite:0.94,alpha:1).setFill(); bounds.fill()
        ("Target application · synthetic fixture" as NSString).draw(at:CGPoint(x:35,y:bounds.height-70),withAttributes:[.font:NSFont.systemFont(ofSize:20),.foregroundColor:NSColor.gray])
        for (image,frame) in layerImages { image.draw(in:frame.offsetBy(dx:-target.minX,dy:-target.minY)) }
        return true
    }
    let destination = URL(fileURLWithPath:CommandLine.arguments[1])
    try reviewPNG(composite).write(to:destination.appendingPathComponent("orbit-v11.png"))
    let completing = Task { await model.prepareCompletion() }
    while !model.voice.voiceFinishing { try await Task.sleep(nanoseconds:1_000_000) }
    model.voice.receiveTranscript("second final",final:true,failed:false)
    let completed = await completing.value
    precondition(completed && model.completed && !model.paused && !model.voice.voiceActive)
    precondition(model.panels.overlay == nil && model.panels.glow?.isVisible == false && model.panels.history?.isVisible == true)
    precondition(model.historyPresented && model.panels.completion == nil, "Merged completion opens history without an export popup")
    model.panels.hideForWorkspace()
    precondition(model.panels.history?.isVisible == true)
    let reopened = await model.prepareCompletion()
    precondition(reopened && model.panels.history?.isVisible == true)
    let store = ReviewStore(), folder = try await store.latest(root:root)!
    let packet = try await store.prepareReviewFiles(folder:folder)
    precondition(packet.images.count == 5 && packet.comments.contains("second final"))
    let script = NSAppleScript(source:notesScript(title:"Review",text:packet.comments,attachmentPaths:packet.images.map(\.path)))!
    var scriptError:NSDictionary?
    precondition(script.compileAndReturnError(&scriptError), "Notes attachments script must compile")
    #if !APP_STORE
    let command = try createReviewCodexCommand(packet)
    let syntax = Process(); syntax.executableURL = URL(fileURLWithPath:"/bin/zsh"); syntax.arguments = ["-n",command.path]
    try syntax.run(); syntax.waitUntilExit(); precondition(syntax.terminationStatus == 0)
    let text = try String(contentsOf:command,encoding:.utf8)
    precondition(text.contains("--image") && text.contains("read-only") && text.contains("comments.txt"))
    #endif
    model.panels.close()
    print("PASS: orb-only selected UI, bounded drag, edge-aligned aspect preview, glow, voice locks and ownership, completion persistence/restoration, Notes attachment syntax and Codex command syntax")
    exit(0)
}
Task { try await Task.sleep(nanoseconds:20_000_000_000); fatalError("Orbit tests timed out") }
app.run()
