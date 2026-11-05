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
    precondition(DuckCapability.allCases.allSatisfy { !$0.special })
    precondition(launcherOrderedTargets([a,b,c],frontID:c.id).map(\.id) == [3,1,2])
    precondition(launcherOrderedTargets([a,b,c],frontID:nil).map(\.id) == [1,2,3])
    precondition(launcherOrderedTargets([a,b,c],frontID:99).map(\.id) == [1,2,3])
    precondition(launcherFilteredCapabilities(DuckCapability.allCases,query:"ocr") == [.ocr])
    precondition(launcherFilteredCapabilities(DuckCapability.allCases,query:"批注") == [.review])
    precondition(launcherFilteredCapabilities(DuckCapability.allCases,query:"  ").count == 2)
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
    precondition(m.status.contains("录制屏幕"))
    m.confirm(); precondition(launches().isEmpty)
    (m, launches, closes) = await makeModel { [] }
    precondition(m.status == "没有可选窗口，请打开应用后重试")
    m.confirm(); precondition(launches().isEmpty && m.step == .window)
    print("PASS: launcher logic")
    exit(0)
}
app.run()
