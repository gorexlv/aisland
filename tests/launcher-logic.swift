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

    print("PASS: launcher logic")
    exit(0)
}
app.run()
