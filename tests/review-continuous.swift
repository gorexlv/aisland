import Cocoa
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mo-continuous-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let model = ReviewModel(storageRoot:root)
    model.active = true; model.paused = true; model.listeningEnabled = false; model.voice.unavailableReason = "fixture"
    let image = NSImage(size:CGSize(width:600,height:400),flipped:false) { r in NSColor.white.setFill();r.fill();return true }
    let shot = ReviewSnapshot(id:UUID(),image:image,png:try reviewPNG(image),frame:CGRect(x:100,y:100,width:900,height:620))
    let one = ReviewRegion(snapshotID:shot.id,number:1,rect:CGRect(x:0.1,y:0.1,width:0.2,height:0.2))
    let two = ReviewRegion(snapshotID:shot.id,number:2,rect:CGRect(x:0.5,y:0.5,width:0.2,height:0.2))
    model.snapshots = [shot]; model.current = shot; model.regions = [one,two]; model.selectedID = one.id
    let live = model.live
    live.bindRegion(one.id,atMS:0)
    func event(_ id:String,_ text:String,_ start:Int,_ end:Int) -> [String:Any] {
        ["type":"session.input_transcript.delta","event_id":id,"delta":text,"start_ms":start,"end_ms":end]
    }
    live.receive(event("a","小墨小墨，第一条",100,400))
    precondition(live.mayReply)
    model.select(two.id)
    while model.busy { try await Task.sleep(nanoseconds:1_000_000) }
    live.bindRegion(two.id,atMS:1000)
    live.receive(event("b","第二条",1200,1400))
    live.receive(event("late-a","的尾句",500,800))
    precondition(model.regions[0].feedback == "小墨小墨，第一条的尾句" && model.regions[1].feedback == "第二条", "Delayed old captions must retain their original opinion")
    precondition(live.mayReply, "An ordinary partial caption must not cut off an authorized reply")
    model.select(one.id)
    while model.busy { try await Task.sleep(nanoseconds:1_000_000) }
    live.bindRegion(one.id,atMS:2000)
    live.receive(event("new-a","补充",2200,2400))
    live.receive(event("late-a-2","结束",850,900))
    precondition(model.regions[0].feedback == "小墨小墨，第一条的尾句结束 补充", "Late text must not overwrite newer contributions")
    precondition(live.messages.filter{$0.role == "user"}.count == 3, "Returning to a region starts a new binding interval")
    try await model.persist()
    let folder = try await ReviewStore().latest(root:root)!
    let saved = try await ReviewStore().load(folder:folder)
    precondition(saved.session.regions[0].feedback == model.regions[0].feedback)
    live.suppressReplies()
    live.receive(event("silenced","小墨小墨",2600,2800))
    precondition(!live.mayReply)
    model.panels.close()
    print("PASS: continuous region bindings, delayed caption ownership, A/B/A transitions, no late overwrite, reply continuity, silent suppression and persistence; no API or microphone used")
    exit(0)
}
Task { try await Task.sleep(nanoseconds:20_000_000_000); fatalError("Continuous test timed out") }
app.run()
