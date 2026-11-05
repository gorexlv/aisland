import Cocoa
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
func pause(_ seconds:Double = 0.02) async throws { try await Task.sleep(nanoseconds:UInt64(seconds * 1_000_000_000)) }
func fixtureSummary(_ sources:[MoSummarySource]) -> MoSummaryContent {
    MoSummaryContent(overview:[MoSummaryItem(text:"Current discussion",sourceIDs:[sources[0].id],status:"fact")],decisions:[MoSummaryItem(text:"Use compact icons",sourceIDs:[sources[0].id],status:"confirmed")],todos:[],questions:[])
}
final class SummaryProbe: @unchecked Sendable {
    let lock = NSLock()
    private var calls = 0
    private var running = 0
    private var peak = 0
    func run(_ sources:[MoSummarySource],_ cancellation:SaveCancellation?) throws -> MoSummaryContent {
        lock.lock(); calls += 1; running += 1; peak = max(peak,running); lock.unlock()
        defer { lock.lock(); running -= 1; lock.unlock() }
        Thread.sleep(forTimeInterval:0.09)
        return fixtureSummary(sources)
    }
    var counts:(Int,Int) { lock.lock(); defer { lock.unlock() }; return (calls,peak) }
}
Task { @MainActor in
    let a = MoSummarySource(id:"region:a",role:"user",regionNumber:1,text:"Use compact icons")
    let b = MoSummarySource(id:"chat:b",role:"assistant",regionNumber:nil,text:"How about green?")
    let valid = fixtureSummary([a])
    try valid.validate(sources:[a])
    var invalid = valid
    invalid.decisions = [MoSummaryItem(text:"Invented",sourceIDs:["missing"],status:"confirmed")]
    do { try invalid.validate(sources:[a]); fatalError("Unknown source accepted") } catch { }
    invalid.decisions = [MoSummaryItem(text:"Invented",sourceIDs:[],status:"confirmed")]
    do { try invalid.validate(sources:[a]); fatalError("Unsourced item accepted") } catch { }
    invalid.decisions = [MoSummaryItem(text:"Invented",sourceIDs:[a.id],status:"done")]
    do { try invalid.validate(sources:[a]); fatalError("Invalid decision status accepted") } catch { }
    invalid.decisions = [MoSummaryItem(text:"Unconfirmed assistant suggestion",sourceIDs:[b.id],status:"confirmed")]
    do { try invalid.validate(sources:[a,b]); fatalError("Assistant-only confirmation accepted") } catch { }
    let probe = SummaryProbe()
    let controller = MoLiveSummary(debounce:0.04,maxWait:0.1,analyze:{ try probe.run($0,$1) })
    controller.update(sources:[a]); try await pause(0.06)
    precondition(probe.counts.0 == 0, "Live must be opt-in")
    controller.setEnabled(true)
    try await pause(0.06)
    controller.update(sources:[a,b])
    try await pause(0.3)
    precondition(probe.counts.0 == 2 && probe.counts.1 == 1, "Updates during a request must rerun without overlap")
    precondition(controller.memory?.sources == [a,b])
    let previous = controller.memory
    let empty = MoLiveSummary(debounce:0.01,maxWait:0.02,analyze:{ try probe.run($0,$1) })
    empty.restore(memory:previous); empty.update(sources:[a]); empty.setEnabled(true)
    try await pause(0.03)
    empty.update(sources:[])
    try await pause(0.12)
    precondition(empty.memory == nil && !empty.outdated && !empty.updating, "Deleting every source must clear old memory and reject in-flight results")
    empty.setEnabled(false)
    controller.update(sources:[b]); try await pause(0.06)
    controller.setEnabled(false)
    try await pause(0.15)
    precondition(controller.memory == previous && !controller.updating, "Disabled summary must reject late results and retain memory")
    controller.reset()
    precondition(controller.memory == nil && !controller.enabled)
    let continuous = MoLiveSummary(debounce:0.08,maxWait:0.1,analyze:{ try probe.run($0,$1) })
    continuous.update(sources:[a]); continuous.setEnabled(true)
    for n in 0..<8 { continuous.update(sources:[MoSummarySource(id:a.id,role:a.role,regionNumber:1,text:"partial \(n)")]); try await pause(0.02) }
    precondition(probe.counts.0 >= 5, "Continuous speech must not starve the bounded timer")
    continuous.setEnabled(false)
    let failing = MoLiveSummary(debounce:0.01,maxWait:0.02,analyze:{ _,_ in throw NotesFailure(detail:"offline") })
    failing.restore(memory:previous)
    failing.update(sources:[b]); failing.setEnabled(true); try await pause(0.08)
    precondition(failing.memory == previous && failing.error == "offline")
    failing.setEnabled(false)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-summary-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let model = ReviewModel(storageRoot:root,liveSummary:MoLiveSummary(debounce:0.01,maxWait:0.02,analyze:{ try probe.run($0,$1) }))
    model.active = true
    model.voice.unavailableReason = "fixture"
    let image = NSImage(size:CGSize(width:200,height:100),flipped:false) { r in NSColor.white.setFill();r.fill();return true }
    let shot = ReviewSnapshot(id:UUID(),image:image,png:try reviewPNG(image),frame:CGRect(x:100,y:100,width:900,height:620))
    let region = ReviewRegion(snapshotID:shot.id,number:1,rect:CGRect(x:0.1,y:0.1,width:0.5,height:0.5),feedback:a.text)
    model.snapshots = [shot]; model.current = shot; model.regions = [region]
    model.live.messages = [MoChatMessage(role:"user",text:"duplicate voice",startMS:0,endMS:1,regionID:region.id),MoChatMessage(role:"assistant",text:b.text,startMS:0,endMS:1)]
    precondition(model.liveSummarySources.count == 2 && model.liveSummarySources[0].regionNumber == 1, "Canonical opinions must not duplicate bound live captions")
    let savedRegions = model.regions
    model.regions = []
    precondition(model.liveSummarySources.count == 1 && model.liveSummarySources[0].role == "assistant", "Deleted opinions must not return through old bound user captions")
    model.regions = savedRegions
    model.liveSummary.restore(memory:previous)
    model.chatDraft = "Keep this draft"
    try await model.persist()
    let folder = try await ReviewStore().latest(root:root)!
    precondition(FileManager.default.fileExists(atPath:folder.appendingPathComponent("memory.json").path))
    let markdown = try String(contentsOf:folder.appendingPathComponent("memory.md"),encoding:.utf8)
    precondition(markdown.contains("#1"))
    let restored = ReviewModel(storageRoot:root)
    try await restored.restore(folder:folder,presentPanels:false)
    precondition(restored.liveSummary.memory == previous && !restored.liveSummary.enabled)
    let stored = try Data(contentsOf:folder.appendingPathComponent("session.json"))
    var legacy = try JSONSerialization.jsonObject(with:stored) as! [String:Any]
    legacy.removeValue(forKey:"liveSummaryMemory")
    let decoded = try JSONDecoder().decode(StoredReviewSession.self,from:JSONSerialization.data(withJSONObject:legacy))
    precondition(decoded.liveSummaryMemory == nil)
    model.paused = true; model.listeningEnabled = false
    model.panels.showOverlay(shot)
    model.setLiveSummary(true)
    try await pause(0.2)
    let window = model.panels.overlay!, view = window.contentView!
    @MainActor func editor(_ view:NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.isEditable { return text }
        return view.subviews.compactMap { editor($0) }.first
    }
    @MainActor func click(_ x:CGFloat) async throws {
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        let point = CGPoint(x:x,y:view.isFlipped ? 18 : view.bounds.height-18)
        func event(_ type:NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:0)!
        }
        // Native switches may run a tracking loop inside mouseDown; prequeue its
        // release while routing both events to this fixture's own window.
        NSApp.postEvent(event(.leftMouseUp),atStart:false)
        window.sendEvent(event(.leftMouseDown))
        window.sendEvent(event(.leftMouseUp))
        try await pause(0.08)
    }
    precondition(editor(view) != nil)
    func capture(_ name:String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
        view.cacheDisplay(in:view.bounds,to:bitmap)
        try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(name+".png"))
    }
    try capture("live-summary-before")
    try await click(85)
    try capture("live-summary-after")
    precondition(editor(view) == nil, "Summary Tab must show summary instead of the composer")
    let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
    view.cacheDisplay(in:view.bounds,to:bitmap)
    try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("live-summary-tab.png"))
    try await click(25)
    precondition(editor(view)?.string == "Keep this draft", "Chat draft must survive switching tabs")
    try await click(85)
    try await click(225)
    precondition(!model.liveSummary.enabled, "Live switch must turn off extraction")
    precondition(editor(view)?.string == "Keep this draft", "Turning Live off must return to Chat")
    // Closing must cancel extraction before waiting for final audio/persistence.
    model.setLiveSummary(true)
    model.updateOpinion(region.id,text:"changed just before closing")
    let closed = await model.closeForTermination()
    precondition(closed && !model.liveSummary.enabled)
    try await pause(0.55)
    let final = try await ReviewStore().load(folder:folder)
    precondition(final.session.liveSummaryMemory == model.liveSummary.memory)
    model.liveSummary.reset()
    try await model.persist()
    precondition(!FileManager.default.fileExists(atPath:folder.appendingPathComponent("memory.json").path))
    precondition(!FileManager.default.fileExists(atPath:folder.appendingPathComponent("memory.md").path))
    model.panels.close(); restored.panels.close()
    print("PASS: Live opt-in, bounded debounce, single flight, cancellation, source validation/deduplication, memory persistence and legacy recovery")
    exit(0)
}
Task { try await Task.sleep(nanoseconds:20_000_000_000); fatalError("Live Summary tests timed out") }
app.run()
