// Launcher routing, one-work-at-a-time, termination preservation and launcher rendering. No real windows, mic or chords.
import Cocoa
import SwiftUI
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
@MainActor func settle() { RunLoop.main.run(until:Date().addingTimeInterval(0.1)) }
@MainActor func render<V: View>(_ view: V, _ name: String, _ dest: String) throws {
    let host = NSHostingView(rootView:view)
    host.frame = NSRect(origin:.zero,size:NSSize(width:560,height:600))
    let window = NSWindow(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false)
    window.contentView = host
    host.layoutSubtreeIfNeeded(); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
    let size = host.fittingSize
    host.frame = NSRect(origin:.zero,size:size); host.layoutSubtreeIfNeeded()
    let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds)!
    host.cacheDisplay(in:host.bounds,to:bitmap)
    try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:dest).appendingPathComponent(name+".png"))
    print("RENDER \(name): \(size)")
}
Task { @MainActor in
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("launcher-routing-"+UUID().uuidString)
    try fm.createDirectory(at:base,withIntermediateDirectories:true)
    defer { try? fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:base.appendingPathComponent("ro").path); try? fm.removeItem(at:base) }
    let dest = CommandLine.arguments[1]
    let t = ScreenTarget(id:1,pid:-1,app:"浏览器",bundleID:"fixture",title:"设计讨论")
    let t2 = ScreenTarget(id:2,pid:-1,app:"文稿",bundleID:"fixture",title:"春季计划")
    let t3 = ScreenTarget(id:3,pid:-1,app:"备忘录",bundleID:"fixture",title:"")
    let png = try reviewPNG(NSImage(size:CGSize(width:20,height:20),flipped:false) { b in NSColor.white.setFill(); b.fill(); return true })
    let fixture = ScreenTarget(id:9,pid:-1,app:"Fixture",bundleID:"fixture",title:"Doc")
    @MainActor func makeRecorder(_ name: String) -> (Recorder, ReviewModel, WindowOCRSession) {
        let review = ReviewModel(storageRoot:base.appendingPathComponent(name+"-review"))
        let ocr = WindowOCRSession(voice:review.voice,storageRoot:base.appendingPathComponent(name+"-ocr"))
        return (Recorder(review:review,windowOCR:ocr),review,ocr)
    }

    // 1. review busy: nothing switches
    var (recorder, review, ocr) = makeRecorder("a")
    var reviewCalls: [(ScreenTarget,String)] = [], ocrCalls: [(ScreenTarget,String)] = [], reframes = 0
    @MainActor func wire() {
        recorder.attachReview = { reviewCalls.append(($0,$1)); return true }
        recorder.attachOCR = { ocrCalls.append(($0,$1)); return true }
        recorder.reframeOCR = { reframes += 1 }
    }
    wire()
    review.active = true; review.busy = true
    await recorder.launch(t,.ocr,note:"n")
    precondition(review.active && review.busy && ocrCalls.isEmpty && reviewCalls.isEmpty && !ocr.active)
    precondition(recorder.toast == "正在处理，请稍后再试", recorder.toast)

    // 2. OCR active + clean reader -> review attach, OCR ended
    (recorder, review, ocr) = makeRecorder("b"); wire()
    ocr.active = true; ocr.target = fixture
    await recorder.launch(t,.review,note:"n")
    precondition(!ocr.active && reviewCalls.count == 1 && reviewCalls[0].0 == t && reviewCalls[0].1 == "n" && ocrCalls.isEmpty)

    // 3. review active (idle, empty) + launch OCR -> review ended, OCR attached with note
    (recorder, review, ocr) = makeRecorder("c"); wire()
    reviewCalls = []; review.active = true
    await recorder.launch(t2,.ocr,note:"读标题")
    precondition(!review.active && ocrCalls.count == 1 && ocrCalls[0].0 == t2 && ocrCalls[0].1 == "读标题" && reviewCalls.isEmpty)
    // no active work: direct attach
    await recorder.launch(t3,.ocr,note:"")
    precondition(ocrCalls.count == 2)
    // termination in flight: no-op
    recorder.terminationRequested = true
    await recorder.launch(t,.review,note:"x"); recorder.primaryAction()
    precondition(reviewCalls.isEmpty && ocrCalls.count == 2 && reframes == 0)
    recorder.terminationRequested = false

    // concurrent launch ignored; busy end shows wait toast
    (recorder, review, ocr) = makeRecorder("d"); wire()
    var slowCalls = 0
    recorder.attachOCR = { _,_ in slowCalls += 1; try? await Task.sleep(nanoseconds:200_000_000); return true }
    let first = Task { await recorder.launch(t,.ocr,note:"1") }
    while slowCalls == 0 { await Task.yield() }
    precondition(recorder.launching)
    await recorder.launch(t2,.ocr,note:"2")
    await first.value
    precondition(slowCalls == 1 && !recorder.launching)
    review.active = true; review.busy = true
    await recorder.endCurrentWorkAction()
    precondition(recorder.toast == "正在处理，请稍后结束" && review.busy && review.active, recorder.toast)
    review.active = false; review.busy = false
    (recorder, review, ocr) = makeRecorder("c"); wire()

    // 3b. Lark proxy routing: launch(.larkProxy) ends previous work and attaches via the injectable closure; other launches end the proxy
    do {
        let larkTarget = ScreenTarget(id:5,pid:-1,app:"Lark",bundleID:"com.larksuite.larkApp",title:"Lark")
        let larkReview = ReviewModel(storageRoot:base.appendingPathComponent("lark-review"))
        let larkOCR = WindowOCRSession(voice:larkReview.voice,storageRoot:base.appendingPathComponent("lark-ocr"))
        let proxy = LarkProxySession(); proxy.autoStart = false
        let lr = Recorder(review:larkReview,windowOCR:larkOCR,larkProxy:proxy)
        var larkCalls: [(ScreenTarget,String)] = [], larkOCRCalls = 0, larkReviewCalls = 0
        lr.attachLarkProxy = { larkCalls.append(($0,$1)); return true }
        lr.attachOCR = { _,_ in larkOCRCalls += 1; return true }
        lr.attachReview = { _,_ in larkReviewCalls += 1; return true }
        larkOCR.active = true; larkOCR.target = fixture
        await lr.launch(larkTarget,.larkProxy,note:"帮我回")
        precondition(!larkOCR.active && larkCalls.count == 1 && larkCalls[0].0 == larkTarget && larkCalls[0].1 == "帮我回" && larkOCRCalls == 0 && larkReviewCalls == 0)
        // proxy active -> launching OCR/review ends it first
        proxy.active = true; proxy.target = larkTarget
        await lr.launch(t,.ocr,note:"")
        precondition(!proxy.active && larkOCRCalls == 1 && larkCalls.count == 1)
        proxy.active = true
        await lr.launch(t,.review,note:"")
        precondition(!proxy.active && larkReviewCalls == 1)
        // proxy active -> launching the proxy again ends the old one first
        proxy.active = true
        await lr.launch(larkTarget,.larkProxy,note:"")
        precondition(!proxy.active && larkCalls.count == 2)
        // review busy blocks the switch
        larkReview.active = true; larkReview.busy = true
        await lr.launch(larkTarget,.larkProxy,note:"")
        precondition(larkCalls.count == 2 && lr.toast == "正在处理，请稍后再试")
        larkReview.active = false; larkReview.busy = false
        // attach failure surfaces the proxy status as a toast
        proxy.status = "未找到 lark-cli，请在设置中填写路径"
        lr.attachLarkProxy = { _,_ in false }
        await lr.launch(larkTarget,.larkProxy,note:"")
        precondition(lr.toast == "未找到 lark-cli，请在设置中填写路径", lr.toast)
        // end action ends the proxy; termination path ends it too
        proxy.active = true
        await lr.endCurrentWorkAction()
        precondition(!proxy.active)
    }

    // 4. primaryAction
    ocr.active = true; ocr.target = fixture
    recorder.primaryAction(); precondition(reframes == 1)
    ocr.active = false; review.active = true; review.busy = true
    recorder.primaryAction(); precondition(reframes == 1 && review.active, "inactive OCR must route to review toggle, not reframe")
    review.active = false; review.busy = false
    // M-2: OCR reader busy -> primary action does not reframe
    ocr.active = true; ocr.target = fixture; ocr.reader.busy = true
    recorder.primaryAction(); precondition(reframes == 1, "busy OCR must not reframe")
    ocr.reader.busy = false; ocr.active = false; ocr.target = nil
    // M-4: nothing attached -> launcher opens (not the review picker)
    recorder.launcher.loadTargets = { [] }
    precondition(!recorder.launcher.visible)
    recorder.primaryAction()
    precondition(recorder.launcher.visible && !review.active && !review.picking, "primary action with no work opens launcher")
    recorder.launcher.close(); settle()
    // M-3: launch while current work busy -> toast, no teardown
    review.active = true; review.busy = true; reviewCalls = []; ocrCalls = []
    await recorder.launch(t,.ocr,note:"")
    precondition(recorder.toast == "正在处理，请稍后再试" && review.active && ocrCalls.isEmpty, recorder.toast)
    review.active = false; review.busy = false
    ocr.active = true; ocr.target = fixture; ocr.reader.busy = true
    await recorder.launch(t,.review,note:"")
    precondition(recorder.toast == "正在处理，请稍后再试" && ocr.active && reviewCalls.isEmpty)
    ocr.reader.busy = false; ocr.active = false; ocr.target = nil

    // 5. attach failure surfaces status as toast
    recorder.attachReview = { _,_ in review.status = "窗口已关闭"; return false }
    await recorder.launch(t,.review,note:"")
    precondition(recorder.toast == "窗口已关闭", recorder.toast)

    // 6. termination: preserveAttachedWork writable vs read-only
    let writable = WindowOCRSession(voice:VoiceInput(),storageRoot:base.appendingPathComponent("w"))
    writable.active = true
    writable.reader.accept(ScreenReadResult(text:"原文",image:png),target:fixture,region:.zero)
    writable.reader.text = "改后"
    let wr = Recorder(review:ReviewModel(storageRoot:base.appendingPathComponent("w-review")),windowOCR:writable)
    precondition(writable.reader.dirty && wr.preserveAttachedWork() && !writable.reader.dirty)
    let savedText = try String(contentsOf:writable.reader.savedFile!,encoding:.utf8)
    precondition(savedText == "改后")
    let ro = base.appendingPathComponent("ro")
    try fm.createDirectory(at:ro,withIntermediateDirectories:true)
    let bad = WindowOCRSession(voice:VoiceInput(),storageRoot:ro)
    bad.active = true
    try fm.setAttributes([.posixPermissions:0o500],ofItemAtPath:ro.path)
    bad.reader.accept(ScreenReadResult(text:"x",image:png),target:fixture,region:.zero)
    let br = Recorder(review:ReviewModel(storageRoot:base.appendingPathComponent("b-review")),windowOCR:bad)
    precondition(bad.reader.dirty && !br.preserveAttachedWork())
    // through the production delegate path
    var replies: [Bool] = []
    let badDelegate = AppDelegate(model:br)
    precondition(badDelegate.requestTermination(reply:{ replies.append($0) }) == .terminateLater)
    while replies.isEmpty { try await Task.sleep(nanoseconds:5_000_000) }
    precondition(replies == [false] && bad.active && bad.reader.dirty && !br.terminationRequested, "read-only root must cancel termination")
    try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:ro.path)
    precondition(badDelegate.requestTermination(reply:{ replies.append($0) }) == .terminateLater)
    while replies.count < 2 { try await Task.sleep(nanoseconds:5_000_000) }
    precondition(replies == [false,true] && !bad.active && bad.records.isEmpty)

    // 7. menu: only the meeting feature button remains (SwiftUI exposes no accessibility tree headless, so check the view source and render it)
    let source = try String(contentsOfFile:"main.swift",encoding:.utf8)
    let menuStart = source.range(of:"if model.showMenu {")!, menuEnd = source.range(of:"} else if model.screenReader.visible {",range:menuStart.upperBound..<source.endIndex)!
    let menuSource = String(source[menuStart.upperBound..<menuEnd.lowerBound])
    precondition(menuSource.contains(".accessibilityLabel(\"会议\")") && !menuSource.contains("读屏") && !menuSource.contains("批阅"))
    precondition(menuSource.components(separatedBy:"MoFeatureIcon(").count == 2, "exactly one feature button")
    let menuModel = Recorder(); menuModel.notchWidth = 180; menuModel.notchHeight = 32; menuModel.showMenu = true
    try render(IslandView(model:menuModel).frame(width:360,height:120),"island-menu",dest)

    // 8. launcher view: both steps rendered, rows and chips
    let model = LauncherModel()
    model.loadTargets = { [t,t2,t3] }
    await model.open(frontPID:nil)
    model.frontID = t2.id
    precondition(model.windowRows.first == t2)
    try render(LauncherView(model:model),"launcher-window",dest)
    model.confirm()
    precondition(model.step == .capability && model.target == t2)
    try render(LauncherView(model:model),"launcher-capability",dest)
    model.rewind(to:.window); precondition(model.step == .window && model.target == nil)
    model.confirm(); model.confirm(); precondition(model.step == .ready)
    model.rewind(to:.capability); precondition(model.step == .capability && model.capability == nil && model.target != nil)
    model.rewind(to:.window); precondition(model.step == .window)
    try render(LauncherView(model:model),"launcher-window-after-rewind",dest)
    let denied = LauncherModel(); struct Denied: Error {}
    denied.loadTargets = { throw Denied() }; await denied.open(frontPID:nil)
    try render(LauncherView(model:denied),"launcher-permission",dest)

    // M-9: Enter before the window list loads is remembered and applied on arrival
    let slow = LauncherModel()
    slow.loadTargets = { try? await Task.sleep(nanoseconds:150_000_000); return [t,t2] }
    let opening = Task { await slow.open(frontPID:nil) }
    try await Task.sleep(nanoseconds:30_000_000)
    slow.confirm(); precondition(slow.step == .window && slow.target == nil)
    await opening.value
    precondition(slow.step == .capability && slow.target == t, "pending confirm applied")
    let stale = LauncherModel()
    stale.loadTargets = { try? await Task.sleep(nanoseconds:100_000_000); return [t] }
    let staleOpen = Task { await stale.open(frontPID:nil) }
    try await Task.sleep(nanoseconds:30_000_000)
    stale.confirm(); stale.close()
    await staleOpen.value
    precondition(stale.step == .window && stale.target == nil && !stale.visible, "closed launcher drops pending confirm")

    // 9. panel lifecycle without keystrokes: show -> visible, close -> hidden; resign key closes
    let panelModel = LauncherModel(); panelModel.loadTargets = { [t,t2] }
    let panel = LauncherPanel(model:panelModel)
    panelModel.onClose = { panel.hide() }
    await panelModel.open(frontPID:nil); panel.show()
    precondition(panel.isVisible)
    // keyboard through the real panel: arrows move, Return advances, Delete rewinds, Esc closes
    try await Task.sleep(nanoseconds:300_000_000)
    @MainActor func key(_ code: UInt16, _ characters: String) {
        let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:panel.window!.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code)!
        panel.window?.sendEvent(event)
    }
    key(125,"\u{F701}"); try await Task.sleep(nanoseconds:50_000_000)
    precondition(panelModel.highlight == 1, "down arrow: \(panelModel.highlight)")
    key(126,"\u{F700}"); try await Task.sleep(nanoseconds:50_000_000)
    precondition(panelModel.highlight == 0)
    key(36,"\r"); try await Task.sleep(nanoseconds:50_000_000)
    precondition(panelModel.step == .capability)
    key(51,"\u{7F}"); try await Task.sleep(nanoseconds:300_000_000)
    precondition(panelModel.step == .window)
    key(53,"\u{1B}"); try await Task.sleep(nanoseconds:50_000_000)
    precondition(!panelModel.visible && !panel.isVisible)
    print("PASS: launcher routing")
    exit(0)
}
Task { try await Task.sleep(nanoseconds:30_000_000_000); fatalError("Launcher routing tests timed out") }
app.run()
