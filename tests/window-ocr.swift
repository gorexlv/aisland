import Cocoa
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("window-ocr-"+UUID().uuidString)
    try fm.createDirectory(at:base,withIntermediateDirectories:true)
    defer { try? fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:base.appendingPathComponent("ro").path); try? fm.removeItem(at:base) }
    let fixture = ScreenTarget(id:1,pid:-1,app:"Fixture",bundleID:"fixture",title:"Doc")
    let png = try reviewPNG(NSImage(size:CGSize(width:20,height:20),flipped:false) { b in NSColor.white.setFill(); b.fill(); return true })
    let region = CGRect(x:0,y:0,width:1,height:1)
    // note in source.json
    let withNote = try saveScreenRead(ScreenReadResult(text:"a",image:png),source:fixture,region:region,root:base.appendingPathComponent("n1"),note:"查标题")
    let meta = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:withNote.deletingLastPathComponent().appendingPathComponent("source.json")))
    precondition(meta["意图"] == "查标题")
    let without = try saveScreenRead(ScreenReadResult(text:"a",image:png),source:fixture,region:region,root:base.appendingPathComponent("n2"))
    let meta2 = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:without.deletingLastPathComponent().appendingPathComponent("source.json")))
    precondition(meta2["意图"] == nil)
    // records
    let session = WindowOCRSession(voice:VoiceInput(),storageRoot:base.appendingPathComponent("s1"))
    session.active = true; session.reader.note = "查标题"
    session.reader.accept(ScreenReadResult(text:"第一段",image:png),target:fixture,region:region)
    session.reader.accept(ScreenReadResult(text:"第二段",image:png),target:fixture,region:region,choice:.discard)
    precondition(session.records.count == 2, "\(session.records.count)")
    precondition(session.records.allSatisfy { fm.fileExists(atPath:$0.file.path) })
    precondition(session.records.last?.text == "第二段" && session.latestText == "第二段")
    let saved = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:session.records[0].file.deletingLastPathComponent().appendingPathComponent("source.json")))
    precondition(saved["意图"] == "查标题")
    // empty result
    session.reader.accept(ScreenReadResult(text:"",image:png),target:fixture,region:region)
    precondition(session.records.count == 2 && session.status == "没有识别到文字，原文字保留", session.status)
    // independence
    let recorder = Recorder(review:ReviewModel())
    precondition(session.reader !== recorder.screenReader)
    let other = WindowOCRSession(voice:VoiceInput(),storageRoot:base.appendingPathComponent("s2"))
    other.reader.save() // nothing pending
    precondition(!other.reader.dirty && !recorder.screenReader.dirty)
    // speaking guard
    var contexts: [String] = []
    other.startLive = { contexts.append($0) }
    other.setSpeakingEnabled(true)
    precondition(!other.speakingEnabled && other.status == "请先框选识别文字" && contexts.isEmpty)
    // context string + restart on new save
    other.target = fixture; other.active = true
    other.reader.accept(ScreenReadResult(text:"甲",image:png),target:fixture,region:region)
    other.setSpeakingEnabled(true)
    try await Task.sleep(nanoseconds:100_000_000)
    precondition(other.speakingEnabled && contexts == ["OCR 识别文字（Fixture · Doc）：\n甲"], "\(contexts)")
    other.reader.accept(ScreenReadResult(text:"乙",image:png),target:fixture,region:region)
    try await Task.sleep(nanoseconds:200_000_000)
    precondition(contexts.last == "OCR 识别文字（Fixture · Doc）：\n乙" && contexts.count == 2, "\(contexts)")
    other.setSpeakingEnabled(false)
    precondition(!other.speakingEnabled)
    // serialized live control: rapid toggles end stopped, never double-start
    var running = 0, maxRunning = 0
    other.startLive = { _ in running += 1; maxRunning = max(maxRunning,running); try? await Task.sleep(nanoseconds:20_000_000) }
    other.stopLive = { running = 0 }
    other.setSpeakingEnabled(true); other.setSpeakingEnabled(false); other.setSpeakingEnabled(true); other.setSpeakingEnabled(false)
    try await Task.sleep(nanoseconds:400_000_000)
    precondition(!other.speakingEnabled && running == 0 && maxRunning <= 1, "running=\(running) max=\(maxRunning)")
    // re-save of the same selection replaces the record
    let rs = WindowOCRSession(voice:VoiceInput(),storageRoot:base.appendingPathComponent("s4"))
    rs.active = true
    rs.reader.accept(ScreenReadResult(text:"原文",image:png),target:fixture,region:region)
    let firstFile = rs.records[0].file
    rs.reader.text = "改后"; rs.reader.save()
    precondition(rs.records.count == 1 && rs.records[0].text == "改后" && rs.records[0].file == rs.reader.savedFile && rs.records[0].file != firstFile)
    precondition(fm.fileExists(atPath:firstFile.path), "old folder kept")
    rs.reader.accept(ScreenReadResult(text:"新选区",image:png),target:fixture,region:region,choice:.discard)
    precondition(rs.records.count == 2)
    // note is one source of truth
    rs.note = "新意图"
    rs.reader.accept(ScreenReadResult(text:"带意图",image:png),target:fixture,region:region)
    let m3 = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:rs.records.last!.file.deletingLastPathComponent().appendingPathComponent("source.json")))
    precondition(m3["意图"] == "新意图")
    // attach while active is refused
    let again = await rs.attach(fixture,note:"x")
    precondition(!again && rs.status == "请先结束当前读屏" && rs.records.count == 3)
    // end() read-only vs writable
    let ro = base.appendingPathComponent("ro")
    try fm.createDirectory(at:ro,withIntermediateDirectories:true)
    let bad = WindowOCRSession(voice:VoiceInput(),storageRoot:ro)
    bad.active = true
    try fm.setAttributes([.posixPermissions:0o500],ofItemAtPath:ro.path)
    bad.reader.accept(ScreenReadResult(text:"x",image:png),target:fixture,region:region)
    precondition(bad.reader.dirty, "read-only root must leave dirty")
    let failed = await bad.end()
    precondition(!failed && bad.active && bad.status.contains("保存失败"), bad.status)
    try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:ro.path)
    let okBad = await bad.end()
    precondition(okBad && !bad.active && bad.records.count == 0)
    let good = WindowOCRSession(voice:VoiceInput(),storageRoot:base.appendingPathComponent("s3"))
    good.active = true
    good.reader.accept(ScreenReadResult(text:"y",image:png),target:fixture,region:region)
    let okGood = await good.end()
    precondition(okGood && !good.active)
    // attach to a missing window
    let attached = await good.attach(fixture,note:"n")
    precondition(!attached && good.status == "选中的窗口已关闭，请重新选择窗口" && !good.active)
    print("PASS: window ocr")
    exit(0)
}
app.run()
