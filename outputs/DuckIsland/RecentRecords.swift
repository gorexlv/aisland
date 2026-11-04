import Cocoa
import SwiftUI

struct RecordSections: Equatable {
    var original: String
    var summary: String = ""
    var todos: String = ""
    init(_ body: String) {
        original = body
        let marker = "会议转写原文\n系统声音与麦克风分别标注，非发言人识别。\n\n"
        if let range = body.range(of: marker) {
            original = String(body[range.upperBound...])
            let prefix = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let start = prefix.range(of: "会议总结\n") { summary = String(prefix[start.lowerBound...]) }
            if let start = summary.range(of: "\n\n可执行 Tickets\n") {
                let rest = String(summary[start.upperBound...])
                todos = rest.components(separatedBy: "\n待确认事项\n").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
        }
    }
}
struct RecentRecord: Identifiable {
    var id: String { url.path }
    let url: URL
    let date: Date
    let kind: String
    let title: String
    let text: String
    let issue: String?
}
enum RecentRecords {
    static func root() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("DuckIsland")
    }
    static func load(root: URL) throws -> [RecentRecord] {
        var records: [RecentRecord] = []
        for (directory, kind, filename) in [("Meetings", "会议", ""), ("ScreenReads", "OCR", "文字.txt"), ("Reviews", "批阅", "review.txt")] {
            let folder = root.appendingPathComponent(directory)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            for entry in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where !entry.lastPathComponent.hasPrefix(".") {
                if filename.isEmpty && (entry.pathExtension != "txt" || entry.lastPathComponent.hasSuffix(".diagnostics.txt")) { continue }
                let url = filename.isEmpty ? entry : entry.appendingPathComponent(filename)
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let text = try? String(contentsOf: url, encoding: .utf8)
                var issue = text == nil ? "文字缺失、损坏或旧格式；可打开原始目录检查" : (text!.isEmpty ? "本地文字为空；请检查原始记录" : nil)
                if issue == nil, kind == "会议", text?.contains("会议转写原文\n") == false { issue = "旧格式：本地文字可读取，按全文展示" }
                if issue == nil, kind == "批阅", !FileManager.default.fileExists(atPath: entry.appendingPathComponent("session.json").path) { issue = "旧格式：本地文字可读取，编辑恢复信息不可用" }
                records.append(RecentRecord(url: url, date: date, kind: kind, title: text?.components(separatedBy: "\n").first.flatMap { $0.isEmpty ? nil : $0 } ?? entry.lastPathComponent, text: text ?? "", issue: issue))
            }
        }
        return records.sorted { $0.date > $1.date }
    }
}

@MainActor final class RecordWindows: ObservableObject {
    static let shared = RecordWindows()
    @Published var records: [RecentRecord] = []
    @Published var loadError = ""
    @Published var jobs: [UUID: String] = [:]
    var running: Set<UUID> = []
    var retries: [UUID: () -> Void] = [:]
    var summaryRetries: [UUID: () -> Void] = [:]
    var jobResults: [UUID: () -> Void] = [:]
    private var window: NSWindow?
    private var results: [NSWindow] = []
    func refresh() {
        Task {
            do {
                let root = try RecentRecords.root()
                records = try await Task.detached { try RecentRecords.load(root: root) }.value
                loadError = ""
            } catch { loadError = "无法读取本地记录：" + error.localizedDescription }
        }
    }
    func show() {
        refresh()
        if window == nil {
            window = makeWindow("最近记录与任务", view: RecentRecordsView(model: self))
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func result(title: String, text: String) {
        let window = makeWindow(title, view: RecordResultView(sections: RecordSections(text)))
        results.removeAll { !$0.isVisible }; results.append(window)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func makeWindow<V: View>(_ title: String, view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view); window.center()
        return window
    }
}
private struct RecentRecordsView: View {
    @ObservedObject var model: RecordWindows
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text("最近记录").font(.title2); Spacer(); Button("刷新") { model.refresh() } }
            Text("仅显示此 Mac 的本地文字。历史备忘录同步状态未知；批阅历史仅供查看，继续编辑请使用批阅中的恢复入口。")
                .font(.caption).foregroundStyle(.secondary)
            if !model.loadError.isEmpty { Text(model.loadError).foregroundStyle(.red) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.jobs.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                        VStack(alignment: .leading) {
                            Text(model.jobs[id] ?? "").textSelection(.enabled)
                            HStack {
                                if let result = model.jobResults[id] { Button("查看结果 / 复制") { result() } }
                                if let retry = model.retries[id] { Button("重试保存 / 同步") { retry() } }
                                #if !APP_STORE
                                if let retry = model.summaryRetries[id] { Button("重试 AI 总结") { retry() } }
                                #endif
                            }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.08))
                    }
                    if model.records.isEmpty { Text("暂无本地记录。完成会议、读屏或批阅保存后，可在这里找回。") }
                    ForEach(model.records) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(record.kind) · \(record.title)").font(.headline).lineLimit(2)
                            Text(record.date, style: .date).font(.caption)
                            Text(record.issue ?? "本地文字可读取 · 备忘录同步状态未知").font(.caption).foregroundStyle(record.issue == nil ? Color.secondary : .orange)
                            Text(record.text).lineLimit(2).foregroundStyle(.secondary)
                            HStack {
                                Button("查看文字") { model.result(title: record.title, text: record.text) }.disabled(record.text.isEmpty)
                                Button("打开本地位置") { NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: record.url.path) ? record.url : record.url.deletingLastPathComponent()]) }
                            }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(Color.gray.opacity(0.08))
                    }
                }
            }
        }.padding(20).frame(minWidth: 580, minHeight: 400)
    }
}
private struct RecordResultView: View {
    let sections: RecordSections
    @State private var selected = 0
    @State private var feedback = ""
    private var text: String { selected == 0 ? sections.original : selected == 1 ? sections.summary : sections.todos }
    private var label: String { ["原文", "总结", "待办"][selected] }
    var body: some View {
        VStack(alignment: .leading) {
            Picker("查看内容", selection: $selected) { Text("原文").tag(0); Text("总结").tag(1); Text("待办").tag(2) }.pickerStyle(.segmented)
            ScrollView { Text(text.isEmpty ? "暂无\(label)。未生成或旧记录未包含此内容。" : text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
            HStack {
                Button("复制" + label) {
                    NSPasteboard.general.clearContents()
                    feedback = NSPasteboard.general.setString(text, forType: .string) ? "已复制" + label : "复制失败，请重试"
                }.disabled(text.isEmpty)
                Text(feedback).font(.caption)
            }
        }.padding(20).frame(minWidth: 520, minHeight: 360).onChange(of: selected) { feedback = "" }
    }
}
