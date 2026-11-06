import Cocoa
import Combine
import SwiftUI
import WebKit
import Speech
import AVFoundation

// MARK: - Settings

enum GameSettings {
    static let urlKey = "gameCompanionURL"
    static let replyKey = "gameCompanionVoiceReply"
    static let presets: [(name: String, url: String)] = [
        ("正式版", "https://little-king.vercel.app"),
        ("测试版", "https://little-king-git-war-mode-sheji.vercel.app"),
        ("本地", "http://127.0.0.1:8940/little-king/"),
    ]
    static var defaultURL: String { presets[0].url }
    static func validURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
    static var url: URL { validURL(UserDefaults.standard.string(forKey: urlKey) ?? "") ?? URL(string: defaultURL)! }
    static var voiceReply: Bool { UserDefaults.standard.object(forKey: replyKey) as? Bool ?? true }
}

// MARK: - Command model

struct GameBat: Equatable {
    let id: Int
    let name: String
    let typeId: String
    let shooter: Bool
    let mounted: Bool
    let alive: Bool
}

enum GameCommand: String, Equatable {
    case hold, advance, charge, skirmish, retreat, auto, follow
    var label: String {
        switch self {
        case .hold: return "坚守"
        case .advance: return "前进"
        case .charge: return "冲锋"
        case .skirmish: return "风筝"
        case .retreat: return "撤退"
        case .auto: return "自由行动"
        case .follow: return "跟我来"
        }
    }
}
/// `.near` is an explicit "身边"/"跟我来"; `.defaultNear` is "no object given" and is only executed in king view.
enum GameTarget: Equatable { case near, defaultNear, selected, units([Int]) }
enum GameAction: Equatable { case command(GameCommand), pause, resume }
struct GameIntent: Equatable {
    var action: GameAction
    var target: GameTarget
    var subject: String
    /// Short phrase for the spoken reply, e.g. "骑兵冲锋".
    var spoken: String {
        switch action {
        case .pause: return "暂停"
        case .resume: return "继续"
        case .command(let command):
            if command == .follow { return "跟我来" }
            return (subject.isEmpty ? (target == .near || target == .defaultNear ? "身边" : "") : subject) + command.label
        }
    }
    /// JSON-safe arguments for `__MoBridge.run`.
    var runArguments: [String: Any]? {
        guard case .command(let command) = action else { return nil }
        let targets: Any
        switch target {
        case .near, .defaultNear: targets = "near"
        case .selected: targets = "selected"
        case .units(let ids): targets = ids
        }
        return ["targets": targets, "cmd": command.rawValue]
    }
}

// MARK: - Parser (pure)

private func gameChineseNumber(_ text: String) -> Int? {
    let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
    guard !text.isEmpty else { return nil }
    if let ten = text.firstIndex(of: "十") {
        let head = String(text[..<ten]), tail = String(text[text.index(after: ten)...])
        guard head.count <= 1, tail.count <= 1 else { return nil }
        let tens = head.isEmpty ? 1 : digits[head.first!]
        let ones = tail.isEmpty ? 0 : digits[tail.first!]
        guard let tens, let ones else { return nil }
        return tens * 10 + ones
    }
    guard text.count == 1 else { return nil }
    return digits[text.first!]
}

/// Lowercases, drops spaces/punctuation and turns "一营" into "1营" so names compare exactly.
func gameNormalize(_ text: String) -> String {
    var result = text.filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
    guard let regex = try? NSRegularExpression(pattern: "([零一二两三四五六七八九十]+)营") else { return result }
    let source = result as NSString
    var output = ""
    var cursor = 0
    for match in regex.matches(in: result, range: NSRange(location: 0, length: source.length)) {
        output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
        let number = source.substring(with: match.range(at: 1))
        output += gameChineseNumber(number).map { "\($0)营" } ?? source.substring(with: match.range)
        cursor = match.range.location + match.range.length
    }
    output += source.substring(from: cursor)
    result = output
    return result
}

/// Drops leading "小墨" (and same-sounding) tokens, matched by toneless pinyin.
func gameStripWake(_ text: String) -> String {
    var rest = Substring(text)
    var stripped = true
    while stripped {
        stripped = false
        for n in 2...min(4, max(2, rest.count)) where n <= rest.count {
            if moPinyin(String(rest.prefix(n))) == "xiaomo" { rest = rest.dropFirst(n); stripped = true; break }
        }
    }
    return String(rest)
}

private let gameSubjectTypes: [(word: String, types: [String], label: String)] = {
    let all = ["heavyShield", "swordShield", "pike", "archer", "crossbow", "heavyCav", "horseArcher"]
    let list: [(String, [String], String)] = [
        ("所有人", all, "全军"), ("全军", all, "全军"), ("所有", all, "全军"), ("全体", all, "全军"), ("大家", all, "全军"),
        ("骑射", ["horseArcher"], "骑射"), ("重骑", ["heavyCav"], "重骑兵"), ("骑兵", ["heavyCav", "horseArcher"], "骑兵"),
        ("剑盾", ["swordShield"], "剑盾兵"), ("步兵", ["heavyShield", "swordShield", "pike"], "步兵"),
        ("重盾兵", ["heavyShield"], "重盾兵"), ("重盾", ["heavyShield"], "重盾兵"), ("盾兵", ["swordShield", "heavyShield"], "盾兵"), ("长枪", ["pike"], "长枪兵"), ("枪兵", ["pike"], "长枪兵"),
        ("弓箭手", ["archer", "crossbow"], "弓兵"), ("弓兵", ["archer", "crossbow"], "弓兵"), ("射手", ["archer", "crossbow"], "弓兵"),
        ("弩兵", ["crossbow"], "弩兵"), ("弩", ["crossbow"], "弩兵"), ("盾", ["swordShield", "heavyShield"], "盾兵"), ("弓", ["archer", "crossbow"], "弓兵"),
    ]
    // Longest word first so "弓箭手" is consumed before "弓"; equal lengths keep listed order.
    return list.enumerated().sorted { ($0.element.0.count, -$0.offset) > ($1.element.0.count, -$1.offset) }.map { (word: $0.element.0, types: $0.element.1, label: $0.element.2) }
}()

