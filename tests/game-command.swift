// Game voice command parser, sentence splitter and bridge argument encoding. Pure: no microphone, no network.
import Cocoa

let bats = [
    GameBat(id: 0, name: "重盾兵1营", typeId: "heavyShield", shooter: false, mounted: false, alive: true),
    GameBat(id: 1, name: "剑盾兵1营", typeId: "swordShield", shooter: false, mounted: false, alive: true),
    GameBat(id: 2, name: "剑盾兵2营", typeId: "swordShield", shooter: false, mounted: false, alive: true),
    GameBat(id: 3, name: "长枪兵", typeId: "pike", shooter: false, mounted: false, alive: true),
    GameBat(id: 4, name: "弓兵1营", typeId: "archer", shooter: true, mounted: false, alive: true),
    GameBat(id: 5, name: "弩兵1营", typeId: "crossbow", shooter: true, mounted: false, alive: true),
    GameBat(id: 6, name: "重骑兵", typeId: "heavyCav", shooter: false, mounted: true, alive: true),
    GameBat(id: 7, name: "骑射营", typeId: "horseArcher", shooter: false, mounted: true, alive: true),
    GameBat(id: 8, name: "剑盾兵3营", typeId: "swordShield", shooter: false, mounted: false, alive: false),
]
let allIDs = [0, 1, 2, 3, 4, 5, 6, 7]

func intent(_ action: GameAction, _ target: GameTarget, _ subject: String = "") -> GameIntent { GameIntent(action: action, target: target, subject: subject) }

struct Case { let text: String; let selected: Int?; let expected: GameIntent? }
func c(_ text: String, _ expected: GameIntent?, selected: Int? = nil) -> Case { Case(text: text, selected: selected, expected: expected) }

let cases: [Case] = [
    c("小莫小莫骑兵冲锋", intent(.command(.charge), .units([6, 7]), "骑兵")),
    c("小墨小墨，骑兵冲锋！", intent(.command(.charge), .units([6, 7]), "骑兵")),
    c("晓墨晓墨 全军撤退", intent(.command(.retreat), .units(allIDs), "全军")),
    c("全军撤退", intent(.command(.retreat), .units(allIDs), "全军")),
    c("所有人前进", intent(.command(.advance), .units(allIDs), "全军")),
    c("弓箭手坚守", intent(.command(.hold), .units([4, 5]), "弓兵")),
    c("射手顶住", intent(.command(.hold), .units([4, 5]), "弓兵")),
    c("剑盾兵一营前进", intent(.command(.advance), .units([1]), "剑盾兵1营")),
    c("剑盾兵二营坚守", intent(.command(.hold), .units([2]), "剑盾兵2营")),
    c("剑盾兵三营冲锋", intent(.command(.charge), .units([]), "剑盾兵3营")),
    c("重骑冲", intent(.command(.charge), .units([6]), "重骑兵")),
    c("重骑兵冲锋", intent(.command(.charge), .units([6]), "重骑兵")),
    c("骑射放风筝", intent(.command(.skirmish), .units([7]), "骑射")),
    c("骑射营游击", intent(.command(.skirmish), .units([7]), "骑射营")),
    c("步兵压上", intent(.command(.advance), .units([0, 1, 2, 3]), "步兵")),
    c("盾兵后撤", intent(.command(.retreat), .units([0, 1, 2]), "盾兵")),
    c("剑盾退回", intent(.command(.retreat), .units([1, 2]), "剑盾兵")),
    c("长枪兵推进", intent(.command(.advance), .units([3]), "长枪兵")),
    c("枪兵守住", intent(.command(.hold), .units([3]), "长枪兵")),
    c("弩兵杀", intent(.command(.charge), .units([5]), "弩兵")),
    c("弩兵自由行动", intent(.command(.auto), .units([5]), "弩兵")),
    c("骑兵交给副将", intent(.command(.auto), .units([6, 7]), "骑兵")),
    c("身边的营冲锋", intent(.command(.charge), .near)),
    c("附近坚守", intent(.command(.hold), .near)),
    c("跟我来", intent(.command(.follow), .near)),
    c("小墨小墨跟上", intent(.command(.follow), .near)),
    c("骑兵跟着我", intent(.command(.follow), .near)),
    c("暂停", intent(.pause, .near)),
    c("小莫小莫继续", intent(.resume, .near)),
    c("冲锋", intent(.command(.charge), .defaultNear)),
    c("坚守", intent(.command(.hold), .defaultNear)),
    c("自动", intent(.command(.auto), .defaultNear)),
    c("撤退", intent(.command(.retreat), .units(allIDs), "全军")),
    c("前进", intent(.command(.advance), .units(allIDs), "全军")),
    c("风筝", intent(.command(.skirmish), .units(allIDs), "全军")),
    c("冲锋", intent(.command(.charge), .selected), selected: 4),
    c("撤退", intent(.command(.retreat), .selected), selected: 4),
    c("冲锋", intent(.command(.charge), .selected), selected: 0),
    c("骑兵撤退", intent(.command(.retreat), .units([6, 7]), "骑兵"), selected: 4),
    c("骑兵和弓兵冲锋", intent(.command(.charge), .units([6, 7, 4, 5]), "骑兵、弓兵")),
    c("重盾兵冲锋", intent(.command(.charge), .units([0]), "重盾兵")),
    c("重盾坚守", intent(.command(.hold), .units([0]), "重盾兵")),
    c("撤", nil),
    c("冲", nil),
    c("杀", nil),
    c("冲杯咖啡", nil),
    c("小墨小墨撤", intent(.command(.retreat), .units(allIDs), "全军")),
    c("小莫小莫冲", intent(.command(.charge), .defaultNear)),
    c("随便说说", nil),
    c("今天天气不错", nil),
    c("小墨小墨", nil),
    c("", nil),
    c("骑兵", nil),
]

