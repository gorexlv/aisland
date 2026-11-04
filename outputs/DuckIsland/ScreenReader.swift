import Cocoa
import SwiftUI
import Vision

struct ScreenReadResult {
    let text: String
    let image: Data
}
func recognizeScreenRegion(png: Data, region: CGRect) throws -> ScreenReadResult {
    guard region.width > 0, region.height > 0, region.minX >= 0, region.minY >= 0,
          region.maxX <= 1.000001, region.maxY <= 1.000001,
          let rep = NSBitmapImageRep(data:png), let original = rep.cgImage else { throw NotesFailure(detail:"框选范围无效，请重新框选") }
    let rect = CGRect(x:region.minX*CGFloat(original.width),y:region.minY*CGFloat(original.height),width:region.width*CGFloat(original.width),height:region.height*CGFloat(original.height)).integral
    guard let cropped = original.cropping(to:rect), let data = NSBitmapImageRep(cgImage:cropped).representation(using:.png,properties:[:]) else { throw NotesFailure(detail:"无法读取框选图片") }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans","en-US"]
    request.usesLanguageCorrection = true
    try VNImageRequestHandler(cgImage:cropped,options:[:]).perform([request])
    let text = (request.results ?? []).compactMap{$0.topCandidates(1).first?.string}.joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines)
    return ScreenReadResult(text:text,image:data)
}
func saveScreenRead(_ result:ScreenReadResult, source:ScreenTarget, region:CGRect, root:URL? = nil) throws -> URL {
    guard !result.text.isEmpty else { throw NotesFailure(detail:"框选区域没有识别到文字，请重新框选") }
    let directory = try root ?? ( FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)).appendingPathComponent("DuckIsland/ScreenReads")
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let folder = directory.appendingPathComponent(date.string(from:Date())+"-"+UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    do {
        try result.image.write(to:folder.appendingPathComponent("region.png"),options:.atomic)
        let metadata = ["应用":source.app,"窗口":source.title,"框选范围":"\(region)"]
        try JSONEncoder().encode(metadata).write(to:folder.appendingPathComponent("source.json"),options:.atomic)
        let textFile = folder.appendingPathComponent("文字.txt")
        try result.text.write(to:textFile,atomically:true,encoding:.utf8)
        return textFile
    } catch { try? FileManager.default.removeItem(at:folder); throw error }
}

@MainActor final class ScreenReader:ObservableObject {
    @Published var visible = false
    @Published var targets:[ScreenTarget] = []
    @Published var selected:ScreenTarget?
    @Published var busy = false
    @Published var text = ""
    @Published var status = "选择窗口，再框选需要读取的区域"
    @Published var savedFile:URL?
    @Published var permissionError = false
    @Published var selecting = false
    @Published var preview:NSImage?
    private var overlay:NSPanel?
    private var token = UUID()
    private var pending: (ScreenReadResult, ScreenTarget, CGRect)?
    var onNotice:((String)->Void)?
    func open() { visible = true; refresh() }
    func cancel() { token = UUID(); busy = false; selecting = false; overlay?.close(); overlay = nil }
    func hide() { cancel(); visible = false }
    func refresh() {
        cancel(); selected = nil; targets = []; busy = true; permissionError = false
        let session = token
        status = "正在识别当前桌面的窗口…"
        Task {
            defer { if token == session { busy = false } }
            do {
                let windows = try await visibleScreenTargets()
                guard session == token else { return }
                targets = windows; status = windows.isEmpty ? "没有可选窗口，请打开应用后刷新" : "选择要框选的窗口"
                if windows.count == 1 { select(windows[0]) }
            } catch { guard session == token else { return }; permissionError = true; status = "请允许小鸭录制屏幕后刷新" }
        }
    }
    func select(_ target:ScreenTarget) { selected = target; capture() }
    func capture() {
        guard let target = selected else { return }
        cancel(); busy = true; text = ""; savedFile = nil; preview = nil; pending = nil
        let session = token
        status = "正在准备框选画面…"
        Task {
            defer { if session == token { busy = false } }
            do {
                let window = try await resolveScreenWindow(target)
                let (data, _) = try await captureScreenWindow(target,purpose:.ocr)
                guard session == token, let image = NSImage(data:data) else { return }
                let frame = reviewScreenRect(window.frame,desktopTop:NSScreen.screens.first?.frame.maxY ?? 0)
                let panel = IslandPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
                panel.isOpaque = true; panel.backgroundColor = .black; panel.hasShadow = false; panel.hidesOnDeactivate = false
                panel.isReleasedWhenClosed = false; panel.level = .floating
                panel.collectionBehavior = [.fullScreenAuxiliary,.stationary,.ignoresCycle]
                let canvas = ScreenReadCanvas(frame:NSRect(origin:.zero,size:frame.size)); canvas.image = image
                canvas.selected = { [weak self] rect in self?.extract(data:data,region:rect,target:target) }
                canvas.cancelled = { [weak self] in self?.cancel(); self?.status = "已取消框选，可重新框选" }
                panel.contentView = canvas; overlay = panel; panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(canvas)
                selecting = true; status = "在目标窗口上拖动框选 · Esc 取消"
            } catch { guard session == token else { return }; status = error.localizedDescription }
        }
    }
    private func extract(data:Data, region:CGRect, target:ScreenTarget) {
        overlay?.close(); overlay = nil; selecting = false; busy = true
        let session = token; status = "正在识别框选区域…"
        Task {
            defer { if session == token { busy = false } }
            do {
                let result = try await Task.detached(priority:.userInitiated) { try recognizeScreenRegion(png:data,region:region) }.value
                guard session == token else { return }
                guard !result.text.isEmpty else { status = "没有识别到文字，请重新框选"; return }
                text = result.text; preview = NSImage(data:result.image); pending = (result,target,region)
                save()
            } catch { guard session == token else { return }; status = "识别失败：\(error.localizedDescription)" }
        }
    }
    func save() {
        guard let (result,target,region) = pending else { return }
        do {
            savedFile = try saveScreenRead(result,source:target,region:region)
            pending = nil
            status = "已保存：" + (savedFile?.deletingLastPathComponent().lastPathComponent ?? "")
            onNotice?("读屏文字已保存")
        } catch { status = "保存失败：\(error.localizedDescription)，文字仍保留，可重试保存" }
    }
    var canRetrySave:Bool { pending != nil && savedFile == nil }
    func copy() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string); status = savedFile == nil ? "文字已复制，请重试保存" : "文字已复制 · 本地文件已保留" }
    func reveal() { if let savedFile { NSWorkspace.shared.activateFileViewerSelecting([savedFile]) } }
}

