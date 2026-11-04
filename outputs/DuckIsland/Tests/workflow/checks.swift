import Cocoa

@MainActor func runWorkflowChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let reader = ScreenReader(storageRoot:root)
    let image = NSImage(size:NSSize(width:20,height:10),flipped:false) { r in NSColor.white.setFill(); r.fill(); return true }
    let png = try reviewPNG(image)
    let target = ScreenTarget(id:42,pid:123,app:"Fixture",bundleID:"test.fixture",title:"Fake window")
    let region = CGRect(x:0.2,y:0.3,width:0.4,height:0.5)
    let result = ScreenReadResult(text:"Fixture text",image:png)
    reader.accept(result,target:target,region:region)
    assert(!reader.dirty && reader.savedFile != nil)
    reader.text = "Edited fixture 中文"
    assert(reader.dirty)
    let clipboard = NSPasteboard.withUniqueName(); defer { clipboard.releaseGlobally() }
    reader.copy(to:clipboard)
    assert(clipboard.string(forType:.string) == reader.text)
    reader.captureRegionImage = { _,_ in throw NotesFailure(detail:"Fixture capture failure") }
    reader.readRegion(displayID:42,name:"Fixture display",region:region)
    let deadline = Date().addingTimeInterval(2)
    while reader.busy && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
    assert(!reader.busy && reader.text == "Edited fixture 中文" && reader.dirty)
    reader.cancel()
    reader.accept(ScreenReadResult(text:"",image:png),target:target,region:.zero)
    assert(reader.text == "Edited fixture 中文" && reader.dirty)
    reader.accept(result,target:target,region:region,choice:.keep)
    assert(reader.text == "Edited fixture 中文")
    reader.save()
    assert(!reader.dirty)
    let saved = reader.savedFile!
    let storedText = try String(contentsOf:saved,encoding:.utf8)
    assert(storedText == reader.text)
    let storedImage = try Data(contentsOf:saved.deletingLastPathComponent().appendingPathComponent("region.png"))
    assert(storedImage == png)
    let metadata = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:saved.deletingLastPathComponent().appendingPathComponent("source.json")))
    assert(metadata["窗口"] == "Fake window" && metadata["框选范围"] == "\(region)")
    reader.accept(result,target:target,region:region,choice:.keep) // Saved content does not prompt.
    assert(reader.text == result.text)
    let blockedRoot = root.appendingPathComponent("file")
    try Data().write(to:blockedRoot)
    let failed = ScreenReader(storageRoot:blockedRoot)
    failed.accept(result,target:target,region:region)
    assert(failed.dirty && failed.canRetrySave)
    assert(!failed.preserveForTermination())
    failed.accept(ScreenReadResult(text:"New",image:png),target:target,region:region,choice:.save)
    assert(failed.text == result.text && failed.dirty)
    failed.cancel(); assert(failed.text == result.text)
    failed.accept(ScreenReadResult(text:"New",image:png),target:target,region:region,choice:.discard)
    assert(failed.text == "New")
    let view = TranscriptScrollContainer(frame:NSRect(x:0,y:0,width:400,height:138))
    view.layout()
    let longText = (0..<100).map { "Fixture line \($0)" }.joined(separator:"\n")
    view.update(longText)
    assert(view.scroll.contentView.bounds.maxY >= view.textView.bounds.maxY - 12)
    view.scroll.contentView.scroll(to:CGPoint(x:0,y:80)); view.readingChanged()
    let before = view.scroll.contentView.bounds.origin
    view.update(longText + "\nNew content")
    assert(view.scroll.contentView.bounds.origin == before && !view.latest.isHidden)
    view.textView.setSelectedRange(NSRange(location:3,length:8)); view.readingChanged()
    view.update(longText + "\nNew content again")
    assert(view.textView.selectedRange() == NSRange(location:3,length:8))
    view.resume(); assert(view.follow.following && view.latest.isHidden)
    var follow = TranscriptFollowState()
    assert(follow.appended())
    follow.reading(atBottom:false,selecting:false); assert(!follow.appended() && follow.unread)
    follow.reading(atBottom:true,selecting:true); assert(!follow.appended())
    follow.resume(); assert(follow.appended() && !follow.unread)
    follow.reading(atBottom:false,selecting:false); follow.reading(atBottom:true,selecting:false)
    assert(follow.appended())
    for size in [CGSize(width:6000,height:4000),CGSize(width:100000,height:1000),CGSize(width:1920,height:1080)] {
        let pixels = screenCaptureSize(size,scale:2,purpose:.ocr)
        assert(pixels.width*pixels.height <= 12_000_000 && max(pixels.width,pixels.height) <= 8192)
        assert(displayRegionRect(region,size:size).minX == size.width*0.2)
    }
    // Per-display normalized mapping is independent of negative/global origins.
    for frame in [CGRect(x:-1920,y:0,width:1920,height:1080),CGRect(x:0,y:1080,width:2560,height:1440)] {
        assert(displayRegionRect(CGRect(x:0,y:0,width:1,height:1),size:frame.size).size == frame.size)
    }
    let fixtureReader = ScreenReader(storageRoot:root)
    fixtureReader.loadTargets = { [] }
    let recorder = Recorder(screenReader:fixtureReader)
    recorder.recording = true; recorder.transcript = "Ongoing fixture meeting"
    recorder.readScreen()
    assert(recorder.recording && recorder.transcript == "Ongoing fixture meeting" && fixtureReader.visible)
    fixtureReader.cancel()
    // Already-active review opens its sidebar without enumerating or capturing windows.
    recorder.review.active = true
    recorder.startReview()
    assert(recorder.recording && recorder.transcript == "Ongoing fixture meeting")
    recorder.recording = false

    recorder.microphoneReserved = true
    assert(recorder.review.voice.unavailableReason == "会议录音中，可输入文字")
    recorder.review.voice.toggleVoice(); assert(!recorder.review.voice.voiceActive)
    recorder.review.voice.draft = "Text remains available"
    recorder.microphoneReserved = false; recorder.busy = true // Transcription drain, no microphone.
    assert(recorder.review.voice.unavailableReason == nil)
    recorder.busy = false
    for stage in 0..<3 {
        recorder.review.voice.voicePreparing = stage == 0
        recorder.review.voice.dictating = stage == 1
        recorder.review.voice.voiceFinishing = stage == 2
        recorder.meeting() // Must return before permissions/real capture.
        assert(!recorder.busy && !recorder.microphoneReserved)
    }
    recorder.review.voice.finishVoice(cancel:true)
    print("PASS: workflow OCR retention/edit/save/failure, clipboard, source association, display budget, reading follow, microphone admission")
}
try MainActor.assumeIsolated { try runWorkflowChecks() }

runMeetingTests() // Existing synthetic OCR/review/audio fixtures; Notes scripts compile only.
