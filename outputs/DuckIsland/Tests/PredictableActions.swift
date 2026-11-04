// Appended to the production declarations by run-predictable-actions.sh.
@MainActor func checkPredictableActions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let model = ReviewModel(storageRoot:root)
    let recorder = Recorder(review:model)
    recorder.recording = true
    recorder.toggle(); assert(recorder.showMenu && recorder.recording)
    recorder.toggle(); assert(!recorder.showMenu && recorder.recording)
    recorder.meeting(); assert(recorder.recording && recorder.showMenu && !recorder.busy)
    await recorder.stopMeeting()
    let ended = recorder.message
    await recorder.stopMeeting()
    assert(!recorder.recording && recorder.message == ended)
    let image = NSImage(size:NSSize(width:100,height:100),flipped:false) { rect in NSColor.white.setFill(); rect.fill(); return true }
    let png = try reviewPNG(image)
    let a = ReviewSnapshot(id:UUID(),image:image,png:png,frame:CGRect(x:0,y:0,width:100,height:100))
    let b = ReviewSnapshot(id:UUID(),image:image,png:png,frame:a.frame)
    let ra = ReviewRegion(snapshotID:a.id,number:1,rect:CGRect(x:0,y:0,width:0.5,height:0.5),feedback:"A")
    let rb = ReviewRegion(snapshotID:b.id,number:2,rect:ra.rect,feedback:"B")
    model.active = true; model.snapshots = [a,b]; model.current = a; model.regions = [ra,rb]
    model.selectedID = ra.id; model.voice.draft = "A"
    // Exercise the actual final-callback barrier without audio hardware.
    model.voice.voiceFinishing = true
    model.select(rb.id)
    await Task.yield()
    assert(model.selectedID == ra.id && model.busy)
    model.voice.receiveTranscript("A final",final:true,failed:false)
    while model.busy { try await Task.sleep(nanoseconds:10_000_000) }
    assert(model.selectedID == rb.id && !model.voice.voiceActive)
    assert(model.regions[0].feedback == "A final" && model.regions[1].feedback == "B")
    await model.deleteSnapshot(a.id)
    assert(model.snapshots.count == 1 && model.regions.count == 1 && model.canUndo)
    model.voice.voiceFinishing = true
    let undoing = Task { await model.undoEdit() }
    await Task.yield(); assert(model.selectedID == rb.id)
    model.voice.receiveTranscript("B final",final:true,failed:false)
    await undoing.value
    assert(model.regions.last?.feedback == "B final")
    assert(model.regions.first?.feedback == "A final" && model.snapshots.count == 2)
    await model.deleteSelectedRegion(); assert(!model.regions.contains { $0.id == rb.id })
    await model.undoEdit(); assert(model.regions.last?.feedback == "B final")
    model.paused = true; model.current = b
    model.addRegion(ra.rect)
    while model.busy { try await Task.sleep(nanoseconds:10_000_000) }
    model.paused = false
    assert(model.regions.count == 3 && !model.voice.voiceActive)
    await model.undoEdit(); assert(model.regions.count == 2)
    try await model.persist()
    let store = ReviewStore()
    let folder = try await store.latest(root:root)!
    let restored = ReviewModel(storageRoot:root)
    try await restored.restore(folder:folder,presentPanels:false)
    assert(restored.regions.count == 2 && restored.snapshots[0].capturedAt == a.capturedAt)
    restored.paused = false
    await restored.deleteSnapshot(a.id); await restored.deleteSnapshot(b.id)
    let empty = try await store.load(folder:folder)
    assert(empty.session.shots.isEmpty && empty.session.regions.isEmpty)
    let remainingFiles = try FileManager.default.contentsOfDirectory(atPath:folder.path)
    assert(!remainingFiles.contains { $0.hasSuffix(".png") })
    await restored.undoEdit()
    let back = try await store.load(folder:folder)
    assert(back.session.shots.count == 1 && back.session.regions.first?.snapshotID == b.id)
    // A failed close retains content and waits for the final transcript before saving.
    let badRoot = root.appendingPathComponent("file")
    try Data().write(to:badRoot)
    let failed = ReviewModel(storageRoot:badRoot)
    failed.active = true; failed.snapshots = [a]; failed.regions = [ra]; failed.selectedID = ra.id
    failed.voice.voiceFinishing = true
    let closing = Task { await failed.closeForTermination() }
    await Task.yield(); assert(failed.active)
    failed.voice.receiveTranscript("retained final",final:true,failed:false)
    let closed = await closing.value
    assert(!closed && failed.active && failed.regions[0].feedback == "retained final")
    _ = await model.closeForTermination(); _ = await restored.closeForTermination()
    print("PASS: menu/start/stop idempotence, selection speech barrier, delete/undo, persistence/empty recovery, failed close retention")
}
Task { @MainActor in
    do { try await checkPredictableActions(); exit(0) }
    catch { fputs("FAIL: \(error)\n",stderr); exit(1) }
}
RunLoop.main.run()
