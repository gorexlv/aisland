import Cocoa
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mo-composer-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let model = ReviewModel(storageRoot:root)
    model.active = true; model.paused = true; model.listeningEnabled = false; model.voice.unavailableReason = "fixture"
    let image = NSImage(size:CGSize(width:600,height:400),flipped:false) { r in NSColor.white.setFill();r.fill();return true }
    let shot = ReviewSnapshot(id:UUID(),image:image,png:try reviewPNG(image),frame:CGRect(x:100,y:100,width:900,height:620))
    model.snapshots = [shot]; model.current = shot
    model.textChatResponder = { input,_ in
        let data = try JSONSerialization.jsonObject(with:Data(input.utf8)) as! [String:Any]
        precondition(data["question"] as? String == "你好小墨小墨")
        return "你好，我可以帮你整理批阅意见。"
    }
    model.panels.showOverlay(shot)
    try await Task.sleep(nanoseconds:80_000_000)
    let window = model.panels.overlay!, view = window.contentView!
    view.layoutSubtreeIfNeeded()
    func editor(in view:NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.isEditable { return text }
        return view.subviews.compactMap { editor(in:$0) }.first
    }
    let field = editor(in:view)!
    window.makeKeyAndOrderFront(nil); window.makeFirstResponder(field)
    field.insertText("第一行",replacementRange:NSRange(location:0,length:0))
    let shiftEnter = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.shift,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
    NSApp.postEvent(shiftEnter,atStart:false)
    try await Task.sleep(nanoseconds:50_000_000)
    precondition(model.chatDraft.contains("\n") && model.live.messages.isEmpty, "Shift+Enter inserts a newline without sending")
    field.setMarkedText("默",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:0,length:field.string.utf16.count))
    let consumed = field.delegate?.textView?(field,doCommandBy:#selector(NSResponder.insertNewline(_:))) ?? false
    precondition(!consumed && model.live.messages.isEmpty, "IME composition must not send")
    field.unmarkText()
    field.insertText("你好小墨小墨",replacementRange:NSRange(location:0,length:field.string.utf16.count))
    precondition(model.chatDraft == "你好小墨小墨")
    let enter = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
    NSApp.postEvent(enter,atStart:false)
    try await Task.sleep(nanoseconds:50_000_000)
    while model.textChatBusy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(model.live.messages.count == 2 && model.live.messages[0].text == "你好小墨小墨" && model.live.messages[1].source == "agent")
    precondition(model.chatDraft.isEmpty && model.regions.isEmpty && !model.speakingEnabled)
    model.chatDraft = "第二个问题"
    model.sendChatMessage(using:{ _,_ in throw NotesFailure(detail:"fixture reply failure") })
    while model.textChatBusy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(model.textChatError == "fixture reply failure" && model.live.messages.count == 3)
    model.retryChatMessage(using:{ _,_ in "重试后的回复" })
    while model.textChatBusy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(model.live.messages.count == 4 && model.live.messages.last?.text == "重试后的回复")
    model.chatDraft = "下一条待发送消息"
    try await Task.sleep(nanoseconds:50_000_000)
    view.layoutSubtreeIfNeeded()
    let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
    view.cacheDisplay(in:view.bounds,to:bitmap)
    try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("mo-chat-composer.png"))
    model.sendChatMessage(using:{ _,cancellation in
        while cancellation?.isCancelled == false { Thread.sleep(forTimeInterval:0.001) }
        return "late reply must not be accepted"
    })
    let closed = await model.closeForTermination()
    precondition(closed)
    try await Task.sleep(nanoseconds:500_000_000)
    precondition(!model.textChatBusy && !model.live.messages.contains(where:{$0.text == "late reply must not be accepted"}))
    let folder = try await ReviewStore().latest(root:root)!, saved = try await ReviewStore().load(folder:folder)
    precondition(saved.session.chatMessages?.contains(where:{$0.text == "重试后的回复"}) == true)
    print("PASS: native composer input/Enter, Agent text reply, silent mode isolation, failure retry without duplicate, persistence and late reply cancellation; no AI service or microphone used")
    exit(0)
}
Task { try await Task.sleep(nanoseconds:20_000_000_000); fatalError("Composer test timed out") }
app.run()