private let gameCommandWords: [(GameAction, [String])] = [
    (.command(.follow), ["跟我来", "跟着我", "跟上"]),
    (.command(.retreat), ["撤退", "后撤", "退回", "撤"]),
    (.command(.skirmish), ["放风筝", "风筝", "游击"]),
    (.command(.auto), ["交给副将", "自由", "自动", "副将"]),
    (.command(.hold), ["坚守", "守住", "顶住", "停下", "原地"]),
    (.command(.charge), ["冲锋", "进攻", "冲", "杀"]),
    (.command(.advance), ["前进", "推进", "压上", "上前"]),
    (.pause, ["暂停"]),
    (.resume, ["继续"]),
]

/// Hot words for speech recognition: command vocabulary plus the current battalion names.
func gameContextualStrings(bats: [GameBat]) -> [String] {
    var words = ["小墨小墨", "全军", "骑兵", "重骑兵", "骑射", "步兵", "剑盾兵", "长枪兵", "弓箭手", "弩兵", "身边"]
    words += gameCommandWords.flatMap { $0.1 }
    words += bats.filter(\.alive).map(\.name)
    var seen = Set<String>()
    return words.filter { seen.insert($0).inserted }
}

private struct GameCommandMatch { let action: GameAction; var word: String; let start: Int; var end: Int }

private let gameCommandWordList: [(word: String, action: GameAction)] = {
    let flat = gameCommandWords.flatMap { entry in entry.1.map { (word: $0, action: entry.0) } }
    return flat.enumerated().sorted { ($0.element.word.count, -$0.offset) > ($1.element.word.count, -$1.offset) }.map(\.element)
}()

private func gameScanCommands(_ chars: [Character]) -> [GameCommandMatch] {
    var matches: [GameCommandMatch] = []
    var index = 0
    while index < chars.count {
        var hit: GameCommandMatch?
        for entry in gameCommandWordList {
            let word = Array(entry.word)
            if index + word.count <= chars.count, Array(chars[index..<index + word.count]) == word { hit = GameCommandMatch(action: entry.action, word: entry.word, start: index, end: index + word.count); break }
        }
        guard let hit else { index += 1; continue }
        // "冲杀" is one charge, not two.
        if var last = matches.last, last.end == hit.start, last.action == hit.action { last.word += hit.word; last.end = hit.end; matches[matches.count - 1] = last }
        else { matches.append(hit) }
        index = hit.end
    }
    return matches
}

/// Parses one utterance into the commands it contains, in order ("骑兵冲锋弓兵坚守" gives two).
func gameParseCommands(_ text: String, bats: [GameBat], selected: Int? = nil) -> [GameIntent] {
    let normalized = gameNormalize(text)
    let stripped = gameStripWake(normalized)
    let woke = stripped.count != normalized.count
    let chars = Array(stripped)
    var matches = gameScanCommands(chars)
    if matches.contains(where: { if case .command = $0.action { return true } else { return false } }) {
        // "继续前进" is an advance, not a resume; a pause/resume AFTER a command ("全军撤退暂停") is its own command.
        let firstCommand = matches.firstIndex { if case .command = $0.action { return true } else { return false } }!
        matches = matches.enumerated().filter { $0.offset > firstCommand || ($0.element.action != .pause && $0.element.action != .resume) }.map(\.element)
    }
    guard !matches.isEmpty else { return [] }
    var clauses: [(String, GameCommandMatch)] = []
    if matches.count == 1 { clauses = [(stripped, matches[0])] }
    else {
        var previous = 0
        for match in matches { clauses.append((String(chars[previous..<match.end]), match)); previous = match.end }
    }
    return clauses.compactMap { gameParseClause($0.0, match: $0.1, bats: bats, selected: selected, woke: woke) }
}

func gameParseCommand(_ text: String, bats: [GameBat], selected: Int? = nil) -> GameIntent? {
    gameParseCommands(text, bats: bats, selected: selected).first
}

