// Register an isolated test chord; deliver Carbon events directly, never type into other apps.
import Cocoa
import Carbon
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let sampleTargets = [ScreenTarget(id:1,pid:1,app:"Safari",bundleID:"test.safari",title:"Design notes"),ScreenTarget(id:2,pid:2,app:"Notes",bundleID:"test.notes",title:"Planning")]
    precondition(reviewFilteredTargets(sampleTargets,query:"safari notes").map(\.id) == [1])
    precondition(reviewFilteredTargets(sampleTargets,query:"  ").count == 2)
    precondition(reviewFilteredTargets(sampleTargets,query:"missing").isEmpty)
    precondition(reviewPickerItems(sampleTargets,query:"e").first == .exit)
    precondition(reviewPickerItems(sampleTargets,query:"missing").isEmpty)
    precondition(reviewPickerHeight(rowCount:1,availableHeight:800) < reviewPickerHeight(rowCount:3,availableHeight:800))
    precondition(reviewPickerHeight(rowCount:100,availableHeight:800) == 520)
    let hotKey = ReviewHotKey(), duplicate = ReviewHotKey()
    let modifiers = UInt32(controlKey | optionKey | cmdKey | shiftKey)
    var toggles = 0, detaches = 0, pickers = 0
    precondition(hotKey.start(toggleKey:UInt32(kVK_F18),detachKey:UInt32(kVK_F19),modifiers:modifiers,pickerKey:UInt32(kVK_F16),pickerModifiers:modifiers,action:{ toggles += 1 },detach:{ detaches += 1 },picker:{ pickers += 1 }))
    @MainActor func emit(_ id:UInt32,_ pressed:Bool) {
        var event: EventRef?
        precondition(CreateEvent(nil,OSType(kEventClassKeyboard),UInt32(pressed ? kEventHotKeyPressed : kEventHotKeyReleased),0,EventAttributes(kEventAttributeUserEvent),&event) == noErr)
        defer { ReleaseEvent(event) }
        var value = EventHotKeyID(signature:ReviewHotKey.signature,id:id)
        precondition(SetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),MemoryLayout<EventHotKeyID>.size,&value) == noErr)
        _ = SendEventToEventTarget(event,GetApplicationEventTarget())
    }
    emit(99,true); precondition(toggles == 0 && detaches == 0)
    emit(1,true); emit(1,true); emit(2,true)
    precondition(toggles == 1 && detaches == 1)
    emit(3,true); emit(3,true); precondition(pickers == 1)
    emit(3,false); emit(3,true); precondition(pickers == 2)
    emit(1,false); emit(1,true); precondition(toggles == 2)
    precondition(!duplicate.start(toggleKey:UInt32(kVK_F17),detachKey:UInt32(kVK_F19),modifiers:modifiers,pickerKey:UInt32(kVK_F16),pickerModifiers:modifiers,action:{},detach:{}))
    emit(2,false); emit(2,true); precondition(detaches == 2)
    hotKey.stop(); emit(1,true); precondition(toggles == 2)
    precondition(duplicate.start(toggleKey:UInt32(kVK_F17),detachKey:UInt32(kVK_F19),modifiers:modifiers,pickerKey:UInt32(kVK_F16),pickerModifiers:modifiers,action:{},detach:{}), "Failed partial registration must release its first chord")
    duplicate.stop()

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-hotkey-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let review = ReviewModel(storageRoot:root)
    let recorder = Recorder(review:review)
    let image = NSImage(size:NSSize(width:100,height:100),flipped:false) { rect in NSColor.white.setFill(); rect.fill(); return true }
    let shot = ReviewSnapshot(id:UUID(),image:image,png:try reviewPNG(image),frame:CGRect(x:100,y:100,width:100,height:100))
    review.active = true; review.paused = true; review.current = shot; review.snapshots = [shot]
    review.busy = true; recorder.toggleReviewShortcut(); precondition(review.paused)
    review.busy = false; recorder.terminationRequested = true
    recorder.toggleReviewShortcut(); precondition(review.paused)
    recorder.terminationRequested = false; recorder.toggleReviewShortcut()
    while review.busy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(!review.paused && review.active && review.snapshots.count == 1, "Shortcut must save and exit a page without ending the session")
    let pickerReady = await review.prepareTargetPicker()
    precondition(pickerReady, "Existing session must open picker after saving")
    precondition(review.active && review.picking && !review.paused && review.snapshots.count == 1)
    precondition(review.panels.selectionOverlay == nil && review.panels.toolbar == nil)
    precondition(review.panels.sidebar?.isVisible == true)
    let pickerFrame = review.panels.sidebar!.frame, screenFrame = NSScreen.main!.visibleFrame
    precondition(abs(pickerFrame.midX-screenFrame.midX) < 1 && abs(pickerFrame.midY-screenFrame.midY) < 1, "Picker must be centered")
    review.targets = sampleTargets
    try await Task.sleep(nanoseconds:50_000_000)
    let pickerView = review.panels.sidebar!.contentView!
    pickerView.layoutSubtreeIfNeeded()
    let pickerBitmap = pickerView.bitmapImageRepForCachingDisplay(in:pickerView.bounds)!
    pickerView.cacheDisplay(in:pickerView.bounds,to:pickerBitmap)
    try pickerBitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/aisland-review-controls/target-picker-search.png"))
    precondition(abs(review.panels.sidebar!.frame.height-reviewPickerHeight(rowCount:3,availableHeight:screenFrame.height-32)) < 1)
    func findSearch(_ view:NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        return view.subviews.compactMap { findSearch($0) }.first
    }
    let search = findSearch(pickerView)!, pickerWindow = review.panels.sidebar!
    pickerWindow.makeKeyAndOrderFront(nil); pickerWindow.makeFirstResponder(search)
    let editor = search.currentEditor() as! NSTextView
    editor.insertText("missing",replacementRange:NSRange(location:0,length:editor.string.utf16.count))
    try await Task.sleep(nanoseconds:50_000_000)
    precondition(abs(pickerWindow.frame.height-reviewPickerHeight(rowCount:0,availableHeight:screenFrame.height-32)) < 1)
    func key(_ code:UInt16,_ characters:String) {
        let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:pickerWindow.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code)!
        pickerWindow.sendEvent(event)
    }
    key(36,"\r")
    try await Task.sleep(nanoseconds:30_000_000)
    precondition(review.active, "Enter with no match must not activate stale selection")
    editor.insertText("e",replacementRange:NSRange(location:0,length:editor.string.utf16.count))
    try await Task.sleep(nanoseconds:50_000_000)
    key(125,"\u{F701}")
    try await Task.sleep(nanoseconds:30_000_000)
    key(126,"\u{F700}")
    try await Task.sleep(nanoseconds:30_000_000)
    key(36,"\r")
    try await Task.sleep(nanoseconds:50_000_000)
    while review.busy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(!review.active && review.target == nil, "e selects exit; down/up and Enter must invoke the highlighted row")
    review.panels.close()
    print("PASS: global three-chord registration, routing, repeat/key-up handling, partial conflict cleanup, busy/termination guards, dynamic picker sizing, live search, native arrow navigation and Enter exit")
    exit(0)
}
Task { try await Task.sleep(nanoseconds:20_000_000_000); fatalError("Hotkey tests timed out") }
app.run()