for (index, item) in cases.enumerated() {
    let result = gameParseCommand(item.text, bats: bats, selected: item.selected)
    precondition(result == item.expected, "case \(index) [\(item.text)] expected \(String(describing: item.expected)) got \(String(describing: result))")
}
precondition(cases.count >= 30)

// Several commands in one sentence run in order; "冲杀" is a single charge; "继续前进" is an advance.
func multi(_ text: String) -> [GameIntent] { gameParseCommands(text, bats: bats) }
precondition(multi("骑兵冲锋弓兵坚守") == [intent(.command(.charge), .units([6, 7]), "骑兵"), intent(.command(.hold), .units([4, 5]), "弓兵")], "\(multi("骑兵冲锋弓兵坚守"))")
precondition(multi("小墨小墨骑兵冲杀，弓箭手撤退") == [intent(.command(.charge), .units([6, 7]), "骑兵"), intent(.command(.retreat), .units([4, 5]), "弓兵")])
precondition(multi("继续前进") == [intent(.command(.advance), .units(allIDs), "全军")])
precondition(multi("全军前进暂停") == [intent(.command(.advance), .units(allIDs), "全军")])
precondition(multi("剑盾兵一营前进重骑兵二营冲锋").count == 2)
precondition(multi("随便说说").isEmpty && multi("").isEmpty)

// Spoken outcome.
let degradedResult = GameRunResult(["ok": true, "done": [["name": "弓兵1营", "cmd": "auto", "from": "charge"], ["name": "重骑兵", "cmd": "charge"]], "skipped": [], "message": "已发出"])
precondition(degradedResult.spoken(for: gameParseCommand("骑兵弓兵冲锋", bats: bats)!) == "弓兵1营自由行动，重骑兵冲锋")
let plainResult = GameRunResult(["ok": true, "done": [["name": "重骑兵", "cmd": "charge"]], "skipped": [], "message": "已发出"])
precondition(plainResult.spoken(for: gameParseCommand("重骑兵冲锋", bats: bats)!) == "重骑兵冲锋")
let nearFail = GameRunResult(["ok": false, "done": [], "skipped": [], "message": "国王身边没有可指挥的营"])
precondition(nearFail.spoken(for: gameParseCommand("跟我来", bats: bats)!) == "国王身边没有可指挥的营")