private func gameParseClause(_ clause: String, match: GameCommandMatch, bats: [GameBat], selected: Int?, woke: Bool) -> GameIntent? {
    var rest = clause
    let alive = bats.filter(\.alive)
    var ids: [Int] = []
    var subjects: [String] = []
    var hasSubject = false
    // Exact battalion names first (longest first, consumed so "重骑兵" does not also match inside "重骑兵2营").
    for bat in alive.sorted(by: { $0.name.count > $1.name.count }) {
        let name = gameNormalize(bat.name)
        guard !name.isEmpty, rest.contains(name) else { continue }
        rest = rest.replacingOccurrences(of: name, with: "")
        if !ids.contains(bat.id) { ids.append(bat.id) }
        subjects.append(bat.name); hasSubject = true
    }
    // A numbered battalion that is not on the field (already gone) must not fall back to its whole troop type.
    if let regex = try? NSRegularExpression(pattern: "(重盾兵|剑盾兵|长枪兵|弓兵|弩兵|骑射营|骑射|重骑兵|重骑|骑兵|步兵)?[0-9]+营") {
        let source = rest as NSString
        for found in regex.matches(in: rest, range: NSRange(location: 0, length: source.length)).reversed() {
            subjects.append(source.substring(with: found.range)); hasSubject = true
            rest = (rest as NSString).replacingCharacters(in: found.range, with: "")
        }
    }
    var near = false
    for word in ["身边", "附近"] where rest.contains(word) { rest = rest.replacingOccurrences(of: word, with: ""); near = true }
    for entry in gameSubjectTypes where rest.contains(entry.word) {
        rest = rest.replacingOccurrences(of: entry.word, with: "")
        for bat in alive where entry.types.contains(bat.typeId) && !ids.contains(bat.id) { ids.append(bat.id) }
        if !subjects.contains(entry.label) { subjects.append(entry.label) }
        hasSubject = true
    }
    // A lone "冲"/"杀"/"撤" is too easy to hear by accident: require an object or the wake word.
    if match.word.count == 1, !hasSubject, !near, !woke { return nil }
    let subject = subjects.joined(separator: "、")
    switch match.action {
    case .pause, .resume: return GameIntent(action: match.action, target: .near, subject: "")
    case .command(.follow): return GameIntent(action: match.action, target: .near, subject: "")
    case .command(let command):
        if near { return GameIntent(action: match.action, target: .near, subject: "") }
        if hasSubject { return GameIntent(action: match.action, target: .units(ids), subject: subject) }
        if selected != nil { return GameIntent(action: match.action, target: .selected, subject: "") }
        if command == .charge || command == .hold || command == .auto { return GameIntent(action: match.action, target: .defaultNear, subject: "") }
        return GameIntent(action: match.action, target: .units(alive.map(\.id)), subject: "全军")
    }
}

// MARK: - Bridge

enum GameBridge {
    /// Injected at documentEnd into the main frame. Everything is wrapped so a game-side exception becomes {ok:false}.
    static let script = """
    (function(){
      if (window.__MoBridge) return;
      function out(x){ return JSON.stringify(x); }
      function dbg(){ try { var lk = window.__LK; return (lk && lk.War && lk.War.debug) || null; } catch (e) { return null; } }
      function battle(d){ try { var b = (typeof d.battle === 'function') ? d.battle() : d.battle; return (b && b.bats) ? b : null; } catch (e) { return null; } }
      function pauseButton(){ return document.getElementById('wPause'); }
      function isPaused(){ var b = pauseButton(); return !!b && String(b.textContent || '').trim() === '继续'; }
      function selectedId(d){ try { var s = d.selected; if (typeof s === 'function') s = s.call(d); return (typeof s === 'number' && s >= 0) ? s : -1; } catch (e) { return -1; } }
      function alive(b){ return !!b && b.side === 0 && b.state !== 'gone' && b.state !== 'rout'; }
      function describe(b){ var t = b.type || {}; return {id: b.id, name: String(b.name || ''), typeId: String(b.typeId || ''), shooter: !!t.missile && !t.mounted, mounted: !!t.mounted, alive: true}; }
      function find(bt, id){ for (var i = 0; i < bt.bats.length; i++) { if (bt.bats[i] && bt.bats[i].id === id) return bt.bats[i]; } return null; }
      // King view (the only view where quick() works) <=> the king's command bar #wKbar is shown (war.js sets wKbar.hidden = !kingView on every phase/view change).
      function inKingView(){ var k = document.getElementById('wKbar'); return !!k && !k.hidden; }
      function kingDead(d){ try { return !!(d.king && d.king.dead); } catch (e) { return false; } }
      // quick() always toasts in #wToast: "身边 N 个营：…" on success, "国王身边 X 米内没有我方的营" / "国王倒下了…" on failure.
      function toastText(){ var t = document.getElementById('wToast'); return (t && !t.hidden) ? String(t.textContent || '').trim() : ''; }
      function clearToast(){ var t = document.getElementById('wToast'); if (t) { t.textContent = ''; t.hidden = true; } }
      function state(){
        try {
          var d = dbg(), bt = d && battle(d);
          if (!bt) return out({ok: true, inBattle: false, kingView: false, kingDead: false, paused: isPaused(), selected: null, bats: []});
          var bats = [], sel = selectedId(d);
          for (var i = 0; i < bt.bats.length; i++) { if (alive(bt.bats[i])) bats.push(describe(bt.bats[i])); }
          return out({ok: true, inBattle: !bt.result, kingView: inKingView(), kingDead: kingDead(d), paused: isPaused(), selected: sel >= 0 ? sel : null, bats: bats});
        } catch (e) { return out({ok: false, message: String(e && e.message || e)}); }
      }
      function degrade(b, cmd){
        var t = b.type || {}, shooter = !!t.missile && !t.mounted;
        if (cmd === 'skirmish' && b.typeId !== 'horseArcher') cmd = 'advance';
        if (shooter && (cmd === 'charge' || cmd === 'advance')) cmd = 'auto';
        return cmd;
      }
      function fail(message, skipped){ return out({ok: false, done: [], skipped: skipped || [], message: message}); }
      function run(a){
        var d, bt, original = -1, wasPaused = false, touched = false, restoreNeeded = false;
        try {
          d = dbg(); bt = d && battle(d);
          if (!bt || bt.result) return fail('还没开战');
          var cmd = String(a && a.cmd || ''), targets = a && a.targets, done = [], skipped = [];
          var known = {hold: 1, advance: 1, charge: 1, skirmish: 1, retreat: 1, auto: 1, follow: 1};
          if (!known[cmd]) return fail('不认识的命令');
          if (targets === 'near') {
            var quick = {follow: 1, charge: 1, hold: 1, auto: 1};
            if (!quick[cmd]) return fail('身边的营不支持这个命令', [{name: '身边的营', reason: '身边的营只支持跟随、冲锋、坚守、自由行动'}]);
            if (!inKingView()) return fail('地图视角下身边命令无效，请说兵种、营名或全军', [{name: '身边的营', reason: '不在国王视角'}]);
            clearToast();
            d.quick(cmd);
            var toast = toastText();
            if (/没有我方的营|国王倒下了/.test(toast)) return fail(toast, [{name: '身边的营', reason: toast}]);
            return out({ok: true, done: [{name: '身边的营', cmd: cmd}], skipped: [], message: /^身边 \\d+ 个营/.test(toast) ? toast : '已发出'});
          }
          if (cmd === 'follow') return fail('跟随只对身边的营', [{name: '全部', reason: '跟随只对身边的营'}]);
          original = selectedId(d); wasPaused = isPaused(); restoreNeeded = true;
          var ids = [];
          if (targets === 'selected') { if (original >= 0) ids = [original]; }
          else if (Object.prototype.toString.call(targets) === '[object Array]') ids = targets;
          if (!ids.length) return fail(targets === 'selected' ? '没有选中的营' : '没有对应的营');
          for (var i = 0; i < ids.length; i++) {
            var b = find(bt, ids[i]);
            if (!alive(b)) { skipped.push({name: String(ids[i]), reason: '已经不在场'}); continue; }
            var k = degrade(b, cmd);
            touched = true; d.select(b.id); d.command(k);
            var item = {name: String(b.name || ''), cmd: k};
            if (k !== cmd) item.from = cmd;
            done.push(item);
          }
          return out({ok: done.length > 0, done: done, skipped: skipped, message: done.length ? '已发出' : '没有可执行的营'});
        } catch (e) { return fail(String(e && e.message || e)); }
        finally {
          // select() auto-pauses the game; always put selection and pause state back, even after an exception.
          if (restoreNeeded) {
            if (touched) { try { d.select(original >= 0 ? original : -1); } catch (e) {} }
            try { if (!wasPaused && isPaused()) { var pb = pauseButton(); if (pb) pb.click(); } } catch (e) {}
          }
        }
      }
      function pause(want){
        try {
          var b = pauseButton();
          if (!b || b.hidden) return out({ok: false, message: '还没开战'});
          if (isPaused() !== !!want) b.click();
          return out({ok: true, paused: isPaused(), message: want ? '已暂停' : '已继续'});
        } catch (e) { return out({ok: false, message: String(e && e.message || e)}); }
      }
      window.__MoBridge = {state: state, run: run, pause: pause};
    })();
    """

