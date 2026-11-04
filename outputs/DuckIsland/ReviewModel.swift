import Cocoa
import SwiftUI
import Combine

struct ReviewRegion: Identifiable, Codable {
    var id = UUID()
    let snapshotID: UUID
    let number: Int
    let rect: CGRect // normalized top-left coordinates
    var feedback = ""
}
struct ReviewSnapshot: Identifiable {
    let id: UUID
    let image: NSImage
    let png: Data
    let frame: CGRect
}
func reviewSelection(_ start: CGPoint, _ end: CGPoint, size: CGSize) -> CGRect? {
    guard size.width > 0, size.height > 0 else { return nil }
    let x1 = max(0,min(size.width,start.x)), x2 = max(0,min(size.width,end.x))
    let y1 = max(0,min(size.height,start.y)), y2 = max(0,min(size.height,end.y))
    guard abs(x2-x1) >= 8, abs(y2-y1) >= 8 else { return nil }
    return CGRect(x:min(x1,x2)/size.width,y:min(y1,y2)/size.height,width:abs(x2-x1)/size.width,height:abs(y2-y1)/size.height)
}
func reviewScreenRect(_ frame: CGRect, desktopTop: CGFloat) -> CGRect {
    CGRect(x:frame.minX,y:desktopTop-frame.maxY,width:frame.width,height:frame.height)
}