// Spoken replies and bridge arguments.
precondition(gameParseCommand("骑兵冲锋", bats: bats)?.spoken == "骑兵冲锋")
precondition(gameParseCommand("全军撤退", bats: bats)?.spoken == "全军撤退")
precondition(gameParseCommand("跟我来", bats: bats)?.spoken == "跟我来")
precondition(gameParseCommand("冲锋", bats: bats)?.spoken == "身边冲锋")
let args = gameParseCommand("弓兵坚守", bats: bats)!.runArguments!
precondition((args["targets"] as? [Int]) == [4, 5] && args["cmd"] as? String == "hold")
precondition(gameParseCommand("冲锋", bats: bats)!.runArguments!["targets"] as? String == "near")
precondition(gameParseCommand("暂停", bats: bats)!.runArguments == nil)

// Chinese numerals and wake stripping.
precondition(gameNormalize("剑盾兵十二营") == "剑盾兵12营")
precondition(gameNormalize("剑盾兵二十营") == "剑盾兵20营")
precondition(gameNormalize("剑盾兵十营") == "剑盾兵10营")
precondition(gameStripWake("小莫小莫骑兵") == "骑兵")
precondition(gameStripWake("骑兵小墨") == "骑兵小墨")
precondition(gameContextualStrings(bats: bats).contains("重骑兵") && !gameContextualStrings(bats: bats).contains("剑盾兵3营"))

// Names with quotes/backslashes must still parse and encode into a valid JS expression.
let odd = [GameBat(id: 9, name: "老\"王\\营", typeId: "pike", shooter: false, mounted: false, alive: true)]
precondition(gameParseCommand("老\"王\\营冲锋", bats: odd)?.target == .units([9]))
let expression = GameBridge.expression(method: "run", argument: ["targets": [9], "cmd": "charge", "note": "a\"b\\c\u{2028}"])!
precondition(expression.hasPrefix("window.__MoBridge ? window.__MoBridge.run(") && !expression.contains("\u{2028}"))

// Sentence splitter: a sentence ends after 0.8 s without new text; delivered text is not repeated.
var splitter = GameSentenceSplitter()
let t0 = Date()
splitter.feed("骑兵", now: t0)
precondition(splitter.poll(now: t0.addingTimeInterval(0.5)) == nil)
splitter.feed("骑兵冲锋", now: t0.addingTimeInterval(0.6))
precondition(splitter.poll(now: t0.addingTimeInterval(1.2)) == nil)
precondition(splitter.poll(now: t0.addingTimeInterval(1.5)) == "骑兵冲锋")
precondition(splitter.poll(now: t0.addingTimeInterval(3)) == nil)
splitter.feed("骑兵冲锋全军撤退", now: t0.addingTimeInterval(3))
precondition(splitter.poll(now: t0.addingTimeInterval(4)) == "全军撤退")
splitter.feed("全军撤退暂停", now: t0.addingTimeInterval(5))
precondition(splitter.finish() == "全军撤退暂停")
precondition(splitter.finish() == nil)

// Punctuation / digit rewrites of delivered text are not re-submitted; punctuation-only text is ignored.
var again = GameSentenceSplitter()
again.feed("骑兵冲锋", now: t0)
precondition(again.poll(now: t0.addingTimeInterval(1)) == "骑兵冲锋")
again.feed("骑兵，冲锋。", now: t0.addingTimeInterval(2))
precondition(again.poll(now: t0.addingTimeInterval(3)) == nil, "re-punctuated text must not repeat")
again.feed("骑兵，冲锋。全军撤退", now: t0.addingTimeInterval(4))
precondition(again.poll(now: t0.addingTimeInterval(5)) == "全军撤退")
again.feed("骑兵，冲锋。全军撤退。。", now: t0.addingTimeInterval(6))
precondition(again.poll(now: t0.addingTimeInterval(7)) == nil)
again.feed("。，", now: t0.addingTimeInterval(8))
precondition(again.poll(now: t0.addingTimeInterval(9)) == nil)
var rewrite = GameSentenceSplitter()
rewrite.feed("骑兵冲锋", now: t0)
precondition(rewrite.poll(now: t0.addingTimeInterval(1)) == "骑兵冲锋")
rewrite.feed("骑兵冲封全军撤退", now: t0.addingTimeInterval(2))   // earlier words rewritten by the recognizer
precondition(rewrite.poll(now: t0.addingTimeInterval(3)) == "全军撤退", "rewrite must not re-run the first command")

print("game-command ok (\(cases.count) cases)")
exit(0)