    static func makeUserScript() -> WKUserScript {
        WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    /// Builds the JS call; the argument is JSON produced by JSONSerialization, never user text spliced into code.
    static func expression(method: String, argument: Any?) -> String? {
        guard let argument else { return "window.__MoBridge ? window.__MoBridge.\(method)() : null" }
        guard let data = try? JSONSerialization.data(withJSONObject: [argument]), var json = String(data: data, encoding: .utf8) else { return nil }
        json = json.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "window.__MoBridge ? window.__MoBridge.\(method)(\(json)[0]) : null"
    }

    @MainActor static func call(_ web: WKWebView, _ method: String, _ argument: Any? = nil) async -> [String: Any] {
        guard let source = expression(method: method, argument: argument) else { return ["ok": false, "message": "参数无法编码"] }
        return await withCheckedContinuation { continuation in
            web.evaluateJavaScript(source) { value, error in
                if let error { continuation.resume(returning: ["ok": false, "message": error.localizedDescription]); return }
                guard let text = value as? String, let data = text.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    continuation.resume(returning: ["ok": false, "message": "游戏页面还没准备好"]); return
                }
                continuation.resume(returning: object)
            }
        }
    }

    static func parseBats(_ object: [String: Any]) -> [GameBat] {
        (object["bats"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let id = raw["id"] as? Int else { return nil }
            return GameBat(id: id, name: raw["name"] as? String ?? "", typeId: raw["typeId"] as? String ?? "", shooter: raw["shooter"] as? Bool ?? false, mounted: raw["mounted"] as? Bool ?? false, alive: raw["alive"] as? Bool ?? true)
        }
    }
}

struct GameRunResult: Equatable {
    var ok: Bool
    var done: [(name: String, cmd: String, from: String?)]
    var skipped: [(name: String, reason: String)]
    var message: String
    init(_ object: [String: Any]) {
        ok = object["ok"] as? Bool ?? false
        message = object["message"] as? String ?? ""
        done = (object["done"] as? [[String: Any]] ?? []).map { ($0["name"] as? String ?? "", $0["cmd"] as? String ?? "", $0["from"] as? String) }
        skipped = (object["skipped"] as? [[String: Any]] ?? []).map { ($0["name"] as? String ?? "", $0["reason"] as? String ?? "") }
    }
    static func == (a: GameRunResult, b: GameRunResult) -> Bool {
        a.ok == b.ok && a.message == b.message && a.done.map { "\($0.name)|\($0.cmd)|\($0.from ?? "")" } == b.done.map { "\($0.name)|\($0.cmd)|\($0.from ?? "")" } && a.skipped.map { "\($0.name)|\($0.reason)" } == b.skipped.map { "\($0.name)|\($0.reason)" }
    }
    /// What to say aloud: the actual outcome (degraded commands, refusals), not the raw request.
    func spoken(for intent: GameIntent) -> String {
        guard ok, !done.isEmpty else {
            if let first = skipped.first, done.isEmpty, message == "没有可执行的营" { return first.reason }
            return message.isEmpty ? "没有执行" : message
        }
        let degraded = done.contains { $0.from != nil }
        var parts: [String]
        if !degraded { parts = [intent.spoken] }
        else {
            parts = done.prefix(3).map { item -> String in "\(item.name)\(GameCommand(rawValue: item.cmd)?.label ?? item.cmd)" }
            if done.count > 3 { parts.append("等\(done.count)个营") }
        }
        if !skipped.isEmpty { parts.append("\(skipped.count)个营不在场") }
        return parts.joined(separator: "，")
    }
    var summary: String {
        var parts = done.map { item -> String in
            let label = GameCommand(rawValue: item.cmd)?.label ?? item.cmd
            if let from = item.from, let origin = GameCommand(rawValue: from) { return "\(item.name) \(label)（\(origin.label)改）" }
            return "\(item.name) \(label)"
        }
        parts += skipped.map { "跳过 \($0.name)：\($0.reason)" }
        if !done.isEmpty, message != "已发出", message != "已下令", !message.isEmpty { parts.append(message) }
        return parts.isEmpty ? message : parts.joined(separator: "；")
    }
}

// MARK: - Sentence splitter (pure)

/// Turns a growing partial transcript into sentences: a sentence ends after `idle` seconds without new text.
/// Text is compared normalized (no punctuation/spaces, Chinese battalion numbers as digits), so the recognizer
/// re-punctuating or rewriting already delivered words never re-submits them.
struct GameSentenceSplitter {
    var idle: TimeInterval = 0.8
    private var consumed = ""
    private var latest = ""
    private var changedAt: Date?
    private func pending(_ full: String) -> String {
        guard !consumed.isEmpty else { return full }
        if full.hasPrefix(consumed) { return String(full.dropFirst(consumed.count)) }
        if let range = full.range(of: consumed, options: .backwards) { return String(full[range.upperBound...]) }
        // The recognizer rewrote text we already delivered: if most of it still matches, treat that region as consumed.
        let common = zip(full, consumed).prefix { $0 == $1 }.count
        if common * 2 >= consumed.count { return String(full.dropFirst(min(full.count, consumed.count))) }
        return full   // a genuinely new utterance
    }
    mutating func feed(_ full: String, now: Date) {
        let text = gameNormalize(full)
        if text != latest { latest = text; changedAt = now }
    }
    mutating func poll(now: Date) -> String? {
        guard let changedAt, now.timeIntervalSince(changedAt) >= idle else { return nil }
        let text = pending(latest)
        self.changedAt = nil
        guard !text.isEmpty else { return nil }
        consumed = latest
        return text
    }
    mutating func finish() -> String? {
        let text = pending(latest)
        reset()
        return text.isEmpty ? nil : text
    }
    mutating func reset() { consumed = ""; latest = ""; changedAt = nil }
}

// MARK: - Recognizer (opens the microphone; never constructed by tests)

@MainActor final class GameRecognizer {
    var contextualStrings: [String] = []
    var deviceID: String?
    var onSentence: (String) -> Void = { _ in }
    var onLevel: (CGFloat) -> Void = { _ in }
    var onFailure: (String) -> Void = { _ in }
    private(set) var running = false
    private var token = UUID()
    private var capture: VoiceMicrophoneCapture?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var splitter = GameSentenceSplitter()
    private var ticker: Timer?
    private var startedAt = Date()
    private var failures: [Date] = []
    private var paused = false

