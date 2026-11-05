import Cocoa
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    precondition(reviewExportTitle("A",note:"") == "A")
    precondition(reviewExportTitle("A",note:"  ") == "A")
    precondition(reviewExportTitle("A",note:"看标题") == "A\n意图：看标题")
    let id = UUID()
    let stored = StoredReviewSession(target:nil,shots:[StoredReviewShot(id:id,frame:.zero)],regions:[],selectedID:nil,intentNote:"x")
    let decoded = try JSONDecoder().decode(StoredReviewSession.self,from:JSONEncoder().encode(stored))
    precondition(decoded.intentNote == "x")
    var legacy = try JSONSerialization.jsonObject(with:JSONEncoder().encode(stored)) as! [String:Any]
    legacy.removeValue(forKey:"intentNote")
    let old = try JSONDecoder().decode(StoredReviewSession.self,from:JSONSerialization.data(withJSONObject:legacy))
    precondition(old.intentNote == nil)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-attach-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let model = ReviewModel(storageRoot:root)
    let before = model.summarySourceJSON
    model.intentNote = "看标题"
    precondition(model.summarySourceJSON == before, "intent must not change the summary source")
    model.intentNote = ""
    await model.restoreLatestStandalone()
    precondition(model.status == "没有可恢复的批阅" && !model.active, model.status)
    let fixture = ScreenTarget(id:1,pid:-1,app:"Fixture",bundleID:"fixture",title:"Gone")
    let ok = await model.attach(fixture,note:"看标题")
    precondition(!ok)
    precondition(model.status == "选中的窗口已关闭，请重新选择窗口", model.status)
    precondition(model.targets.isEmpty && model.panels.sidebar == nil, "attach must not show the picker sidebar")
    precondition(!model.busy && !model.active)
    // Persisted note round-trips through standalone restore.
    let shotID = UUID()
    let image = NSImage(size:CGSize(width:40,height:40),flipped:false) { b in NSColor.white.setFill(); b.fill(); return true }
    let png = try reviewPNG(image)
    let session = StoredReviewSession(target:fixture,shots:[StoredReviewShot(id:shotID,frame:CGRect(x:0,y:0,width:40,height:40))],regions:[],selectedID:nil,intentNote:"看标题")
    try await ReviewStore().save(ReviewSavePayload(session:session,originals:[shotID:png],text:"x"),folder:root.appendingPathComponent("2026-a"))
    await model.restoreLatestStandalone()
    precondition(model.active && model.intentNote == "看标题" && model.snapshots.count == 1, model.status)
    model.panels.close()
    print("PASS: review attach")
    exit(0)
}
Task { try await Task.sleep(nanoseconds:20_000_000_000); fatalError("Attach tests timed out") }
app.run()
