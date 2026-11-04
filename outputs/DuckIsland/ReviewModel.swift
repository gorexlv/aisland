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
    var capturedAt: Date? = Date()
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
    @Published var snapshots: [ReviewSnapshot] = []
    @Published var current: ReviewSnapshot?
    var panels: ReviewPanels!
    private struct EditState {
        let snapshots: [ReviewSnapshot]
        let regions: [ReviewRegion]
        let selectedID: UUID?
        let currentID: UUID?
    }
    private var undoStates: [EditState] = []
    @Published private(set) var canUndo = false
    private func rememberEdit() {
        undoStates.append(EditState(snapshots:snapshots, regions:regions, selectedID:selectedID, currentID:current?.id))
        if undoStates.count > 30 { undoStates.removeFirst() }
        canUndo = true
    }
    private var token = UUID()
    private var saveFolder: URL?
    private let store = ReviewStore()
    private let storageRoot: URL?
    private var autosave: Task<Void,Never>?
    @Published var recoveryFolder: URL?
    private var voiceChanges: AnyCancellable?
    private var tracking: Timer?
    private var trackingBusy = false
    var onNotice: ((String)->Void)?
    init(storageRoot: URL? = nil) {
        self.storageRoot = storageRoot
        panels = ReviewPanels(model:self)
        voiceChanges = voice.$draft.sink { [weak self] text in
            guard let self, let id = self.selectedID, let index = self.regions.firstIndex(where:{$0.id == id}) else { return }
            self.regions[index].feedback = text
            self.copied = false
            self.scheduleSave()
        }
    }
    func start() {
        if active { panels.showSidebar(); return }
        active = true; picking = true; busy = true; copied = false
        regions = []; snapshots = []; current = nil; selectedID = nil; saveFolder = nil
        undoStates = []; canUndo = false
        token = UUID(); let session = token
        status = "正在扫描当前桌面…"; panels.showSidebar()
        Task {
            if let root = try? (storageRoot ?? ReviewStore.defaultRoot()) { recoveryFolder = try? await store.latest(root:root) }
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
    func refreshPicker() { Task { if await closeForTermination() { start() } } }
    func choose(_ item: ScreenTarget) async {
        let session = token
        do {
            let window = try await resolveScreenWindow(item)
            guard token == session, active else { return }
            target = item; picking = false; panels.clearHighlights()
            panels.positionSidebar(window.frame); panels.showSidebar()
            status = "点击「截取画面并标注」，在截图上框选批阅"
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
            await finishDictation(); panels.hideOverlay(); paused = false
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
                try await persist()
                status = "拖动框选；点击区域选中，点击麦克风录入意见"
            } catch { status = "截图或保存失败：\(error.localizedDescription)，已截取画面仍保留，可重试保存" }
        }
    }
    func addRegion(_ rect: CGRect) {
        guard paused, !busy, let current else { return }
        let item = ReviewRegion(snapshotID:current.id,number:(regions.map(\.number).max() ?? 0)+1,rect:rect)
        rememberEdit()
        regions.append(item); select(item.id)
        scheduleSave()
        panels.redraw()
    }
    func select(_ id: UUID, speak: Bool = false) {
        guard !busy else { return }
        if speak && selectedID == id && voice.dictating { voice.finishVoice(cancel:false); return }
        busy = true
        Task {
            // Keep selectedID unchanged until every accepted final callback is delivered.
            await finishDictation()
            selectedID = id
            voice.draft = regions.first(where:{$0.id == id})?.feedback ?? ""
            voice.status = "可输入文字，或点击麦克风录入"
            if paused, let shotID = regions.first(where:{$0.id == id})?.snapshotID,
               let shot = snapshots.first(where:{$0.id == shotID}), current?.id != shotID {
                current = shot; panels.showOverlay(shot)
            }
            busy = false; panels.redraw()
            if speak { voice.toggleVoice() }
        }
    }
    /// Finish accepted speech before changing identities or recording an undo state.
    func deleteSelectedRegion() async {
        guard !busy, let id = selectedID else { return }
        busy = true; defer { busy = false }
        await finishDictation()
        guard regions.contains(where: { $0.id == id }) else { return }
        rememberEdit()
        regions.removeAll { $0.id == id }; selectedID = nil; voice.draft = ""
        await saveEdit("已删除标记及其意见，可撤销")
    }
    func deleteSnapshot(_ id: UUID) async {
        guard !busy, snapshots.contains(where: { $0.id == id }) else { return }
        busy = true; defer { busy = false }
        await finishDictation()
        rememberEdit()
        let count = regions.filter { $0.snapshotID == id }.count
        regions.removeAll { $0.snapshotID == id }; snapshots.removeAll { $0.id == id }
        if !regions.contains(where: { $0.id == selectedID }) { selectedID = nil; voice.draft = "" }
        if current?.id == id { current = snapshots.last }
        await saveEdit("已删除截图及 \(count) 条意见，可撤销")
    }
    func undoEdit() async {
        guard !busy, !undoStates.isEmpty else { return }
        busy = true; defer { busy = false }
        await finishDictation()
        let state = undoStates.removeLast()
        // Preserve edits to surviving regions; undo only changes structural membership.
        let live = Dictionary(uniqueKeysWithValues:regions.map { ($0.id, $0.feedback) })
        snapshots = state.snapshots
        regions = state.regions.map { item in
            var item = item; if let text = live[item.id] { item.feedback = text }; return item
        }
        selectedID = state.selectedID
        current = snapshots.first { $0.id == state.currentID } ?? snapshots.last
        voice.draft = regions.first { $0.id == selectedID }?.feedback ?? ""
        canUndo = !undoStates.isEmpty
        await saveEdit("已撤销；恢复的截图和意见已保留")
    }
    private func saveEdit(_ notice: String) async {
        copied = false; autosave?.cancel()
        if paused { if let current { panels.showOverlay(current) } else { panels.hideOverlay(); paused = false } }
        panels.redraw()
        do { try await persist(); status = notice }
        catch { status = "保存失败：\(error.localizedDescription)，修改仍保留，可重试保存" }
    }
    func stopVoice() { voice.finishVoice(cancel:true) }
    private func finishDictation() async { await voice.finishAndWait() }
    private func scheduleSave() {
        autosave?.cancel()
        guard active, !snapshots.isEmpty else { return }
        autosave = Task {
            do { try await Task.sleep(nanoseconds:400_000_000); try Task.checkCancellation(); try await persist() }
            catch is CancellationError { }
            catch { status = "自动保存失败：\(error.localizedDescription)，请重试保存后关闭" }
        }
    }
    func resume() {
        guard paused, !busy else { return }
        busy = true
        status = "正在保存标记并返回实时窗口…"
        let session = token
        Task {
            await finishDictation()
            guard token == session else { return }
            defer { busy = false }
            do { try await persist(); panels.hideOverlay(); paused = false; status = "已保存批阅，已返回实时窗口；可再次截取画面并标注" }
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
                try await persist()
                try copyReview(target:target?.label ?? "窗口批阅",regions:regions,snapshots:snapshots)
                copied = true
                status = "已复制全部图片和评审意见，可直接粘贴"
                onNotice?("批阅已复制：\(snapshots.count) 张画面，\(regions.count) 条意见")
            } catch { status = "保存或复制失败：\(error.localizedDescription)，内容仍在当前会话中，请重试" }
        }
    }
    func persist() async throws {
        guard !snapshots.isEmpty || saveFolder != nil else { return }
        if saveFolder == nil {
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            saveFolder = try (storageRoot ?? ReviewStore.defaultRoot()).appendingPathComponent(formatter.string(from:Date()) + "-" + UUID().uuidString)
        }
        let session = StoredReviewSession(target:target,shots:snapshots.map { StoredReviewShot(id:$0.id,frame:$0.frame,capturedAt:$0.capturedAt) },regions:regions,selectedID:selectedID)
        let payload = ReviewSavePayload(session:session,originals:Dictionary(uniqueKeysWithValues:snapshots.map { ($0.id,$0.png) }),text:reviewPlainText(target:target?.label ?? "窗口批阅",regions:regions,snapshots:snapshots))
        try await store.save(payload,folder:saveFolder!)
    }
    func restoreLatest() {
        guard !busy, let folder = recoveryFolder else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await restore(folder:folder)
            } catch { status = "恢复失败：\(error.localizedDescription)。原文件未修改" }
        }
    }
    func restore(folder: URL, presentPanels: Bool = true) async throws {
        let payload = try await store.load(folder:folder)
        let restored = try payload.session.shots.map { shot -> ReviewSnapshot in
            guard let data = payload.originals[shot.id], let image = NSImage(data:data) else { throw NotesFailure(detail:"批阅原图无法恢复") }
            return ReviewSnapshot(id:shot.id,image:image,png:data,frame:shot.frame,capturedAt:shot.capturedAt)
        }
        await finishDictation()
        undoStates = []; canUndo = false
        token = UUID(); tracking?.invalidate(); tracking = nil
        snapshots = restored; regions = payload.session.regions; target = payload.session.target
        selectedID = payload.session.selectedID; saveFolder = folder
        let selectedShot = regions.first(where:{$0.id == selectedID})?.snapshotID
        current = restored.first(where:{$0.id == selectedShot}) ?? restored.last
        active = true; picking = false; paused = !restored.isEmpty
        if presentPanels { panels.clearHighlights() }
        voice.draft = regions.first(where:{$0.id == selectedID})?.feedback ?? ""
        if presentPanels, let current { panels.showOverlay(current); panels.positionSidebar(current.frame) }
        status = "已恢复批阅，可继续编辑意见并完成复制；原窗口可能已关闭"
    }
    func reveal() { if let saveFolder { NSWorkspace.shared.activateFileViewerSelecting([saveFolder]) } }
    func close() { Task { _ = await closeForTermination() } }
    func closeForTermination() async -> Bool {
        guard !busy else { return false }
        busy = true
        autosave?.cancel()
        await finishDictation()
        autosave?.cancel() // The final transcript may have scheduled another debounce.
        do { try await persist() }
        catch { busy = false; status = "保存失败，请重试后关闭：\(error.localizedDescription)"; return false }
        token = UUID(); tracking?.invalidate(); tracking = nil
        panels.close(); active = false; picking = false; paused = false; busy = false; target = nil
        return true
    }
}