    /// Set when the on-device model is unavailable and Apple's servers are used instead.
    private(set) var online = false
    /// Bumped by stop(); every await in start() re-checks it so a stop during permission prompts / mic start wins.
    private var generation = UUID()
    struct Cancelled: Error {}

    func start() async throws {
        guard !running else { return }
        let mine = UUID(); generation = mine
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard generation == mine else { throw Cancelled() }
        let speech: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard generation == mine else { throw Cancelled() }
        guard mic, speech == .authorized else { throw NotesFailure(detail: "请允许麦克风和语音识别权限后重试") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable else { throw NotesFailure(detail: "中文语音识别暂不可用") }
        self.recognizer = recognizer; online = !recognizer.supportsOnDeviceRecognition
        running = true; paused = false; failures = []
        do { try await begin() } catch {
            // Only the owning generation may tear down; a newer start() owns the shared state now.
            if generation == mine { running = false; teardown() }
            throw error
        }
        guard generation == mine else { throw Cancelled() }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    func stop() {
        generation = UUID()
        running = false; paused = false; online = false
        ticker?.invalidate(); ticker = nil
        teardown()
        splitter.reset()
    }
    /// Stops hearing (used while the companion speaks) without ending the listening session.
    func pause() { guard running, !paused else { return }; paused = true; teardown(); splitter.reset() }
    func resume() async {
        guard running, paused else { return }
        paused = false
        do { try await begin() } catch { onFailure(error.localizedDescription) }
    }
    private func teardown() {
        token = UUID()
        capture?.stop(); capture = nil
        task?.cancel(); task = nil
    }
    private func begin() async throws {
        guard let recognizer else { return }
        let current = UUID(); token = current
        splitter.reset(); startedAt = Date()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.contextualStrings = Array(contextualStrings.prefix(100))
        let newTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true, failed = error != nil
            Task { @MainActor [weak self] in self?.receive(current, text, final: final, failed: failed) }
        }
        task = newTask
        let capture = VoiceMicrophoneCapture(); self.capture = capture
        do {
            _ = try await capture.start(request: request, deviceID: deviceID, level: { [weak self] level in
                Task { @MainActor [weak self] in self?.onLevel(level) }
            }, failure: { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, self.token == current else { return }
                    self.stop(); self.onFailure("录音失败：" + message)
                }
            })
        } catch {
            // Clean up only what this call created; shared state may already belong to a newer start.
            capture.stop(); newTask.cancel()
            throw error
        }
        if token != current { capture.stop(); newTask.cancel() }   // stopped or superseded while the microphone was starting
    }
    private func receive(_ current: UUID, _ text: String?, final: Bool, failed: Bool) {
        guard running, !paused, token == current else { return }
        if let text, !text.isEmpty { splitter.feed(text, now: Date()) }
        guard final || failed else { return }
        if let sentence = splitter.finish() { onSentence(sentence) }
        if failed {
            let now = Date()
            failures = failures.filter { now.timeIntervalSince($0) < 10 } + [now]
            if failures.count >= 4 { stop(); onFailure("语音识别反复中断，请重新开启"); return }
        }
        Task { await restart() }
    }
    private func tick() {
        guard running, !paused else { return }
        guard let sentence = splitter.poll(now: Date()) else { return }
        onSentence(sentence)
        if Date().timeIntervalSince(startedAt) > 45 { Task { await restart() } }
    }
    private func restart() async {
        guard running, !paused else { return }
        teardown()
        do { try await begin() } catch { stop(); onFailure(error.localizedDescription) }
    }
}

// MARK: - Session

struct GameRecord: Identifiable, Equatable {
    enum Kind { case done, skipped, unknown }
    let id = UUID()
    let time: Date
    let said: String
    let result: String
    let kind: Kind
}

@MainActor final class GamePanels: OrbitPanels {
    weak var session: GameSession? { didSet { configure() } }
    override init() { super.init(); configure() }
    private func configure() {
        toolbarTitle = "陪玩呼吸灯"; recordTitle = "陪玩指令记录"
        isActive = { [weak self] in self?.session?.active == true }
        makeOrbit = { [weak self] _ in
            guard let session = self?.session else { return AnyView(EmptyView()) }
            return AnyView(GameOrbitView(session: session))
        }
        makeRecord = { [weak self] in
            guard let session = self?.session else { return AnyView(EmptyView()) }
            return AnyView(GameRecordView(session: session))
        }
    }
}

@MainActor final class GameSession: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    var panels = GamePanels()
    @Published var active = false
    @Published var listening = false
    @Published var preparing = false
    @Published var executing = false
    @Published var speaking = false
    @Published var inBattle = false
    @Published var bats: [GameBat] = []
    @Published var selected: Int?
    @Published var kingView = false
    @Published var records: [GameRecord] = []
    @Published var status = ""
    @Published var recordsShown = true
    @Published var lastError: String?
    @Published var online = false
    var inputLevel: CGFloat = 0
    weak var webView: WKWebView?
    /// Returns why the microphone cannot be used right now (meeting, GPT-Live, ...), nil when free.
    var microphoneBlockReason: () -> String? = { nil }
    var replyEnabled: () -> Bool = { GameSettings.voiceReply }
    var onClose: (() -> Void)?
    let recognizer = GameRecognizer()
    private let synthesizer = AVSpeechSynthesizer()
    private var poller: Timer?
    private var polling = false
    private var prepareGeneration = UUID()

