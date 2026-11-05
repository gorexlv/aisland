import Cocoa
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let source = [ReviewSummarySource(number:1,text:"make it smaller")]
    let valid = Data(#"{"items":[{"number":1,"keyPoints":["缩小尺寸"],"cleanedText":"请缩小图标尺寸。"}]}"#.utf8)
    let rendered = try renderReviewSummary(valid,source:source)
    precondition(rendered.contains("#1") && rendered.contains("缩小尺寸"))
    let invalid = Data(#"{"items":[{"number":99,"keyPoints":["invented"],"cleanedText":"invented"}]}"#.utf8)
    do { _ = try renderReviewSummary(invalid,source:source); fatalError("Unknown region number accepted") } catch { }
    do { _ = try renderReviewSummary(valid,source:source+[ReviewSummarySource(number:2,text:"second")]); fatalError("Missing region accepted") } catch { }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-ai-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let model = ReviewModel(storageRoot:root)
    model.active = true
    model.target = ScreenTarget(id:42,pid:-1,app:"Fixture",bundleID:"fixture",title:"Summary")
    let image = NSImage(size:CGSize(width:200,height:100),flipped:false) { r in NSColor.white.setFill();r.fill();return true }
    let shot = ReviewSnapshot(id:UUID(),image:image,png:try reviewPNG(image),frame:CGRect(x:0,y:0,width:200,height:100))
    let region = ReviewRegion(snapshotID:shot.id,number:1,rect:CGRect(x:0.1,y:0.1,width:0.5,height:0.5),feedback:"make it smaller")
    model.snapshots = [shot]; model.current = shot; model.regions = [region]; model.selectedID = region.id
    model.summarizeReview { input,_ in
        let decoded = try JSONDecoder().decode([ReviewSummarySource].self,from:Data(input.utf8))
        precondition(decoded.count == 1 && decoded[0].number == 1 && decoded[0].text == "make it smaller")
        return try renderReviewSummary(valid,source:decoded)
    }
    while model.summaryBusy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(model.aiSummary == rendered && !model.summaryOutdated && model.regions[0].feedback == region.feedback)
    try await model.persist()
    let folder = try await ReviewStore().latest(root:root)!
    let restored = ReviewModel(storageRoot:root)
    try await restored.restore(folder:folder,presentPanels:false)
    precondition(restored.aiSummary == rendered && !restored.summaryOutdated)
    model.summarizeReview { _,_ in Thread.sleep(forTimeInterval:0.1); return "#1\nOriginal snapshot" }
    model.updateOpinion(region.id,text:"updated while generating")
    while model.summaryBusy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(model.summaryOutdated && model.regions[0].feedback == "updated while generating")
    let previous = model.aiSummary
    model.summarizeReview { _,_ in throw NotesFailure(detail:"fixture failure") }
    while model.summaryBusy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(model.aiSummary == previous && model.summaryError == "fixture failure")
    model.voice.refreshInputDevices()
    let oldDevice = model.voice.selectedInputID
    do { try model.voice.setInputDevice("fixture-missing-device"); fatalError("Missing device accepted") } catch { }
    precondition(model.voice.selectedInputID == oldDevice)
    model.summarizeReview { _,cancellation in
        while cancellation?.isCancelled == false { Thread.sleep(forTimeInterval:0.001) }
        return "late result"
    }
    model.voice.dictating = true
    let closing = Task { await model.closeForTermination() }
    while !model.voice.voiceFinishing { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(!model.summaryBusy, "Close must cancel summary before waiting on voice or persistence")
    model.voice.receiveTranscript("final before close",final:true,failed:false)
    let closed = await closing.value
    precondition(closed)
    try await Task.sleep(nanoseconds:550_000_000)
    precondition(model.aiSummary != "late result" && !model.summaryBusy)
    let stored = try await ReviewStore().load(folder:folder)
    precondition(stored.session.target?.id == 42, "Late AI result must not overwrite the closed session with nil target")
    restored.panels.close()
    print("PASS: summary references, immutable source, stale results, persistence, failure retention, session isolation and invalid device rejection; no AI service or microphone used")
    exit(0)
}
Task { try await Task.sleep(nanoseconds:20_000_000_000); fatalError("Summary tests timed out") }
app.run()
