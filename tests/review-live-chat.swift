import Cocoa
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    precondition(moOpenAIKeyFromEnvironment("OPENROUTER_API_KEY=fixture") == nil)
    precondition(moOpenAIKeyFromEnvironment("export OPENAI_API_KEY='fixture-secret' # comment") == "fixture-secret")
    precondition(moOpenAIKeyFromEnvironment("OPENAI_API_KEY=$SOME_OTHER_KEY") == nil)
    let emptyProxy = try MoLiveNetwork.proxyDictionary("")
    precondition(emptyProxy == nil)
    let proxy = try MoLiveNetwork.proxyDictionary("http://127.0.0.1:7897")!
    precondition(proxy["HTTPSPort"] as? Int == 7897)
    do { _ = try MoLiveNetwork.proxyDictionary("http://user:secret@localhost:7897"); fatalError("Proxy credentials must not enter preferences") } catch { }
    precondition(MoLiveNetwork.shouldRetry(NSError(domain:NSURLErrorDomain,code:NSURLErrorSecureConnectionFailed)))
    precondition(!MoLiveNetwork.shouldRetry(NSError(domain:NSURLErrorDomain,code:NSURLErrorServerCertificateUntrusted)))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mo-live-fixture-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let model = ReviewModel(storageRoot:root)
    let live = model.live
    func event(_ role:String,_ id:String,_ text:String,_ start:Int,_ end:Int) -> [String:Any] {
        ["type":role == "user" ? "session.input_transcript.delta" : "session.output_transcript.delta","event_id":id,"delta":text,"start_ms":start,"end_ms":end]
    }
    live.receive(event("user","a","请帮我",0,200))
    live.receive(event("assistant","b","好的",100,300))
    live.receive(event("user","c"," 看看这个批阅",200,600))
    live.receive(event("user","c"," 看看这个批阅",200,600))
    live.receive(event("assistant","d","，你想改哪里？",300,900))
    precondition(live.messages.count == 2)
    precondition(live.messages[0].text == "请帮我 看看这个批阅" && live.messages[1].text == "好的，你想改哪里？")
    precondition(live.messages[0].fragments?.count == 2 && live.messages[0].fragments?.last?.startMS == 200)
    live.receive(event("user","e","让图标小一点",4000,4600))
    precondition(live.messages.count == 3, "A separate speech interval starts a new message")
    let start = moLiveStartEvent(context:"#1 图标",messages:live.messages)
    precondition(start["type"] as? String == "session.start")
    let session = start["session"] as! [String:Any]
    precondition(session["model"] as? String == "gpt-live-1")
    precondition((session["input"] as? [[String:Any]])?.count == 3)
    let audio = session["audio"] as! [String:Any], format = audio["format"] as! [String:Any]
    precondition(format["rate"] as? Int == 24000 && format["type"] as? String == "audio/pcm")
    let image = NSImage(size:CGSize(width:600,height:400),flipped:false) { r in NSColor.white.setFill();r.fill();return true }
    let shot = ReviewSnapshot(id:UUID(),image:image,png:try reviewPNG(image),frame:CGRect(x:100,y:100,width:900,height:620))
    model.active = true; model.paused = true; model.snapshots = [shot]; model.current = shot
    model.panels.showOverlay(shot)
    try await Task.sleep(nanoseconds:100_000_000)
    let view = model.panels.overlay!.contentView!
    view.layoutSubtreeIfNeeded()
    let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
    view.cacheDisplay(in:view.bounds,to:bitmap)
    try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("gpt-live-chat.png"))
    try await model.persist()
    let folder = try await ReviewStore().latest(root:root)!
    let saved = try await ReviewStore().load(folder:folder)
    precondition(saved.session.chatMessages?.count == 3)
    precondition(saved.session.chatMessages?[0].text == live.messages[0].text)
    precondition(model.regions.isEmpty, "Chat must not create or overwrite review opinions")
    await live.stop()
    precondition(!live.active)
    model.panels.close()
    print("PASS: GPT-Live session schema, per-speaker overlapping captions, deduplication, fragment timing, message persistence, env isolation and chat rendering; no credentials, network or microphone used")
    exit(0)
}
Task { try await Task.sleep(nanoseconds:20_000_000_000); fatalError("Live chat test timed out") }
app.run()