    override init() {
        super.init()
        panels.session = self
        synthesizer.delegate = self
        recognizer.onSentence = { [weak self] text in guard let self else { return }; Task { await self.process(text) } }
        recognizer.onLevel = { [weak self] level in self?.inputLevel = level }
        recognizer.onFailure = { [weak self] message in self?.listeningFailed(message) }
    }

    var statusLine: String {
        if !status.isEmpty { return status }
        if listening { return (inBattle ? "在听" : "在听 · 还没开战") + (online ? " · 使用 Apple 在线识别" : "") }
        return inBattle ? "麦克风已关" : "还没开战"
    }

    func attach(webView: WKWebView) {
        self.webView = webView
        active = true; records = []; status = ""; lastError = nil; recordsShown = true
        panels.setRecordVisible(true)
        poller?.invalidate()
        poller = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refreshState() } }
    }
    func end() {
        stopListening(status: "")
        synthesizer.stopSpeaking(at: .immediate)
        poller?.invalidate(); poller = nil
        panels.close()
        active = false; webView = nil; inBattle = false; bats = []; selected = nil; speaking = false; executing = false; status = ""
    }

    func refreshState() async {
        guard active, !polling, let webView else { return }
        polling = true; defer { polling = false }
        let object = await GameBridge.call(webView, "state")
        guard object["ok"] as? Bool == true else { inBattle = false; bats = []; return }
        inBattle = object["inBattle"] as? Bool ?? false
        bats = GameBridge.parseBats(object)
        selected = object["selected"] as? Int
        kingView = object["kingView"] as? Bool ?? false
        recognizer.contextualStrings = gameContextualStrings(bats: bats)
    }

    // MARK: Listening

    func toggleListening() { setListening(!(listening || preparing)) }
    func setListening(_ on: Bool) {
        guard on else { stopListening(status: ""); return }
        guard active, !listening, !preparing else { return }
        if let reason = microphoneBlockReason() { status = reason; return }
        preparing = true; status = "正在打开麦克风…"
        let mine = UUID(); prepareGeneration = mine
        Task {
            defer { if prepareGeneration == mine { preparing = false } }
            do {
                recognizer.contextualStrings = gameContextualStrings(bats: bats)
                try await recognizer.start()
                guard prepareGeneration == mine else { return }
                guard active else { recognizer.stop(); return }
                listening = true; online = recognizer.online; status = ""; lastError = nil
            } catch is GameRecognizer.Cancelled { // stopped while starting: nothing to report
            } catch {
                guard prepareGeneration == mine else { return }
                listening = false; status = error.localizedDescription; lastError = error.localizedDescription
            }
        }
    }
    func stopListening(status text: String) {
        prepareGeneration = UUID()
        recognizer.stop()
        listening = false; preparing = false; online = false; inputLevel = 0; status = text
    }
    private func listeningFailed(_ message: String) {
        listening = false; inputLevel = 0; status = message; lastError = message
    }

    // MARK: Commands

    func add(said: String, result: String, kind: GameRecord.Kind) {
        records.append(GameRecord(time: Date(), said: said, result: result, kind: kind))
        if records.count > 200 { records.removeFirst(records.count - 200) }
    }

    func process(_ text: String) async {
        guard active, let webView else { return }
        await refreshState()
        let intents = gameParseCommands(text, bats: bats, selected: selected)
        guard !intents.isEmpty else { add(said: text, result: "没听懂：" + text, kind: .unknown); return }
        guard inBattle else {
            add(said: text, result: "还没开战，没有发出", kind: .skipped)
            speak("还没开战"); return
        }
        executing = true; defer { executing = false }
        var replies: [String] = []
        for (index, original) in intents.enumerated() {
            var intent = original
            let said = index == 0 ? text : "（同一句）" + intent.spoken
            if intent.target == .defaultNear {
                guard kingView else {
                    let message = "地图视角请说兵种、营名或全军"
                    add(said: said, result: message, kind: .skipped); replies.append("请说兵种或营名"); continue
                }
                intent.target = .near
            }
            let result: GameRunResult
            switch intent.action {
            case .pause: result = GameRunResult(await GameBridge.call(webView, "pause", true))
            case .resume: result = GameRunResult(await GameBridge.call(webView, "pause", false))
            case .command: result = GameRunResult(await GameBridge.call(webView, "run", intent.runArguments))
            }
            let succeeded: Bool
            if case .command = intent.action { succeeded = result.ok && !result.done.isEmpty } else { succeeded = result.ok }
            if succeeded { lastError = nil }
            add(said: said, result: result.summary, kind: succeeded ? .done : .skipped)
            replies.append(result.spoken(for: intent))
        }
        speak(replies.joined(separator: "，"))
    }

    // MARK: Spoken reply

    func speak(_ text: String) {
        guard replyEnabled(), !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speaking = true
        recognizer.pause()
        synthesizer.speak(utterance)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { Task { @MainActor in self.finishedSpeaking() } }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { Task { @MainActor in self.finishedSpeaking() } }
    private func finishedSpeaking() {
        guard !synthesizer.isSpeaking else { return }
        speaking = false
        Task { try? await Task.sleep(nanoseconds: 300_000_000); await recognizer.resume() }
    }

    func setRecordsShown(_ shown: Bool) { recordsShown = shown; panels.setRecordVisible(shown) }

    var activityState: MoActivityState {
        var items: [MoActivity] = []
        if active {
            if speaking { items.append(MoActivity(id: "game-speaking", kind: .speaking, title: "正在回应", target: .reader)) }
            if executing { items.append(MoActivity(id: "game-executing", kind: .executing, title: "执行指令", target: .reader)) }
            if listening { items.append(MoActivity(id: "game-listening", kind: .listening, title: "正在聆听", target: .reader, level: inputLevel)) }
            if let lastError { items.append(MoActivity(id: "game-error", kind: .failed, title: "陪玩异常", target: .reader, detail: lastError)) }
            items.append(MoActivity(id: "game-ready", kind: .reviewing, title: "陪玩就绪", target: .reader))
        }
        var result = MoActivityState.resolve(items)
        result.context = "守城小国王"
        return result
    }
}

