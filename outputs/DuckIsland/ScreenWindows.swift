import Cocoa
import ScreenCaptureKit

struct ScreenTarget: Codable, Identifiable, Equatable {
    let id: UInt32
    let pid: Int32
    let app: String
    let bundleID: String
    let title: String
    var label: String { title.isEmpty ? app : app + " · " + title }

}
func visibleScreenTargets() async throws -> [ScreenTarget] {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    return content.windows.compactMap { window in
        guard window.windowLayer == 0, window.frame.width > 100, window.frame.height > 80,
              let app = window.owningApplication, app.processID != getpid(),
              app.bundleIdentifier != "local.rexlv.duckisland",
              NSRunningApplication(processIdentifier: app.processID)?.activationPolicy == .regular else { return nil }
        return ScreenTarget(id: window.windowID, pid: app.processID, app: app.applicationName,
                            bundleID: app.bundleIdentifier, title: window.title ?? "")
    }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
}
func resolveScreenWindow(_ target: ScreenTarget) async throws -> SCWindow {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
    guard let window = content.windows.first(where: { $0.windowID == target.id && $0.owningApplication?.processID == target.pid && $0.owningApplication?.bundleIdentifier == target.bundleID }),
          NSRunningApplication(processIdentifier: target.pid) != nil else {
        throw NotesFailure(detail: "选中的窗口已关闭，请重新选择窗口")
    }
    return window
}
func captureScreenWindow(_ target: ScreenTarget) async throws -> (Data, CGSize) {
    let window = try await resolveScreenWindow(target)
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    let ratio = min(1, 1440 / max(window.frame.width, 1))
    config.width = max(1, Int(window.frame.width * ratio))
    config.height = max(1, Int(window.frame.height * ratio))
    config.showsCursor = false
    config.ignoreShadowsSingleWindow = true
    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { throw NotesFailure(detail: "无法读取窗口画面") }
    return (data, CGSize(width: image.width, height: image.height))
}
