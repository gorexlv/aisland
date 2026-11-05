import Cocoa
import CoreGraphics

enum DuckCapability: String, CaseIterable, Identifiable {
    case review, ocr
    var id: String { rawValue }
    var title: String { self == .review ? "批注" : "OCR 读屏" }
    var symbol: String { self == .review ? "square.and.pencil" : "text.viewfinder" }
    var special: Bool { false }
}
func duckCapabilities(for target: ScreenTarget) -> [DuckCapability] { [.review, .ocr] }
func launcherOrderedTargets(_ targets: [ScreenTarget], frontID: UInt32?) -> [ScreenTarget] {
    guard let frontID, let index = targets.firstIndex(where: { $0.id == frontID }) else { return targets }
    var result = targets
    result.insert(result.remove(at: index), at: 0)
    return result
}
func frontmostWindowID(pid: pid_t, among targets: [ScreenTarget]) -> UInt32? {
    guard let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return nil }
    let ids = Set(targets.map(\.id))
    for window in info {
        guard (window[kCGWindowOwnerPID as String] as? Int32) == pid, (window[kCGWindowLayer as String] as? Int) == 0,
              let number = window[kCGWindowNumber as String] as? UInt32, ids.contains(number) else { continue }
        return number
    }
    return nil
}
func launcherFilteredCapabilities(_ items: [DuckCapability], query: String) -> [DuckCapability] {
    let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    return items.filter { item in terms.allSatisfy { item.title.localizedStandardContains($0) } }
}