// MARK: - Views

struct GameOrbitView: View {
    @ObservedObject var session: GameSession
    @Environment(\.colorScheme) private var colorScheme
    @State private var dragStart: (anchor: CGPoint, mouse: CGPoint)?
    @GestureState private var isDragging = false
    private var ringColor: Color { colorScheme == .dark ? Color(red: 0.69, green: 0.86, blue: 0.97) : Color(red: 0.35, green: 0.52, blue: 0.68) }
    var body: some View {
        ZStack {
            Button { session.setRecordsShown(!session.recordsShown) } label: {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(colorScheme == .dark ? Color(red: 0.77, green: 0.93, blue: 0.89) : Color(red: 0.13, green: 0.47, blue: 0.39))
                    .background(colorScheme == .dark ? Color(red: 0.18, green: 0.27, blue: 0.29) : Color(red: 0.92, green: 0.98, blue: 0.96), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
            }.accessibilityLabel(session.recordsShown ? "收起指令记录" : "打开指令记录").help(session.recordsShown ? "收起指令记录" : "打开指令记录")
                .position(x: 37, y: 105).zIndex(1)
            Button { session.toggleListening() } label: {
                MoOrb(ringColor: ringColor, busy: session.executing, activity: { session.activityState })
            }.accessibilityLabel(session.listening ? "停止听" : "开始听").help("点击开关听；拖动移动呼吸灯")
                .highPriorityGesture(DragGesture(minimumDistance: 6).updating($isDragging) { _, state, _ in state = true }.onChanged { value in
                    let mouse = NSEvent.mouseLocation
                    if dragStart == nil { dragStart = (session.panels.orbAnchor, CGPoint(x: mouse.x - value.translation.width, y: mouse.y + value.translation.height)) }
                    if let origin = dragStart { session.panels.moveOrb(to: CGPoint(x: origin.anchor.x + mouse.x - origin.mouse.x, y: origin.anchor.y + mouse.y - origin.mouse.y)) }
                }.onEnded { _ in dragStart = nil })
                .onChange(of: isDragging) { if !isDragging { dragStart = nil } }
                .contextMenu {
                    Button(session.listening ? "停止听" : "开始听") { session.toggleListening() }
                    Button(session.recordsShown ? "收起指令记录" : "打开指令记录") { session.setRecordsShown(!session.recordsShown) }
                    Divider()
                    Button("关闭陪玩窗口") { session.onClose?() }
                }.position(x: 64, y: 84)
            Button { session.toggleListening() } label: {
                Image(systemName: session.listening ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(session.listening ? Color(red: 0.08, green: 0.45, blue: 0.94) : Color(red: 0.30, green: 0.35, blue: 0.39), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
            }.help(session.listening ? "正在听；点击关闭麦克风" : "麦克风已关；点击开始听")
                .accessibilityLabel(session.listening ? "关闭麦克风" : "打开麦克风")
                .position(x: 91, y: 105)
        }.frame(width: 128, height: 124).buttonStyle(.plain)
    }
}

struct GameRecordView: View {
    @ObservedObject var session: GameSession
    private func color(_ kind: GameRecord.Kind) -> Color {
        switch kind {
        case .done: return Color.green
        case .skipped: return Color.orange
        case .unknown: return IslandStyle.secondary
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("守城小国王 · 陪玩").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 2)
                Text(session.statusLine).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(session.listening ? Color.green : IslandStyle.secondary).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Color.white.opacity(0.1), in: Capsule())
            }
            Divider().overlay(IslandStyle.line)
            if session.records.isEmpty {
                Text(session.listening ? "说「骑兵冲锋」「全军撤退」试试" : "点右侧麦克风开始语音指挥").font(.system(size: 11)).foregroundStyle(IslandStyle.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(session.records.reversed()) { record in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(record.time.formatted(date: .omitted, time: .standard)).font(.system(size: 10, design: .monospaced)).foregroundStyle(IslandStyle.secondary)
                                    Spacer(minLength: 2)
                                }
                                Text("你说：" + record.said).font(.system(size: 11)).lineLimit(2)
                                Text(record.kind == .unknown ? record.result : (record.kind == .done ? "已发出：" : "未发出：") + record.result).font(.system(size: 11)).foregroundStyle(color(record.kind)).lineLimit(3)
                            }
                        }
                    }
                }
            }
        }.padding(10).buttonStyle(.plain).modifier(IslandSurface())
    }
}