final class ScreenReadCanvas:NSView {
    var image:NSImage?
    var selected:((CGRect)->Void)?
    var cancelled:(()->Void)?
    private var start:CGPoint?
    private var end:CGPoint?
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.crosshair) }
    override func keyDown(with event:NSEvent) { if event.keyCode == 53 { cancelled?() } else { super.keyDown(with:event) } }
    override func draw(_ dirtyRect:NSRect) {
        image?.draw(in:bounds,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
        NSColor.black.withAlphaComponent(0.2).setFill(); bounds.fill()
        if let start, let end, let normalized = reviewSelection(start,end,size:bounds.size) {
            let r = CGRect(x:normalized.minX*bounds.width,y:normalized.minY*bounds.height,width:normalized.width*bounds.width,height:normalized.height*bounds.height)
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect:r).addClip()
            image?.draw(in:bounds,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.systemYellow.setStroke(); let border = NSBezierPath(rect:r); border.lineWidth = 3; border.stroke()
        }
        let badge = NSRect(x:12,y:12,width:min(320,bounds.width-24),height:30)
        NSColor.black.withAlphaComponent(0.85).setFill(); NSBezierPath(roundedRect:badge,xRadius:7,yRadius:7).fill()
        ("拖动框选需要读取的文字 · Esc 取消" as NSString).draw(in:badge.insetBy(dx:9,dy:7),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.white])
    }
    override func mouseDown(with event:NSEvent) { start = convert(event.locationInWindow,from:nil); end = start }
    override func mouseDragged(with event:NSEvent) { end = convert(event.locationInWindow,from:nil); needsDisplay = true }
    override func mouseUp(with event:NSEvent) {
        if let start, let region = reviewSelection(start,convert(event.locationInWindow,from:nil),size:bounds.size) { selected?(region) }
        start = nil; end = nil; needsDisplay = true
    }
}

struct ScreenReaderView:View {
    @ObservedObject var reader:ScreenReader
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text("🐨 " + (reader.selected?.label ?? "选择读屏窗口")).font(.system(size:12,weight:.medium)).lineLimit(1)
                Spacer(minLength:0)
                Button { reader.hide() } label:{Image(systemName:"chevron.up")}.help("收起读屏")
            }
            if reader.selected == nil {
                ScrollView {
                    VStack(spacing:5) {
                        ForEach(reader.targets) { target in
                            Button { reader.select(target) } label: {
                                HStack { Text(target.label).font(.system(size:12)).lineLimit(2); Spacer(); Image(systemName:"chevron.right") }
                                    .padding(8).background(.white.opacity(0.06),in:RoundedRectangle(cornerRadius:8))
                            }
                        }
                    }
                }.frame(height:166)
                HStack {
                    Button("刷新窗口") { reader.refresh() }.disabled(reader.busy)
                    if reader.permissionError { Button("屏幕权限") { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) } }
                }.font(.system(size:11))
            } else {
                ScrollView {
                    Text(reader.text.isEmpty ? "框选需要读取的区域，识别完成后自动保存文字。" : reader.text)
                        .font(.system(size:13)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).foregroundStyle(reader.text.isEmpty ? .gray : .white)
                }.frame(height:166)
                HStack {
                    Button("重新框选") { reader.capture() }.disabled(reader.busy)
                    Button("切换窗口") { reader.refresh() }.disabled(reader.busy)
                    Spacer()
                    if reader.canRetrySave { Button("重试保存") { reader.save() } }
                    Button("复制") { reader.copy() }.disabled(reader.text.isEmpty)
                    Button("查看文件") { reader.reveal() }.disabled(reader.savedFile == nil)
                }.font(.system(size:11))
            }
            HStack {
                if reader.busy { ProgressView().controlSize(.mini) }
                Text(reader.status).font(.system(size:10)).foregroundStyle(.gray).lineLimit(2)
                if reader.selecting { Button("取消") { reader.cancel(); reader.status = "已取消框选" }.font(.system(size:10)) }
            }
        }.padding(16).buttonStyle(.plain).foregroundStyle(.yellow)
    }
}
