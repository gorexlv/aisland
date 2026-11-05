// Synthetic history editing, never accesses the microphone or external apps.
import Cocoa
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-test-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let model = ReviewModel(storageRoot:root)
    let image = NSImage(size:CGSize(width:480,height:300),flipped:false) { rect in
        NSColor(calibratedWhite:0.96,alpha:1).setFill();rect.fill()
        ("Review fixture" as NSString).draw(at:CGPoint(x:30,y:220),withAttributes:[.font:NSFont.systemFont(ofSize:25),.foregroundColor:NSColor.gray]);return true
    }
    let png = try reviewPNG(image)
    model.active = true; model.paused = true
    model.snapshots = (0..<5).map { _ in ReviewSnapshot(id:UUID(),image:image,png:png,frame:CGRect(x:100,y:100,width:900,height:620)) }
    model.regions = model.snapshots.enumerated().map { i,s in ReviewRegion(snapshotID:s.id,number:i+1,rect:CGRect(x:0.1,y:0.1,width:0.2,height:0.2),feedback:"Original opinion \(i+1)") }
    model.regions[4].transcript = [VoiceTranscriptEntry(recordedAt:Date(timeIntervalSince1970:1793925128),text:"标题的层级需要更清楚，重要信息可以前置。"),VoiceTranscriptEntry(recordedAt:Date(timeIntervalSince1970:1793925135),text:"第二段保留在同一条意见里，时间按实际录音保存。")]
    model.current = model.snapshots.last; model.selectedID = model.regions.last!.id
    model.voice.draft = model.regions.last!.feedback
    model.panels.showOverlay(model.current!)
    model.panels.showEditor()
    model.voice.dictating = true; model.openHistory(); precondition(!model.historyPresented)
    model.voice.dictating = false; model.voice.voicePreparing = true; model.openHistory(); precondition(!model.historyPresented)
    model.voice.voicePreparing = false; model.openHistory()
    precondition(model.historyPresented && model.panels.history?.isVisible == true && !model.canSwitchSnapshots)
    precondition(model.panels.sidebar?.isVisible == false, "Legacy editor must not remain interactive behind the modal")
    model.select(model.regions[0].id,speak:true)
    precondition(model.selectedID == model.regions.last!.id && !model.busy)
    model.resume(); precondition(!model.paused && !model.busy)
    let completionAllowed = await model.prepareCompletion(); precondition(completionAllowed && model.historyPresented, "Merged entry reveals the existing history window")
    precondition(model.panels.selectionOverlay == nil && model.panels.overlay == nil && model.panels.glow?.isVisible != true, "Opening history must release the original application")
    precondition(model.panels.history!.level == .normal && !model.panels.history!.hidesOnDeactivate)
    let current = model.current!.id
    model.selectSnapshot(model.snapshots[0].id); precondition(model.current!.id == current)
    model.toggleSinglePage(); precondition(!model.paused)
    model.updateOpinion(model.regions[0].id,text:"Updated first opinion")
    precondition(model.voice.draft == "Original opinion 5", "Editing another screenshot must not replace the current voice draft")
    model.updateOpinion(model.regions[4].id,text:"Updated last opinion")
    precondition(model.voice.draft == "Updated last opinion")
    try await Task.sleep(nanoseconds:600_000_000)
    let store = ReviewStore(), folder = try await store.latest(root:root)!
    let saved = try await store.load(folder:folder)
    precondition(saved.session.regions[0].feedback == "Updated first opinion" && saved.session.regions[4].feedback == "Updated last opinion")
    let extra = ReviewRegion(snapshotID:model.snapshots[4].id,number:6,rect:CGRect(x:0.6,y:0.55,width:0.25,height:0.25),feedback:"Click this region")
    model.regions.append(extra)
    try await Task.sleep(nanoseconds:100_000_000)
    let host = model.panels.history!.contentView!
    host.layoutSubtreeIfNeeded()
    func findImage(_ view:NSView) -> ReviewHistoryImageView? {
        if let image = view as? ReviewHistoryImageView { return image }
        return view.subviews.compactMap { findImage($0) }.first
    }
    let large = findImage(host)!
    let fitted = reviewHistoryImageRect(size:image.size,bounds:large.bounds.insetBy(dx:12,dy:12))
    precondition(fitted.width > 400, "Selected image must be larger than a thumbnail")
    let point = CGPoint(x:fitted.minX+fitted.width*0.7,y:fitted.minY+fitted.height*0.65)
    precondition(reviewHistoryRegion(at:point,in:fitted,regions:model.regions.filter{$0.snapshotID == model.snapshots[4].id}) == extra.id)
    precondition(reviewHistoryRegion(at:CGPoint(x:-1,y:-1),in:fitted,regions:model.regions) == nil)
    let event = NSEvent.mouseEvent(with:.leftMouseDown,location:large.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:model.panels.history!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
    model.panels.history!.sendEvent(event)
    try await Task.sleep(nanoseconds:100_000_000)
    func findEditor(_ view:NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.isEditable { return text }
        return view.subviews.compactMap { findEditor($0) }.first
    }
    let editor = findEditor(host)!
    let replacement = NSRange(location:0,length:editor.string.utf16.count)
    editor.insertText("Edited through native text input",replacementRange:replacement)
    try await Task.sleep(nanoseconds:600_000_000)
    precondition(model.regions[5].feedback == "Edited through native text input" && model.regions[4].feedback == "Updated last opinion", "Clicking the image region must select the matching opinion editor")
    let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds)!
    host.cacheDisplay(in:host.bounds,to:bitmap)
    try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("history-modal.png"))
    model.panels.hideForWorkspace(); precondition(model.panels.history?.isVisible == true, "History must remain independent of the target workspace")
    model.panels.positionSidebar(model.current!.frame); precondition(model.panels.history?.isVisible == true)
    await model.dismissHistory()
    precondition(!model.historyPresented && model.panels.history == nil && !model.paused)
    model.panels.close()
    let blocker = root.appendingPathComponent("blocker");try Data().write(to:blocker)
    let failed = ReviewModel(storageRoot:blocker)
    failed.active = true; failed.snapshots = [model.snapshots[0]]; failed.regions = [model.regions[0]]
    failed.openHistory(); failed.updateOpinion(failed.regions[0].id,text:"Keep unsaved text")
    await failed.dismissHistory()
    precondition(failed.historyPresented && failed.panels.history != nil && failed.regions[0].feedback == "Keep unsaved text" && failed.status.contains("失败"))
    failed.panels.close()
    print("PASS: nonmodal history releases target, large image region click selects opinion, native editing, autosave and failure retention")
    exit(0)
}
Task { try await Task.sleep(nanoseconds:20_000_000_000);fatalError("History tests timed out") }
app.run()