struct GameSettingsForm: View {
    @AppStorage(GameSettings.urlKey) private var url = GameSettings.defaultURL
    @AppStorage(GameSettings.replyKey) private var reply = true
    @State private var custom = false
    private let customTag = "custom"
    private var selection: Binding<String> {
        Binding(get: { custom || !GameSettings.presets.contains { $0.url == url } ? customTag : url },
                set: { tag in
                    if tag == customTag { custom = true } else { custom = false; url = tag }
                })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("游戏地址", selection: selection) {
                ForEach(GameSettings.presets, id: \.url) { Text($0.name).tag($0.url) }
                Text("自定义").tag(customTag)
            }
            if selection.wrappedValue == customTag {
                TextField("http(s):// 开头的地址", text: $url).textFieldStyle(.roundedBorder)
                if GameSettings.validURL(url) == nil { Text("地址无效，将使用正式版").font(.system(size: 11)).foregroundStyle(Color.orange) }
            }
            Toggle("语音回应", isOn: $reply)
            Text("从菜单栏「陪玩 · 守城小国王」打开游戏窗口，小墨挂在窗口上，说「骑兵冲锋」「全军撤退」即可指挥。识别优先在本机完成；本机不支持时会使用 Apple 在线识别（此时状态行会提示），语音回应在本机合成。").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Window

@MainActor final class GameWindow: NSObject, NSWindowDelegate, WKNavigationDelegate {
    let session = GameSession()
    private(set) var window: NSWindow?
    private(set) var webView: WKWebView?
    private var observers: [NSObjectProtocol] = []
    var isOpen: Bool { window != nil }

    override init() {
        super.init()
        session.onClose = { [weak self] in self?.close() }
    }

    func show(url: URL = GameSettings.url) {
        if let window { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); syncPanels(); return }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(GameBridge.makeUserScript())
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "守城小国王 · 小墨陪玩"
        window.contentView = web
        window.contentMinSize = CGSize(width: 480, height: 360)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window; webView = web
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in Task { @MainActor in self?.syncPanels() } })
        }
        for name in [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.syncPanels() } })
        }
        session.attach(webView: web)
        web.load(URLRequest(url: url))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        syncPanels()
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        session.end()
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        window?.delegate = nil
        window = nil; webView = nil
    }

    static func cgFrame(_ frame: CGRect, desktopTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: desktopTop - frame.maxY, width: frame.width, height: frame.height)
    }

    func syncPanels() {
        guard let window, session.active else { return }
        let visible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible) && NSApp.isActive
        if visible { session.panels.position(Self.cgFrame(window.frame, desktopTop: session.panels.desktopTop)) } else { session.panels.hideForWorkspace() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { session.status = ""; Task { await session.refreshState() } }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { session.status = "页面加载失败：" + error.localizedDescription }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { session.status = "页面加载失败：" + error.localizedDescription }
}
