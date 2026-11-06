import Cocoa
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    for heard in ["小莫小莫 能听到吗","小莫小莫能听到吗? 听到回复一声","小魔小魔，看下这里","晓墨晓墨","小墨，在吗","xiao mo xiao mo"] {
        precondition(moIsAddressed(heard), "Homophones of the wake word must wake: \(heard)")
    }
    for other in ["这里改成蓝色","别消磨时间","小明说的方案","名字叫小墨"] {
        precondition(!moIsAddressed(other), "Must not wake: \(other)")
    }
    let quiet = MoLiveSession()
    quiet.receive(["type":"session.input_transcript.delta","event_id":"plain","delta":"这里改成蓝色","start_ms":0,"end_ms":500])
    quiet.receive(["type":"session.output_transcript.delta","event_id":"not-addressed","delta":"不会显示","start_ms":600,"end_ms":800])
    precondition(quiet.messages.count == 1 && !quiet.mayReply)
    quiet.receive(["type":"session.input_transcript.delta","event_id":"wake","delta":"小墨小墨，你怎么看？","start_ms":4000,"end_ms":4500])
    precondition(quiet.mayReply)
    quiet.receive(["type":"session.output_transcript.delta","event_id":"answer","delta":"我建议提高对比度。","start_ms":4600,"end_ms":5000])
    precondition(quiet.messages.last?.role == "assistant")
    quiet.suppressReplies()
    quiet.receive(["type":"session.input_transcript.delta","event_id":"late-wake","delta":"小墨小墨","start_ms":7000,"end_ms":7500])
    let count = quiet.messages.count
    quiet.receive(["type":"session.output_transcript.delta","event_id":"suppressed","delta":"不能回复","start_ms":7600,"end_ms":8000])
    precondition(!quiet.mayReply && quiet.messages.count == count, "Late wake must not reenable replies after silence")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mo-unified-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let model = ReviewModel(storageRoot:root)
    model.active = true; model.paused = true; model.listeningEnabled = false
    model.voice.unavailableReason = "fixture"
    let image = NSImage(size:CGSize(width:600,height:400),flipped:false) { r in NSColor.white.setFill();r.fill();return true }
    let shot = ReviewSnapshot(id:UUID(),image:image,png:try reviewPNG(image),frame:CGRect(x:100,y:100,width:900,height:620))
    let region = ReviewRegion(snapshotID:shot.id,number:1,rect:CGRect(x:0.1,y:0.1,width:0.3,height:0.3),feedback:"已有意见")
    model.snapshots = [shot]; model.current = shot; model.regions = [region]; model.selectedID = region.id
    model.voice.loadDraft(region.feedback)
    model.live.receive(["type":"session.input_transcript.delta","event_id":"live-input","delta":"小墨小墨，帮我检查对比度。","start_ms":0,"end_ms":500])
    precondition(model.regions[0].feedback == "已有意见 小墨小墨，帮我检查对比度。")
    model.live.receive(["type":"session.output_transcript.delta","event_id":"live-reply","delta":"建议提高文字对比度。","start_ms":600,"end_ms":900])
    var rows = moConversationRows(model)
    precondition(rows.count == 2 && rows[0].title == "小墨 · #1" && rows[1].title == "小墨")
    model.listeningEnabled = true
    model.voice.unavailableReason = nil
    let before = model.regions[0].feedback
    model.resumeLocalListening(begin:{
        model.voice.prepareRecognitionDraft()
        model.voice.receiveTranscript("静默追加的新意见",final:false,failed:false)
    })
    precondition(model.regions[0].feedback == before+" 静默追加的新意见", "Silent recognition must append to the latest live opinion, not stale draft")
    model.voice.unavailableReason = "fixture"
    model.setSpeakingEnabled(false)
    while model.busy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(!model.speakingEnabled && !model.live.active, "Silent mode must never start a remote session")
    try await model.persist()
    let folder = try await ReviewStore().latest(root:root)!
    let payload = try await ReviewStore().load(folder:folder)
    precondition(payload.session.transcriptRecords?.first?.text == model.regions[0].feedback)
    precondition(payload.session.chatMessages?.last?.role == "assistant")
    model.panels.showOverlay(shot)
    try await Task.sleep(nanoseconds:60_000_000)
    let view = model.panels.overlay!.contentView!
    view.layoutSubtreeIfNeeded()
    let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
    view.cacheDisplay(in:view.bounds,to:bitmap)
    try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("mo-unified-conversation.png"))
    model.panels.close()
    print("PASS: silent reply suppression, wake gating, late wake isolation, live opinion synchronization, merged numbered notes, persistence and unified rendering; no API or microphone used")
    exit(0)
}
Task { try await Task.sleep(nanoseconds:20_000_000_000); fatalError("Unified test timed out") }
app.run()
