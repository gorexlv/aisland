import Cocoa
import SwiftUI
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
enum ScreenCapturePurpose { case review, ocr }
func screenCaptureSize(_ size: CGSize, scale: CGFloat, purpose: ScreenCapturePurpose) -> CGSize {
    let width = max(1, size.width), height = max(1, size.height)
    let budget: CGFloat = purpose == .ocr ? 12_000_000 : 6_000_000
    let edge: CGFloat = purpose == .ocr ? 8192 : 4096
    let ratio = min(max(1,min(scale,2)), sqrt(budget / width / height), edge / max(width,height))
    return CGSize(width:max(1,floor(width * ratio)),height:max(1,floor(height * ratio)))
}
func captureScreenWindow(_ target: ScreenTarget, purpose: ScreenCapturePurpose = .review) async throws -> (Data, CGSize) {
    let window = try await resolveScreenWindow(target)
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    let size = screenCaptureSize(window.frame.size,scale:CGFloat(filter.pointPixelScale),purpose:purpose)
    config.width = Int(size.width)
    config.height = Int(size.height)
    config.showsCursor = false
    config.ignoreShadowsSingleWindow = true
    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { throw NotesFailure(detail: "无法读取窗口画面") }
    return (data, CGSize(width: image.width, height: image.height))
}

// Region coordinates are normalized within one display, with top-left origin.
// ScreenCaptureKit resolves the display itself, avoiding global AppKit Y offsets.
func displayRegionRect(_ region: CGRect, size: CGSize) -> CGRect {
    CGRect(x:region.minX * size.width,y:region.minY * size.height,width:region.width * size.width,height:region.height * size.height)
}
func captureDisplayRegion(displayID: UInt32, region: CGRect) async throws -> Data {
    let content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
    guard let display = content.displays.first(where:{$0.displayID == displayID}),
          region.width > 0, region.height > 0, region.minX >= 0, region.minY >= 0, region.maxX <= 1, region.maxY <= 1 else {
        throw NotesFailure(detail:"屏幕或框选区域已失效")
    }
    let own = content.applications.filter { $0.processID == getpid() }
    let filter = SCContentFilter(display:display,excludingApplications:own,exceptingWindows:[])
    let config = SCStreamConfiguration()
    let rect = displayRegionRect(region,size:filter.contentRect.size)
    config.sourceRect = rect
    let size = screenCaptureSize(rect.size,scale:CGFloat(filter.pointPixelScale),purpose:.ocr)
    config.width = Int(size.width); config.height = Int(size.height); config.showsCursor = false
    let image = try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
    guard let data = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else { throw NotesFailure(detail:"无法读取屏幕区域") }
    return data
}

struct ScreenTargetRow: View {
    let target: ScreenTarget
    var body: some View {
        HStack(spacing:12) {
            if let icon = NSRunningApplication(processIdentifier:target.pid)?.icon {
                Image(nsImage:icon).resizable().scaledToFit().frame(width:32,height:32)
            } else { Image(systemName:"macwindow").font(.system(size:22)).frame(width:32,height:32).foregroundStyle(IslandStyle.secondary) }
            VStack(alignment:.leading,spacing:4) {
                Text(target.title.isEmpty ? target.app : target.title).font(.system(size:14)).lineLimit(2)
                Text(target.app).font(.system(size:12)).foregroundStyle(IslandStyle.secondary)
            }
            Spacer(minLength:4)
            Image(systemName:"chevron.right").font(.system(size:12)).foregroundStyle(IslandStyle.secondary)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,9).contentShape(Rectangle())
            .help(target.label).accessibilityElement(children:.combine)
    }
}