@MainActor final class ReviewModel: ObservableObject {
    @Published var active = false
    @Published var picking = false
    @Published var paused = false
    @Published var busy = false
    @Published var targets: [ScreenTarget] = []
    @Published var target: ScreenTarget?
    @Published var regions: [ReviewRegion] = []
    @Published var selectedID: UUID?
    @Published var status = "选择窗口开始批阅"
    @Published var copied = false
    let voice = VoiceInput()
    var snapshots: [ReviewSnapshot] = []
    var current: ReviewSnapshot?
    var panels: ReviewPanels!
    private var token = UUID()
    private var saveFolder: URL?
    private var voiceChanges: AnyCancellable?
    private var tracking: Timer?
    private var trackingBusy = false
    var onNotice: ((String)->Void)?
    init() {
        panels = ReviewPanels(model:self)
        voiceChanges = voice.$draft.sink { [weak self] text in
            guard let self, let id = self.selectedID, let index = self.regions.firstIndex(where:{$0.id == id}) else { return }
            self.regions[index].feedback = text
            self.copied = false
        }
    }
    func start() {
        if active { panels.showSidebar(); return }
        active = true; picking = true; busy = true; copied = false
        regions = []; snapshots = []; current = nil; selectedID = nil; saveFolder = nil
        token = UUID(); let session = token
        status = "正在扫描当前桌面…"; panels.showSidebar()
        Task {
            defer { if token == session { busy = false } }
            do {
                let found = try await visibleScreenTargets()
                guard token == session else { return }
                targets = found
                if found.count == 1 { await choose(found[0]) }
                else {
                    status = found.isEmpty ? "没有可选窗口，请打开应用后刷新" : "点击窗口高亮边框，或在列表中选择"
                    await panels.showHighlights(found)
                }
            } catch { status = "无法读取屏幕，请在系统设置中允许小鸭录制屏幕后重试" }
        }
    }
    func refreshPicker() { close(); start() }
    func choose(_ item: ScreenTarget) async {
        let session = token
        do {
            let window = try await resolveScreenWindow(item)
            guard token == session, active else { return }
            target = item; picking = false; panels.clearHighlights()
            panels.positionSidebar(window.frame); panels.showSidebar()
            status = "点击暂停，冻结画面后框选批阅"
            tracking?.invalidate()
            tracking = Timer.scheduledTimer(withTimeInterval:0.8,repeats:true) { [weak self] _ in
                Task { @MainActor in await self?.track() }
            }
        } catch { status = error.localizedDescription }
    }
    private func track() async {
        guard active, !picking, !busy, !trackingBusy, let target else { return }
        trackingBusy = true; defer { trackingBusy = false }
        let session = token
        do {
            let window = try await resolveScreenWindow(target)
            guard session == token else { return }
            let visible = (CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []).contains { ($0[kCGWindowNumber as String] as? UInt32) == target.id }
            if visible {
                panels.positionSidebar(paused ? (current?.frame ?? window.frame) : window.frame)
                panels.showSidebar()
                if paused { panels.overlay?.orderFrontRegardless() }
            } else { panels.hideForWorkspace() }
        } catch {
            guard session == token else { return }
            stopVoice(); panels.hideOverlay(); paused = false
            status = "目标窗口已关闭，已有批阅仍可完成并复制"
            tracking?.invalidate(); panels.showSidebar()
        }
    }
    func pause() {
        guard active, !paused, !busy, let target else { return }
        busy = true; copied = false; let session = token
        status = "正在截取窗口…"
        Task {
            defer { if token == session { busy = false } }
            do {
                let window = try await resolveScreenWindow(target)
                let (data, _) = try await captureScreenWindow(target)
                guard token == session, let image = NSImage(data:data) else { return }
                let snapshot = ReviewSnapshot(id:UUID(),image:image,png:data,frame:window.frame)
                snapshots.append(snapshot); current = snapshot; paused = true
                panels.showOverlay(snapshot); panels.positionSidebar(window.frame)
                status = "拖动框选；点击框选区域可语音批阅"
            } catch { status = error.localizedDescription }
        }
    }
    func addRegion(_ rect: CGRect) {
        guard paused, let current else { return }
        stopVoice()
        let item = ReviewRegion(snapshotID:current.id,number:regions.count+1,rect:rect)
        regions.append(item); select(item.id)
        status = "已框选 #\(item.number)，输入意见或点击麦克风"
        panels.redraw()
    }
    func select(_ id: UUID, speak: Bool = false) {
        if speak && selectedID == id && voice.dictating { voice.finishVoice(cancel:false); return }
        stopVoice(); selectedID = id
        voice.draft = regions.first(where:{$0.id == id})?.feedback ?? ""
        voice.status = "可输入文字，或点击麦克风录入"
        panels.redraw()
        if speak { voice.toggleVoice() }
    }
    func stopVoice() { voice.finishVoice(cancel:true) }
    private func finishDictation() async {
        if voice.dictating { voice.finishVoice(cancel:false) }
        let deadline = Date().addingTimeInterval(3)
        while voice.voiceFinishing && Date() < deadline { try? await Task.sleep(nanoseconds:100_000_000) }
        stopVoice()
    }
    func resume() {
        guard paused, !busy else { return }
        busy = true
        status = "正在保存标记并恢复窗口…"
        let session = token
        Task {
            await finishDictation()
            guard token == session else { return }
            defer { busy = false }
            do { try persist(); panels.hideOverlay(); paused = false; status = "已保存批阅，可继续操作应用；暂停可批阅下一张画面" }
            catch { status = "保存失败：\(error.localizedDescription)，批阅仍保留，请重试" }
        }
    }
    func finish() {
        guard !busy, !snapshots.isEmpty else { return }
        busy = true
        status = "正在保存并复制批阅…"
        let session = token
        Task {
            await finishDictation()
            guard token == session else { return }
            defer { busy = false }
            do {
                try persist()
                try copyReview(target:target?.label ?? "窗口批阅",regions:regions,snapshots:snapshots)
                copied = true; paused = false; panels.hideOverlay()
                status = "已复制全部图片和评审意见，可直接粘贴"
                onNotice?("批阅已复制：\(snapshots.count) 张画面，\(regions.count) 条意见")
            } catch { status = "复制失败：\(error.localizedDescription)，记录已保留" }
        }
    }
    func persist() throws {
        guard !snapshots.isEmpty else { return }
        if saveFolder == nil {
            let root = try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("DuckIsland/Reviews")
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let folder = root.appendingPathComponent(formatter.string(from:Date()) + "-" + UUID().uuidString.prefix(6))
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            saveFolder = folder
        }
        guard let folder = saveFolder else { return }
        for (index, shot) in snapshots.enumerated() {
            let marked = annotatedReviewImage(shot,regions:regions.filter{$0.snapshotID == shot.id})
            try reviewPNG(marked).write(to:folder.appendingPathComponent(String(format:"%02d",index+1)+"-"+shot.id.uuidString+".png"),options:.atomic)
        }
        try JSONEncoder().encode(regions).write(to:folder.appendingPathComponent("regions.json"),options:.atomic)
        try reviewPlainText(target:target?.label ?? "窗口批阅",regions:regions,snapshots:snapshots).write(to:folder.appendingPathComponent("review.txt"),atomically:true,encoding:.utf8)
    }
    func reveal() { if let saveFolder { NSWorkspace.shared.activateFileViewerSelecting([saveFolder]) } }
    func close() {
        stopVoice()
        do { try persist() } catch { status = "保存失败，请重试后关闭：\(error.localizedDescription)"; return }
        token = UUID(); tracking?.invalidate(); tracking = nil
        panels.close(); active = false; picking = false; paused = false; busy = false; target = nil
    }
}
