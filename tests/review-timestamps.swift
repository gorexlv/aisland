import Cocoa
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let start = Date(timeIntervalSince1970:1000)
    let entries = timedVoiceTranscript("hello world next phrase",tokens:[VoiceTimedToken(range:NSRange(location:0,length:5),offset:0.2),VoiceTimedToken(range:NSRange(location:6,length:5),offset:1),VoiceTimedToken(range:NSRange(location:12,length:4),offset:4),VoiceTimedToken(range:NSRange(location:17,length:6),offset:5)],startedAt:start)
    precondition(entries.count == 2 && entries[0].text == "hello world" && entries[1].text == "next phrase")
    precondition(entries[0].recordedAt == start.addingTimeInterval(0.2) && entries[1].recordedAt == start.addingTimeInterval(4))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("timed-review-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let model = ReviewModel(storageRoot:root)
    model.voice.unavailableReason = "fixture"
    let image = NSImage(size:CGSize(width:100,height:100),flipped:false) { rect in NSColor.white.setFill();rect.fill();return true }
    let shot = ReviewSnapshot(id:UUID(),image:image,png:try reviewPNG(image),frame:CGRect(x:0,y:0,width:100,height:100))
    let one = ReviewRegion(snapshotID:shot.id,number:1,rect:CGRect(x:0.1,y:0.1,width:0.2,height:0.2))
    let two = ReviewRegion(snapshotID:shot.id,number:2,rect:CGRect(x:0.5,y:0.5,width:0.2,height:0.2))
    model.snapshots = [shot]; model.current = shot; model.regions = [one,two]; model.selectedID = one.id
    model.voice.receiveTranscript("hello world next phrase",final:false,failed:false,timings:entries)
    precondition(model.regions[0].transcript == entries && model.regions[1].transcript == nil)
    precondition(model.regions[0].feedback == "hello world next phrase")
    model.voice.receiveTranscript("",final:true,failed:false,timings:[])
    precondition(model.regions[0].feedback == "hello world next phrase", "Empty final recognition must not erase accepted opinion text")
    precondition(model.regions[0].transcript == entries, "Empty final timings must not erase accepted transcript")
    model.select(two.id)
    while model.busy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(model.voice.timedTranscript.isEmpty)
    model.voice.receiveTranscript("second",final:false,failed:false,timings:[VoiceTranscriptEntry(recordedAt:start.addingTimeInterval(10),text:"second")])
    precondition(model.regions[0].transcript == entries && model.regions[1].transcript?.count == 1)
    precondition(model.regions[1].feedback == "second")
    model.voice.receiveTranscript(nil,final:false,failed:true,timings:[],errorDescription:"fixture interrupted")
    precondition(model.regions[1].feedback == "second" && model.regions[1].transcript?.count == 1)
    precondition(model.regions[0].feedback == "hello world next phrase", "Finishing another opinion must not change the first")
    try await model.persist()
    let store = ReviewStore(), folder = try await store.latest(root:root)!
    let saved = try await store.load(folder:folder)
    precondition(saved.session.regions[0].transcript == entries)
    precondition(saved.session.regions[0].feedback == "hello world next phrase" && saved.session.regions[1].feedback == "second")
    model.voice.loadDraft("")
    model.voice.receiveTranscript(nil,final:true,failed:false,timings:[VoiceTranscriptEntry(recordedAt:start,text:"segment-only result")])
    precondition(model.regions[1].feedback == "segment-only result", "A timestamped result must also populate the opinion")
    var legacy = try JSONSerialization.jsonObject(with:JSONEncoder().encode(one)) as! [String:Any]
    legacy.removeValue(forKey:"transcript")
    let decoded = try JSONDecoder().decode(ReviewRegion.self,from:JSONSerialization.data(withJSONObject:legacy))
    precondition(decoded.transcript == nil)
    print("PASS: partial/final/empty/error/segment-only recognition writes opinions, preserves ownership and persists text/timestamps")
    exit(0)
}
Task { try await Task.sleep(nanoseconds:15_000_000_000);fatalError("Timestamp test timed out") }
app.run()
