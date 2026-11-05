import Cocoa
import Combine

struct WindowOCRRecord: Identifiable { let id: UUID; let file: URL; var text: String; let date: Date }

@MainActor final class WindowOCRPanels {
    weak var session: WindowOCRSession?
    func position(_ frame: CGRect) {}
    func hideForWorkspace() {}
    func close() {}
}

@MainActor final class WindowOCRSession: ObservableObject {
    let reader: ScreenReader
    let live = MoLiveSession()
    let voice: VoiceInput
    var panels = WindowOCRPanels()
    @Published var active = false
    @Published var target: ScreenTarget?
    @Published var note = ""
    @Published var records: [WindowOCRRecord] = []
    @Published var speakingEnabled = false
    @Published var status = ""
    var startLive: ((String) async -> Void)?
    private var tracking: Timer?
    private var trackingBusy = false
    private var token = UUID()
    private var statusLink: AnyCancellable?
    init(voice: VoiceInput, storageRoot: URL? = nil) {
        self.voice = voice; reader = ScreenReader(storageRoot:storageRoot)
        panels.session = self
        reader.onSaved = { [weak self] file, text in self?.saved(file,text) }
        statusLink = reader.$status.dropFirst().sink { [weak self] in self?.status = $0 }
    }
    var latestText: String { reader.text }
    func attach(_ item: ScreenTarget, note: String) async -> Bool {
        do { _ = try await resolveScreenWindow(item) } catch { status = error.localizedDescription; return false }
        token = UUID()
        target = item; self.note = note; reader.note = note; active = true
        records = []; speakingEnabled = false
        tracking?.invalidate()
        tracking = Timer.scheduledTimer(withTimeInterval:0.8,repeats:true) { [weak self] _ in
            Task { @MainActor in await self?.track() }
        }
        reframe()
        return true
    }
    func reframe() { if let target { reader.select(target) } }
    private func saved(_ file: URL, _ text: String) {
        records.append(WindowOCRRecord(id:UUID(),file:file,text:text,date:Date()))
        guard speakingEnabled, let target else { return }
        let session = token
        Task { await live.stop(); guard session == token, speakingEnabled else { return }; await begin(target,text) }
    }
    private func begin(_ target: ScreenTarget, _ text: String) async {
        let context = "OCR 识别文字（\(target.label)）：\n" + text
        if let startLive { await startLive(context) } else { await live.start(context:context,deviceID:voice.selectedInputID) }
    }
    func setSpeakingEnabled(_ on: Bool) {
        if on {
            guard let target, !latestText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { status = "请先框选识别文字"; return }
            speakingEnabled = true
            let text = latestText
            Task { await begin(target,text) }
        } else { speakingEnabled = false; Task { await live.stop() } }
    }
    private func track() async {
        guard active, !trackingBusy, let target else { return }
        trackingBusy = true; defer { trackingBusy = false }
        let session = token
        do {
            let window = try await resolveScreenWindow(target)
            guard session == token, self.target == target else { return }
            let visible = (CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []).contains { ($0[kCGWindowNumber as String] as? UInt32) == target.id }
            if visible { panels.position(window.frame) } else { panels.hideForWorkspace() }
        } catch {
            guard session == token, self.target == target else { return }
            speakingEnabled = false
            await live.stop()
            guard session == token else { return }
            reader.cancel(); tracking?.invalidate(); tracking = nil
            status = "目标窗口已关闭，已有读屏记录仍可查看"
        }
    }
    func end() async -> Bool {
        if reader.dirty { reader.save() }
        if reader.dirty { return false }
        token = UUID(); tracking?.invalidate(); tracking = nil
        speakingEnabled = false
        await live.stop()
        reader.reset(); panels.close()
        active = false; target = nil; note = ""; records = []; status = ""
        return true
    }
    func preserveForTermination() -> Bool { reader.preserveForTermination() }
}
