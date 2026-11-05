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

enum LauncherStep { case window, capability, ready }
@MainActor final class LauncherModel: ObservableObject {
    @Published var step: LauncherStep = .window
    @Published var query = "" { didSet { if query != oldValue { highlight = 0 } } }
    @Published var targets: [ScreenTarget] = []
    @Published var frontID: UInt32?
    @Published var target: ScreenTarget?
    @Published var capability: DuckCapability?
    @Published var highlight = 0
    @Published var status = ""
    @Published var visible = false
    var loadTargets: () async throws -> [ScreenTarget] = visibleScreenTargets
    var onLaunch: (ScreenTarget, DuckCapability, String) -> Void = { _, _, _ in }
    var onClose: () -> Void = {}
    var windowRows: [ScreenTarget] { reviewFilteredTargets(launcherOrderedTargets(targets, frontID: frontID), query: query) }
    var capabilityRows: [DuckCapability] { target.map { launcherFilteredCapabilities(duckCapabilities(for: $0), query: query) } ?? [] }
    private var rowCount: Int { step == .window ? windowRows.count : step == .capability ? capabilityRows.count : 0 }
    func open(frontPID: pid_t?) async {
        step = .window; query = ""; targets = []; frontID = nil; target = nil; capability = nil; highlight = 0; status = ""; visible = true
        do { targets = try await loadTargets() } catch { status = "请允许Mo · 墨录制屏幕后重试"; return }
        if targets.isEmpty { status = "没有可选窗口，请打开应用后重试"; return }
        if let frontPID { frontID = frontmostWindowID(pid: frontPID, among: targets) }
        highlight = 0
    }
    func move(_ delta: Int) { highlight = max(0, min(highlight + delta, max(rowCount - 1, 0))) }
    func confirm() {
        switch step {
        case .window:
            guard windowRows.indices.contains(highlight) else { return }
            target = windowRows[highlight]; query = ""; step = .capability; highlight = 0
        case .capability:
            guard capabilityRows.indices.contains(highlight) else { return }
            capability = capabilityRows[highlight]; query = ""; step = .ready
        case .ready:
            guard let target, let capability else { return }
            onLaunch(target, capability, query.trimmingCharacters(in: .whitespacesAndNewlines)); close()
        }
    }
    func deleteBackward() -> Bool {
        guard query.isEmpty else { return false }
        switch step {
        case .ready: capability = nil; step = .capability; highlight = 0; return true
        case .capability: target = nil; step = .window; highlight = 0; return true
        case .window: return false
        }
    }
    func close() { visible = false; onClose() }
}
