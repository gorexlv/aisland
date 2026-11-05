import Cocoa
import SwiftUI
import Combine

struct ReviewRegion: Identifiable, Codable {
    var id = UUID()
    let snapshotID: UUID
    let number: Int
    var rect: CGRect // normalized top-left coordinates
    var feedback = ""
    var transcript: [VoiceTranscriptEntry]? = nil
    var isText: Bool? = nil
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

struct ReviewTranscriptRecord: Identifiable, Codable {
    var id = UUID()
    let regionID: UUID
    var createdAt = Date()
    var text: String
}
enum ReviewInputMode { case text, audio }

@MainActor final class ReviewModel: ObservableObject {
    @Published var inputMode: ReviewInputMode = .audio
    @Published var active = false
    @Published var completed = false
    @Published var historyPresented = false
    @Published var reviewNoteName: String?
    @Published var shortcutHint: String?
    @Published var picking = false
    @Published var paused = false
    @Published var busy = false
    @Published var targets: [ScreenTarget] = []
    @Published var target: ScreenTarget?
    @Published var regions: [ReviewRegion] = []
    @Published var intentNote = ""
    @Published var aiSummary = ""
    @Published var aiSummaryInput = ""
    @Published var summaryBusy = false
    @Published var summaryError: String?
    private var summaryGeneration = UUID()
    private var summaryCancellation: SaveCancellation?
    var summarySourceJSON: String {
        let source = regions.compactMap { region -> ReviewSummarySource? in
            let text = region.feedback.trimmingCharacters(in:.whitespacesAndNewlines)
            return text.isEmpty ? nil : ReviewSummarySource(number:region.number,text:text)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(data:(try? encoder.encode(source)) ?? Data("[]".utf8),encoding:.utf8) ?? "[]"
    }
    var summaryOutdated: Bool { !aiSummary.isEmpty && aiSummaryInput != summarySourceJSON }
    private func clearAISummary() {
        summaryCancellation?.cancel(); summaryCancellation = nil; summaryGeneration = UUID()
        summaryBusy = false; aiSummary = ""; aiSummaryInput = ""; summaryError = nil
    }
    func summarizeReview(using analyze:@escaping @Sendable (String,SaveCancellation?) throws -> String = { try analyzeReviewText($0,cancellation:$1) }) {
        guard !summaryBusy, active else { return }
        let input = summarySourceJSON
        guard input != "[]" else { summaryError = "还没有可整理的转写内容"; return }
        let generation = summaryGeneration, cancellation = SaveCancellation()
        summaryCancellation = cancellation; summaryBusy = true; summaryError = nil
        Task {
            do {
                let result = try await Task.detached(priority:.utility) { try analyze(input,cancellation) }.value
                guard generation == summaryGeneration else { return }
                aiSummary = result; aiSummaryInput = input; summaryBusy = false; summaryCancellation = nil
                scheduleSave()
            } catch {
                guard generation == summaryGeneration else { return }
                summaryBusy = false; summaryCancellation = nil; summaryError = error.localizedDescription
            }
        }
    }
    func changeInputDevice(_ id:String?) {
        guard !busy, !live.active, !voice.voicePreparing, !voice.voiceFinishing else { return }
        let resumeRecording = voice.dictating
        busy = true
        Task {
            await finishDictation()
            do {
                try voice.setInputDevice(id)
                busy = false
                if resumeRecording && paused && inputMode == .audio { voice.toggleVoice() }
            } catch { busy = false; status = error.localizedDescription; voice.status = status; voice.lastError = status }
        }
    }
    @Published var transcriptFeed: [ReviewTranscriptRecord] = []
    @Published var selectedID: UUID? {
        didSet {
            if selectedID != oldValue { live.bindRegion(selectedID) }
            if let selectedID, selectedID != oldValue { recordTranscriptSelection(selectedID) }
        }
    }
    @Published var status = "选择窗口开始批阅"
    @Published var copied = false
    let voice = VoiceInput()
    let live = MoLiveSession()
    @Published var chatPanelShowsTranscript = false // Kept for older render fixtures.
    @Published var speakingEnabled = false
    @Published var listeningEnabled = true
    private var liveRegionPrefix: [UUID:String] = [:]
    private var liveRegionTimingPrefix: [UUID:[VoiceTranscriptEntry]] = [:]
    private var liveRegionMessages: [UUID:Set<UUID>] = [:]
    func resumeLocalListening(begin:(()->Void)? = nil) {
        guard active, paused, listeningEnabled, !busy, !historyPresented, !live.active,
              inputMode == .audio, !voice.voiceActive, voice.unavailableReason == nil,
              !voice.needsVoicePermission, voice.lastError == nil else { return }
        if let id = selectedID, let region = regions.first(where:{$0.id == id}) {
            voice.loadDraft(region.feedback,transcript:region.transcript ?? [])
        } else { voice.loadDraft("") }
        if let begin { begin() } else { voice.toggleVoice() }
    }
    func setSpeakingEnabled(_ enabled:Bool) {
        guard !busy, active, !picking, !historyPresented else { return }
        speakingEnabled = enabled
        if !paused { return }
        listeningEnabled = true; inputMode = .audio
        if !enabled { live.suppressReplies() }
        busy = true
        Task {
            await live.stop()
            await finishDictation()
            busy = false
            if enabled { startLiveChat() } else { voice.lastError = nil; voice.needsVoicePermission = false; resumeLocalListening() }
        }
    }
    func resumeListening() {
        listeningEnabled = true; voice.lastError = nil; voice.needsVoicePermission = false
        if speakingEnabled { startLiveChat() } else { resumeLocalListening() }
    }
    func stopListening() {
        listeningEnabled = false; speakingEnabled = false; live.suppressReplies()
        busy = true
        Task { await live.stop(); await finishDictation(); busy = false }
    }
    func startLiveChat() {
        guard !busy, !live.active, active, paused, !historyPresented else { return }
        guard voice.unavailableReason == nil else { liveNotice = voice.unavailableReason!; return }
        speakingEnabled = true; listeningEnabled = true; inputMode = .audio
        busy = true
        Task {
            await finishDictation()
            busy = false
            let context = "目标：\(target?.label ?? "未选择窗口")\n" + reviewPlainText(target:target?.label ?? "批阅",regions:regions,snapshots:snapshots)
            await live.start(context:context,deviceID:voice.selectedInputID)
        }
    }
    @Published var liveNotice = ""
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
    private var voiceStatusChanges: AnyCancellable?
    private var timedVoiceChanges: AnyCancellable?
    private var tracking: Timer?
    private var trackingBusy = false
    var onNotice: ((String)->Void)?
    var onRestoreRequest: (() -> Void)?
    init(storageRoot: URL? = nil) {
        self.storageRoot = storageRoot
        panels = ReviewPanels(model:self)
        live.onMessagesChanged = { [weak self] in self?.scheduleSave() }
        live.currentRegionID = { [weak self] in self?.selectedID }
        live.onSessionStarted = { [weak self] in
            self?.liveRegionPrefix = [:]; self?.liveRegionTimingPrefix = [:]; self?.liveRegionMessages = [:]
        }
        live.onUserTranscript = { [weak self] message in
            guard let self, let id = message.regionID, let index = self.regions.firstIndex(where:{$0.id == id}) else { return }
            if self.liveRegionPrefix[id] == nil { self.liveRegionPrefix[id] = self.regions[index].feedback; self.liveRegionTimingPrefix[id] = self.regions[index].transcript ?? [] }
            self.liveRegionMessages[id,default:[]].insert(message.id)
            let ids = self.liveRegionMessages[id] ?? []
            let contributions = self.live.messages.filter { ids.contains($0.id) }.sorted { $0.startMS < $1.startMS }
            let prefix = self.liveRegionPrefix[id] ?? ""
            let text = ([prefix] + contributions.map(\.text)).filter{!$0.isEmpty}.joined(separator:" ")
            self.regions[index].feedback = text
            self.regions[index].transcript = (self.liveRegionTimingPrefix[id] ?? []) + contributions.flatMap { ($0.fragments ?? []).map { VoiceTranscriptEntry(recordedAt:self.live.startedAt.addingTimeInterval(Double($0.startMS)/1000),text:$0.text) } }
            if let last = self.transcriptFeed.indices.last(where:{self.transcriptFeed[$0].regionID == id}) { self.transcriptFeed[last].text = text }
            self.copied = false; self.scheduleSave()
        }
        live.onEnded = { [weak self] in
            guard let self, self.speakingEnabled, !self.busy else { return }
            self.speakingEnabled = false; self.liveNotice = self.live.status; self.resumeLocalListening()
        }
        voiceStatusChanges = voice.$dictating.combineLatest(voice.$voicePreparing,voice.$voiceFinishing).combineLatest($busy).sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                (self?.panels.selectionOverlay?.contentView as? ReviewCanvas)?.updateInlineControls()
                self?.panels.selectionOverlay?.contentView?.needsDisplay = true
                if let self, !self.speakingEnabled { self.resumeLocalListening() }
            }
        }
        timedVoiceChanges = voice.$timedTranscript.sink { [weak self] entries in
            guard let self, let id = self.selectedID, let index = self.regions.firstIndex(where:{$0.id == id}) else { return }
            self.regions[index].transcript = entries.isEmpty ? nil : entries
            self.scheduleSave()
        }
        voiceChanges = voice.$draft.sink { [weak self] text in
            guard let self else { return }
            guard let id = self.selectedID, let index = self.regions.firstIndex(where:{$0.id == id}) else {
                guard !text.isEmpty, self.voice.voiceActive else { return }
                if let index = self.live.messages.firstIndex(where:{$0.id == self.voice.draftID}) { self.live.messages[index].text = text }
                else { self.live.messages.append(MoChatMessage(id:self.voice.draftID,role:"user",text:text,startMS:0,endMS:0,source:"dictation")) }
                self.scheduleSave(); return
            }
            self.regions[index].feedback = text
            if let last = self.transcriptFeed.indices.last, self.transcriptFeed[last].regionID == id { self.transcriptFeed[last].text = text }
            self.copied = false
            self.scheduleSave()
        }
    }
    func recordTranscriptSelection(_ id: UUID) {
        guard transcriptFeed.last?.regionID != id, let region = regions.first(where:{$0.id == id}) else { return }
        transcriptFeed.append(ReviewTranscriptRecord(regionID:id,text:region.feedback))
    }
    private func resetForStart() {
        inputMode = .audio; speakingEnabled = false; listeningEnabled = true
        active = true; picking = true; busy = true; copied = false; completed = false; reviewNoteName = nil
        clearAISummary(); live.messages = []; transcriptFeed = []; intentNote = ""
        regions = []; snapshots = []; current = nil; selectedID = nil; saveFolder = nil
        undoStates = []; canUndo = false
        token = UUID()
    }
    func attach(_ item: ScreenTarget, note: String) async -> Bool {
        guard !active, !busy else { status = "请先结束当前批阅"; return false }
        resetForStart(); busy = false; target = nil
        intentNote = note.trimmingCharacters(in:.whitespacesAndNewlines)
        await choose(item)
        if target?.id == item.id && !picking { return true }
        token = UUID(); active = false; picking = false; intentNote = ""
        return false
    }
    func restoreLatestStandalone() async {
        guard !active, !busy else { return }
        busy = true; defer { busy = false }
        do {
            guard let root = try? (storageRoot ?? ReviewStore.defaultRoot()), let folder = try await store.latest(root:root) else { status = "没有可恢复的批阅"; return }
            try await restore(folder:folder)
        } catch { status = "恢复失败：\(error.localizedDescription)。原文件未修改" }
    }
    func start(autoSelect: Bool = true) {
        if active { panels.showSidebar(); return }
        resetForStart()
        let session = token
        status = "正在扫描当前桌面…"; panels.showSidebar()
        Task {
            if let root = try? (storageRoot ?? ReviewStore.defaultRoot()) { recoveryFolder = try? await store.latest(root:root) }
            defer { if token == session && picking { busy = false } }
            do {
                let found = try await visibleScreenTargets()
                guard token == session else { return }
                targets = found
                if autoSelect && found.count == 1 { busy = false; await choose(found[0]) }
                else {
                    status = found.isEmpty ? "没有可选窗口，请打开应用后刷新" : "点击窗口高亮边框，或在列表中选择"
                    await panels.showHighlights(found)
                }
            } catch { status = "无法读取屏幕，请在系统设置中允许Mo · 墨录制屏幕后重试" }
        }
    }
    func refreshPicker() { openTargetPicker() }
    func openTargetPicker() {
        guard !busy else { return }
        if !active { panels.positionSidebar(.zero); start(autoSelect:false); panels.showTargetPicker(); return }
        Task {
            guard await prepareTargetPicker() else { return }
            busy = true; defer { busy = false }
            let session = token
            do {
                let found = try await visibleScreenTargets()
                guard token == session else { return }
                targets = found
                status = found.isEmpty ? "没有可选窗口，请打开应用后刷新" : "选择目标窗口，或退出批阅"
                await panels.showHighlights(found)
            } catch { status = "无法读取屏幕，请检查屏幕录制权限后刷新" }
        }
    }
    @discardableResult func prepareTargetPicker() async -> Bool {
        guard active, !busy else { return false }
        busy = true; defer { busy = false }
        await live.stop()
        await finishDictation(); autosave?.cancel()
        do { try await persist() }
        catch { status = "保存失败，暂未切换目标：\(error.localizedDescription)"; return false }
        token = UUID() // Invalidate any in-flight tracking result from the previous binding.
        tracking?.invalidate(); tracking = nil
        paused = false; picking = true
        panels.hideHistory(); panels.hideOverlay(); panels.detachTarget(); panels.clearHighlights()
        panels.showTargetPicker()
        return true
    }
    func choose(_ item: ScreenTarget) async {
        guard active, picking, !busy else { return }
        var enterReview = false
        busy = true; defer { busy = false; if enterReview { pause() } }
        let session = token
        do {
            let window = try await resolveScreenWindow(item)
            guard token == session, active else { return }
            if let previous = target, previous.id != item.id {
                try await persist()
                guard token == session, active else { return }
                selectedID = nil; voice.loadDraft("")
                clearAISummary(); live.messages = []; transcriptFeed = []
                regions = []; snapshots = []; current = nil; saveFolder = nil
                undoStates = []; canUndo = false; copied = false; completed = false; reviewNoteName = nil
            }
            target = item; picking = false; panels.clearHighlights()
            panels.positionSidebar(window.frame); panels.showSidebar()
            status = "正在进入批阅…"
            enterReview = true
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
            guard session == token, !picking, self.target == target else { return }
            let visible = (CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []).contains { ($0[kCGWindowNumber as String] as? UInt32) == target.id }
            if visible {
                panels.positionSidebar(window.frame)
                panels.showSidebar()
                if paused { panels.overlay?.orderFrontRegardless() }
            } else { panels.hideForWorkspace() }
        } catch {
            guard session == token, !picking, self.target == target else { return }
            await live.stop()
            await finishDictation()
            guard session == token, !picking, self.target == target else { return }
            panels.hideOverlay(); panels.detachTarget(); paused = false
            status = "目标窗口已关闭，已有批阅仍可完成并复制"
            tracking?.invalidate(); panels.showSidebar()
        }
    }
    var currentPageNumber: Int? {
        guard let current, let index = snapshots.firstIndex(where: { $0.id == current.id }) else { return nil }
        return index + 1
    }
    func toggleSinglePage() {
        guard !historyPresented else { return }
        if paused { resume() } else { pause() }
    }
    func pause() {
        guard active, !busy, !historyPresented, let target else { return }
        busy = true; copied = false; completed = false; panels.hideCompletionMenu(); let session = token
        status = "正在截取窗口…"
        Task {
            defer { if token == session { busy = false } }
            do {
                await finishDictation()
                guard token == session else { return }
                let window = try await resolveScreenWindow(target)
                let (data, _) = try await captureScreenWindow(target)
                guard token == session, let image = NSImage(data:data) else { return }
                let snapshot = ReviewSnapshot(id:UUID(),image:image,png:data,frame:window.frame)
                snapshots.append(snapshot); current = snapshot; paused = true
                selectedID = nil; voice.loadDraft("")
                panels.showOverlay(snapshot); panels.positionSidebar(window.frame)
                try await persist()
                busy = false
                if speakingEnabled { startLiveChat() } else { resumeLocalListening() }
                status = "在目标窗口内拖动框选，松开后自动录音；小预览中点击编号切换意见"
            } catch { status = "截图或保存失败：\(error.localizedDescription)，已截取画面仍保留，可重试保存"; onNotice?(status) }
        }
    }
    func setInputMode(_ mode: ReviewInputMode) async {
        guard active, !picking, !busy, !historyPresented, !live.active else { return }
        busy = true
        await finishDictation()
        inputMode = mode; busy = false
        panels.redraw()
        if mode == .audio, !live.active, paused, let selectedID,
           regions.contains(where:{$0.id == selectedID && $0.snapshotID == current?.id}) {
            voice.toggleVoice()
        }
    }
    @discardableResult func addTextRegion(_ selection: CGRect, canvasSize: CGSize) -> UUID? {
        guard inputMode == .text, paused, !busy, !historyPresented, !voice.voiceActive,
              let current, canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let width = min(max(120,selection.width*canvasSize.width),canvasSize.width), height = min(max(64,selection.height*canvasSize.height),canvasSize.height)
        let x = min(max(0,selection.minX*canvasSize.width),canvasSize.width-width), y = min(max(0,selection.minY*canvasSize.height),canvasSize.height-height)
        let rect = CGRect(x:x/canvasSize.width,y:y/canvasSize.height,width:width/canvasSize.width,height:height/canvasSize.height)
        rememberEdit()
        let item = ReviewRegion(snapshotID:current.id,number:(regions.map(\.number).max() ?? 0)+1,rect:rect,isText:true)
        regions.append(item); selectedID = item.id; voice.loadDraft("")
        scheduleSave(); panels.redraw()
        return item.id
    }
    func focusTextOpinion(_ id:UUID) {
        guard inputMode == .text, !busy, !voice.voiceActive,
              let item = regions.first(where:{$0.id == id && $0.isText == true}) else { return }
        selectedID = id; voice.loadDraft(item.feedback,transcript:item.transcript ?? [])
        panels.redraw()
    }
    func addRegion(_ rect: CGRect) {
        guard paused, !busy, !historyPresented, let current else { return }
        let item = ReviewRegion(snapshotID:current.id,number:(regions.map(\.number).max() ?? 0)+1,rect:rect)
        rememberEdit()
        regions.append(item); select(item.id, speak:inputMode == .audio)
        scheduleSave()
        panels.redraw()
    }
    func select(_ id: UUID, speak: Bool = false) {
        guard !busy, !historyPresented, let item = regions.first(where:{$0.id == id}) else { return }
        if voice.voiceActive, let current, item.snapshotID != current.id { return }
        let continueVoice = !live.active && inputMode == .audio && (speak || ((voice.dictating || voice.voicePreparing) && selectedID != id))
        if speak && selectedID == id && voice.dictating { voice.finishVoice(cancel:false); return }
        busy = true
        Task {
            // Local speech drains before selection changes; Live stays connected and uses its timeline.
            await finishDictation()
            selectedID = id
            voice.loadDraft(regions.first(where:{$0.id == id})?.feedback ?? "",transcript:regions.first(where:{$0.id == id})?.transcript ?? [])
            voice.status = "可输入文字，或点击麦克风录入"
            if paused, let shotID = regions.first(where:{$0.id == id})?.snapshotID,
               let shot = snapshots.first(where:{$0.id == shotID}), current?.id != shotID {
                current = shot; panels.showOverlay(shot)
            }
            busy = false; panels.redraw()
            if continueVoice { voice.toggleVoice() }
        }
    }
    var canSwitchSnapshots: Bool { !busy && !voice.voiceActive && !live.active && !historyPresented }
    func openHistory() {
        if historyPresented { panels.showHistory(); return }
        guard canSwitchSnapshots, !snapshots.isEmpty else { return }
        historyPresented = true; paused = false
        panels.hideOverlay(); panels.refreshChrome()
        status = "点击大图中的框选查看意见；原应用已恢复操作，修改自动保存"
        panels.showHistory()
    }
    func updateOpinion(_ id:UUID,text:String) {
        guard !busy, !voice.voiceActive, let index = regions.firstIndex(where:{$0.id == id}) else { return }
        regions[index].feedback = text; copied = false; reviewNoteName = nil
        if selectedID == id { voice.draft = text }
        status = "意见已修改，正在自动保存…"
        scheduleSave()
    }
    func dismissHistory() async {
        guard historyPresented, !busy else { return }
        busy = true; defer { busy = false }
        autosave?.cancel()
        do {
            try await persist()
            historyPresented = false; panels.hideHistory()
            status = "历史批阅修改已保存"
        } catch { status = "保存失败：\(error.localizedDescription)，修改仍保留，请重试" }
    }
    func selectSnapshot(_ id: UUID) {
        guard canSwitchSnapshots, let shot = snapshots.first(where:{$0.id == id}) else { return }
        completed = false; panels.hideCompletionMenu()
        current = shot; paused = true
        selectedID = regions.first(where:{$0.snapshotID == id})?.id
        voice.loadDraft(regions.first(where:{$0.id == selectedID})?.feedback ?? "",transcript:regions.first(where:{$0.id == selectedID})?.transcript ?? [])
        panels.showOverlay(shot)
        status = "已切换到截图 \(currentPageNumber ?? 1)"
    }
    func toggleOpinionVoice() {
        guard !live.active, inputMode == .audio, paused, !busy, !historyPresented, selectedID != nil else { return }
        voice.toggleVoice()
    }
    func completeReview() { Task { _ = await prepareCompletion() } }
    @discardableResult func prepareCompletion() async -> Bool {
        guard !busy, !snapshots.isEmpty else { return false }
        if historyPresented { panels.showHistory(); return true }
        busy = true; defer { busy = false }
        await live.stop()
        await finishDictation(); autosave?.cancel()
        do {
            try await persist()
            paused = false; completed = true; historyPresented = true
            panels.hideCompletionMenu(); panels.hideOverlay(); panels.refreshChrome()
            status = "已保存"
            panels.showHistory()
            return true
        } catch { status = "保存失败：\(error.localizedDescription)，批阅仍保留"; return false }
    }
    func writeReviewToNotes() {
        guard !busy, !snapshots.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            await live.stop()
        await finishDictation(); autosave?.cancel()
            do {
                try await persist()
                guard let saveFolder else { return }
                let packet = try await store.prepareReviewFiles(folder:saveFolder)
                let title = "截图批阅 · " + (target?.label ?? Date().formatted(date:.numeric,time:.shortened))
                let text = packet.comments
                let paths = packet.images.map(\.path)
                let receipt = try await Task.detached { try insertIntoNotesInBackground(title:title,text:text,existingID:nil,attachmentPaths:paths) }.value
                reviewNoteName = receipt.name; status = "已写入 Apple Notes："+receipt.name
                onNotice?(status)
            } catch { status = "写入 Notes 失败：\(error.localizedDescription)，本地批阅仍保留" }
        }
    }
    func sendToCodex() {
        guard !busy, !snapshots.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            await live.stop()
        await finishDictation(); autosave?.cancel()
            do {
                try await persist()
                guard let saveFolder else { return }
                let packet = try await store.prepareReviewFiles(folder:saveFolder)
                let command = try createReviewCodexCommand(packet)
                guard NSWorkspace.shared.open(command) else { throw NotesFailure(detail:"无法打开 Codex 会话终端") }
                status = "已打开 Codex 新会话终端，截图已作为附件传入，评论保存在 comments.txt"
            } catch { status = "发送到 Codex 失败：\(error.localizedDescription)，本地批阅仍保留" }
        }
    }
    func updateRegionRect(_ id:UUID,rect:CGRect) {
        guard paused, !busy, !historyPresented, let current,
              let index = regions.firstIndex(where:{$0.id == id && $0.snapshotID == current.id}),
              rect.minX >= 0, rect.minY >= 0, rect.maxX <= 1.000001, rect.maxY <= 1.000001,
              rect.width > 0, rect.height > 0, regions[index].rect != rect else { return }
        rememberEdit()
        regions[index].rect = rect; copied = false; reviewNoteName = nil
        scheduleSave(); panels.redraw()
    }
    func closeRegion(_ id: UUID) async { await deleteRegion(id) }
    func deleteSelectedRegion() async {
        guard let id = selectedID else { return }
        await deleteRegion(id)
    }
    /// Finish accepted speech before deleting a region or capturing its undo state.
    private func deleteRegion(_ id: UUID) async {
        guard !busy, !historyPresented, regions.contains(where: { $0.id == id }) else { return }
        busy = true; defer { busy = false }
        await finishDictation()
        rememberEdit()
        regions.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil; voice.loadDraft("") }
        await saveEdit("已删除标记及其意见，可撤销")
    }
    func deleteSnapshot(_ id: UUID) async {
        guard !busy, !historyPresented, snapshots.contains(where: { $0.id == id }) else { return }
        busy = true; defer { busy = false }
        await finishDictation()
        rememberEdit()
        let count = regions.filter { $0.snapshotID == id }.count
        regions.removeAll { $0.snapshotID == id }; snapshots.removeAll { $0.id == id }
        if !regions.contains(where: { $0.id == selectedID }) { selectedID = nil; voice.loadDraft("") }
        if current?.id == id { current = snapshots.last }
        await saveEdit("已删除截图及 \(count) 条意见，可撤销")
    }
    func undoEdit() async {
        guard !busy, !historyPresented, !undoStates.isEmpty else { return }
        busy = true; defer { busy = false }
        await finishDictation()
        let state = undoStates.removeLast()
        // Preserve edits to surviving regions; undo only changes structural membership.
        let live = Dictionary(uniqueKeysWithValues:regions.map { ($0.id, $0) })
        snapshots = state.snapshots
        regions = state.regions.map { item in
            var item = item; if let current = live[item.id] { item.feedback = current.feedback; item.transcript = current.transcript }; return item
        }
        selectedID = state.selectedID
        current = snapshots.first { $0.id == state.currentID } ?? snapshots.last
        voice.loadDraft(regions.first { $0.id == selectedID }?.feedback ?? "",transcript:regions.first { $0.id == selectedID }?.transcript ?? [])
        canUndo = !undoStates.isEmpty
        await saveEdit("已撤销；恢复的截图和意见已保留")
    }
    private func saveEdit(_ notice: String) async {
        copied = false; autosave?.cancel()
        if paused { if let current { panels.showOverlay(current) } else { panels.hideOverlay(); paused = false } }
        if !paused { await live.stop() }
        panels.redraw(); panels.refreshChrome()
        do { try await persist(); status = notice }
        catch { status = "保存失败：\(error.localizedDescription)，修改仍保留，可重试保存" }
    }
    func stopVoice() { voice.finishVoice(cancel:true) }
    private func finishDictation() async { await voice.finishAndWait() }
    private func scheduleSave() {
        autosave?.cancel()
        guard active, !snapshots.isEmpty else { return }
        let session = token
        autosave = Task {
            do { try await Task.sleep(nanoseconds:400_000_000); try Task.checkCancellation(); guard active, token == session else { return }; try await persist(); if historyPresented { status = "意见已自动保存" } }
            catch is CancellationError { }
            catch { status = "自动保存失败：\(error.localizedDescription)，请重试保存后关闭" }
        }
    }
    func resume() {
        guard paused, !busy, !historyPresented else { return }
        busy = true
        status = "正在保存标记并返回实时窗口…"
        let session = token
        Task {
            await live.stop()
            await finishDictation()
            guard token == session else { return }
            defer { busy = false }
            do { try await persist(); panels.hideOverlay(); paused = false; panels.refreshChrome(); status = "已保存批阅，已返回实时窗口；可再次截取画面并标注" }
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
                try copyReview(target:reviewExportTitle(target?.label ?? "窗口批阅",note:intentNote),regions:regions,snapshots:snapshots)
                copied = true
                status = "已复制"
                onNotice?("已复制")
            } catch { status = "保存或复制失败：\(error.localizedDescription)，内容仍在当前会话中，请重试" }
        }
    }
    func sendToClaude() { Task { await sendToClaude(using:openClaudeReview) } }
    func sendToClaude(using open: @MainActor (URL) async throws -> Void) async {
        guard !busy, !historyPresented, !snapshots.isEmpty else { return }
        busy = true; defer { busy = false }
        autosave?.cancel()
        status = "正在保存截图与评论，准备 Claude 对话…"
        await finishDictation()
        autosave?.cancel()
        do {
            try await persist()
            guard let folder = saveFolder else { throw NotesFailure(detail:"批阅尚未保存") }
            let packet = try await store.prepareClaudePacket(folder:folder)
            try await open(packet.link)
            token = UUID(); tracking?.invalidate(); tracking = nil
            panels.close(); active = false; picking = false; paused = false; target = nil
            status = "已在 Claude Desktop 准备截图与评论，请在 Claude 中点击发送"
            onNotice?(status)
        } catch {
            status = "发送给 Claude 未完成：\(error.localizedDescription)。批阅仍保留，可重试"
        }
    }
    func persist() async throws {
        guard !snapshots.isEmpty || saveFolder != nil else { return }
        if saveFolder == nil {
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            saveFolder = try (storageRoot ?? ReviewStore.defaultRoot()).appendingPathComponent(formatter.string(from:Date()) + "-" + UUID().uuidString)
        }
        let session = StoredReviewSession(transcriptRecords:transcriptFeed.isEmpty ? nil : transcriptFeed,chatMessages:live.messages.isEmpty ? nil : live.messages,aiSummary:aiSummary.isEmpty ? nil : aiSummary,aiSummaryInput:aiSummaryInput.isEmpty ? nil : aiSummaryInput,target:target,shots:snapshots.map { StoredReviewShot(id:$0.id,frame:$0.frame,capturedAt:$0.capturedAt) },regions:regions,selectedID:selectedID,intentNote:intentNote.isEmpty ? nil : intentNote)
        let payload = ReviewSavePayload(session:session,originals:Dictionary(uniqueKeysWithValues:snapshots.map { ($0.id,$0.png) }),text:reviewPlainText(target:reviewExportTitle(target?.label ?? "窗口批阅",note:intentNote),regions:regions,snapshots:snapshots))
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
        guard !historyPresented else { throw NotesFailure(detail:"请先保存并关闭历史批阅编辑") }
        let payload = try await store.load(folder:folder)
        let restored = try payload.session.shots.map { shot -> ReviewSnapshot in
            guard let data = payload.originals[shot.id], let image = NSImage(data:data) else { throw NotesFailure(detail:"批阅原图无法恢复") }
            return ReviewSnapshot(id:shot.id,image:image,png:data,frame:shot.frame,capturedAt:shot.capturedAt)
        }
        await live.stop()
        await finishDictation()
        undoStates = []; canUndo = false
        token = UUID(); tracking?.invalidate(); tracking = nil
        snapshots = restored; regions = payload.session.regions; target = payload.session.target
        clearAISummary()
        live.messages = payload.session.chatMessages ?? []
        aiSummary = payload.session.aiSummary ?? ""; aiSummaryInput = payload.session.aiSummaryInput ?? ""
        transcriptFeed = payload.session.transcriptRecords ?? regions.map { ReviewTranscriptRecord(regionID:$0.id,text:$0.feedback) }
        selectedID = payload.session.selectedID; saveFolder = folder; intentNote = payload.session.intentNote ?? ""
        let selectedShot = regions.first(where:{$0.id == selectedID})?.snapshotID
        current = restored.first(where:{$0.id == selectedShot}) ?? restored.last
        active = true; picking = false; paused = !restored.isEmpty; completed = false
        if presentPanels { panels.clearHighlights() }
        voice.loadDraft(regions.first(where:{$0.id == selectedID})?.feedback ?? "",transcript:regions.first(where:{$0.id == selectedID})?.transcript ?? [])
        if presentPanels, let current { panels.showOverlay(current); panels.positionSidebar(current.frame) }
        status = "已恢复批阅，可继续编辑意见并完成复制；原窗口可能已关闭"
    }
    func reveal() { if let saveFolder { NSWorkspace.shared.activateFileViewerSelecting([saveFolder]) } }
    func close() { Task { _ = await closeForTermination() } }
    func closeForTermination() async -> Bool {
        guard !busy else { return false }
        summaryCancellation?.cancel(); summaryCancellation = nil; summaryGeneration = UUID(); summaryBusy = false
        busy = true
        autosave?.cancel()
        await live.stop()
        await finishDictation()
        autosave?.cancel() // The final transcript may have scheduled another debounce.
        do { try await persist() }
        catch { busy = false; status = "保存失败，请重试后关闭：\(error.localizedDescription)"; return false }
        autosave?.cancel()
        token = UUID(); tracking?.invalidate(); tracking = nil
        panels.close(); active = false; picking = false; paused = false; busy = false; target = nil
        return true
    }
}
