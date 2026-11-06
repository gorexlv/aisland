// Pure launcher logic: registry, ordering, filtering and keyboard state machine. No UI, no hotkeys.
import Cocoa
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let a = ScreenTarget(id:1,pid:1,app:"Safari",bundleID:"test.safari",title:"Design notes")
    let b = ScreenTarget(id:2,pid:2,app:"Notes",bundleID:"test.notes",title:"Planning")
    let c = ScreenTarget(id:3,pid:3,app:"Xcode",bundleID:"test.xcode",title:"Launcher")
    precondition(duckCapabilities(for:a).first == .review && duckCapabilities(for:a).count == 2)
    precondition(DuckCapability.review.title == "批注" && DuckCapability.ocr.title == "OCR 读屏")
    precondition(DuckCapability.review.symbol == "square.and.pencil" && DuckCapability.ocr.symbol == "text.viewfinder")
    precondition(DuckCapability.allCases.filter(\.special) == [.larkProxy] && DuckCapability.larkProxy.title == "代发" && DuckCapability.larkProxy.symbol == "paperplane")
    precondition(!duckCapabilities(for:a).contains(.larkProxy))
    precondition(launcherOrderedTargets([a,b,c],frontID:c.id).map(\.id) == [3,1,2])
    precondition(launcherOrderedTargets([a,b,c],frontID:nil).map(\.id) == [1,2,3])
    precondition(launcherOrderedTargets([a,b,c],frontID:99).map(\.id) == [1,2,3])
    precondition(launcherFilteredCapabilities(DuckCapability.allCases,query:"ocr") == [.ocr])
    precondition(launcherFilteredCapabilities(DuckCapability.allCases,query:"代发") == [.larkProxy])
    precondition(launcherFilteredCapabilities(DuckCapability.allCases,query:"批注") == [.review])
    precondition(launcherFilteredCapabilities(DuckCapability.allCases,query:"  ").count == DuckCapability.allCases.count)
    precondition(launcherFilteredCapabilities(DuckCapability.allCases,query:"zzz").isEmpty)
    precondition(frontmostWindowID(pid:-1,among:[a,b,c]) == nil)

    @MainActor func makeModel(_ load: @escaping @MainActor () async throws -> [ScreenTarget] = { [a,b,c] }) async -> (LauncherModel, () -> [(ScreenTarget,DuckCapability,String)], () -> Int) {
        let m = LauncherModel()
        var launches: [(ScreenTarget,DuckCapability,String)] = [], closes = 0
        m.loadTargets = load
        m.onLaunch = { launches.append(($0,$1,$2)) }
        m.onClose = { closes += 1 }
        await m.open(frontPID:nil)
        return (m,{ launches },{ closes })
    }
    // Fast path
    var (m, launches, closes) = await makeModel()
    precondition(m.visible && m.step == .window && m.frontID == nil && m.targets.count == 3)
    m.frontID = c.id
    let first = m.windowRows[0]
    precondition(first.id == c.id)
    m.confirm(); precondition(m.step == .capability && m.target == first)
    m.confirm(); precondition(m.step == .ready && m.capability == .review)
    m.confirm()
    precondition(launches().count == 1 && launches()[0].0 == first && launches()[0].1 == .review && launches()[0].2 == "")
    precondition(!m.visible && closes() == 1)
    // Note
    (m, launches, closes) = await makeModel()
    m.confirm(); m.confirm(); m.query = " 看下标题 "; m.confirm()
    precondition(launches().count == 1 && launches()[0].2 == "看下标题")
    // Capability filter
    (m, launches, closes) = await makeModel()
    m.confirm(); m.move(1); m.query = "ocr"
    precondition(m.capabilityRows == [.ocr] && m.highlight == 0)
    m.confirm(); precondition(m.capability == .ocr && m.step == .ready && m.query.isEmpty)
    // Delete backward
    m.query = "x"; precondition(!m.deleteBackward() && m.step == .ready)
    m.query = ""; precondition(m.deleteBackward() && m.step == .capability && m.capability == nil)
    precondition(m.deleteBackward() && m.step == .window && m.target == nil)
    precondition(!m.deleteBackward())
    // Move clamp
    m.move(5); precondition(m.highlight == 2)
    m.move(-9); precondition(m.highlight == 0)
    // Errors
    struct Denied: Error {}
    (m, launches, closes) = await makeModel { throw Denied() }
    precondition(m.status.contains("录制屏幕") && m.permissionError)
    m.confirm(); precondition(launches().isEmpty)
    (m, launches, closes) = await makeModel { [] }
    precondition(m.status == "没有可选窗口，请打开应用后重试" && !m.permissionError)
    m.confirm(); precondition(launches().isEmpty && m.step == .window)
    // Stale load must not overwrite a newer open or a closed launcher
    let stale = LauncherModel()
    var waiting: [CheckedContinuation<[ScreenTarget],Never>] = []
    stale.loadTargets = { await withCheckedContinuation { waiting.append($0) } }
    let t1 = Task { await stale.open(frontPID:nil) }
    while waiting.count < 1 { await Task.yield() }
    let t2 = Task { await stale.open(frontPID:nil) }
    while waiting.count < 2 { await Task.yield() }
    waiting[1].resume(returning:[b]); await t2.value
    precondition(stale.targets.map(\.id) == [2] && stale.visible)
    waiting[0].resume(returning:[a,c]); await t1.value
    precondition(stale.targets.map(\.id) == [2] && stale.status.isEmpty, "stale load overwrote newer open")
    let t3 = Task { await stale.open(frontPID:nil) }
    while waiting.count < 3 { await Task.yield() }
    stale.close()
    waiting[2].resume(returning:[a]); await t3.value
    precondition(!stale.visible && stale.targets.isEmpty, "load after Esc must be dropped")
    stale.loadTargets = { throw Denied() }
    let t4 = Task { await stale.open(frontPID:nil) }
    await t4.value; stale.close()
    precondition(stale.visible == false)
    precondition(launcherDeleteAllowed(isRepeat:false,responder:nil) && !launcherDeleteAllowed(isRepeat:true,responder:nil))
    let tv = NSTextView(); precondition(launcherDeleteAllowed(isRepeat:false,responder:tv))
    tv.setMarkedText("ni",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:0,length:0))
    precondition(!launcherDeleteAllowed(isRepeat:false,responder:tv), "marked text must block tag deletion")
    // reset is synchronous and clears stale state
    m.target = a; m.step = .capability; m.permissionError = true; m.reset()
    precondition(m.step == .window && m.target == nil && !m.permissionError && m.targets.isEmpty)
    print("PASS: launcher logic")
    exit(0)
}
app.run()
