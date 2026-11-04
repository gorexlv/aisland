# U3 工作流提效验收报告

基线：`08275f59b1655aae407e9c1265314baf4415536b`。仅当前 ux-workflow worktree 修改；未推送、未合并 main、未清理 worktree。

## 实现和逐项证据

| 验收项 | 实现/测试证据 |
| --- | --- |
| 会议中 OCR / 文字批阅不停止会议 | `Recorder.readScreen/startReview` 移除 recording/busy 整体阻塞；两条路径不调用 stopMeeting、不重置会话；workflow fixture 在 recording=true、非空 transcript 下调用实际方法，断言 recording/transcript 保留；窗口枚举注入空 fixture，批阅使用已激活 sidebar，未采集画面 |
| 批阅语音互斥 | `microphoneReserved` 在会议权限准备前置位，在实际采集停止后解除；VoiceInput.unavailableReason 在入口与按钮同时阻止启动，显示“会议录音中，可输入文字”；实际 meeting() 对 preparing/dictating/finishing 三态均提前返回，测试覆盖；文字 draft 始终可写 |
| 区分收尾和保存 | 采集准备/运行期间禁止批阅语音；采集停止后的转写 drain 和后台保存不占用批阅麦克风；OCR/文字批阅在各阶段均可用；busy 仍防止第二场会议抢占未收尾识别器 |
| 快捷框选 | 状态栏菜单“快捷框选取字”和 OCR 面板“快捷框选屏幕区域”；每屏透明选择层，无需窗口列表；松手后才调用 SCScreenshotManager，Esc 关闭全部层；没有定时/后台截图 |
| 多屏/像素 | 用 NSScreen 对应 displayID 选择 SCDisplay；框选归一化为该屏 top-left 坐标，用 filter.contentRect 点尺寸映射，再依 pointPixelScale 计算截图像素；避免全局负坐标/Y 翻转混用；OCR 上限 1200 万像素和单边 8192；fixture 覆盖负原点、副屏在上、超宽/高分辨率预算；跨屏连续拖动不拼接，需在目标屏内框选 |
| OCR 保留 | 新操作不清空 text/pending/savedFile；取消、注入采集失败、空结果均保留编辑；成功结果替换 dirty 内容时提供保留/另存后继续/放弃；另存失败不替换；已保存内容不重复确认；测试直接调用实际接受和失败路径 |
| 编辑/复制/保存 | TextEditor 绑定 text；复制测试用独立 pasteboard；save 以当前 text + 原 pending 图像/source/region 保存；测试读回文字、图片字节和 source.json 核对；保持原 region.png/source.json/文字.txt 文件格式；保存修改生成独立记录 |
| 退出保护 | OCR dirty 先尝试保存，失败返回取消退出并保留内容；随后仍调用原 review.closeForTermination 和原有界 stopMeeting/finishSavesForTermination；未修改这些既有收尾实现；测试覆盖 OCR 保存失败不允许退出 |
| 阅读不跳动 | 用实际 NSTextView/NSScrollView 观察 viewport 与选择范围；生产使用 TranscriptFollowState；追加只在 following 时滚到底，上滚/选择时保留 offset 与 selection，显示“有新内容 · 回到最新”；真实视图 fixture 断言 offset/selection、初次到底和恢复跟随；状态测试覆盖手动回到底部 |

## 命令与结果

- `bash outputs/DuckIsland/Tests/workflow/run.sh`：退出码 0，workflow 模型/实际 Recorder/实际 AppKit 视图测试通过；既有 SelfTests 的 OCR 中文英文识别/区域裁剪/保存、Review 图片文字导出、后台保存 fixture、PCM/Notes 脚本编译检查全部通过。
- `bash outputs/DuckIsland/Tests/run-save-reliability.sh`：local/store 保存可靠性 fixture 均通过；两种发行配置无签名编译通过；NotesHelper 无签名编译通过。
- `zsh outputs/DuckIsland/Tests/meeting/run.sh`：退出码 0，慢双路识别、队列/字节上限、尾部排空、超时保留、过期回调、双源时间顺序等回归全部通过。
- `git diff --check`：无空白错误。

测试没有执行签名脚本、真实录音、真实截图、外部 AI 或 Notes 写入；SelfTests 只编译 Notes AppleScript，不执行；fixture 使用临时目录和独立 pasteboard。

## 共享接口/集成注意

- `VoiceInput.swift` 新增 `@Published unavailableReason: String?`；ReviewModel 无修改。
- `ReviewPanels.swift` 仅两处改动：麦克风 disabled 条件追加 unavailableReason；状态显示优先 unavailableReason。U1 合并时保留其删除/撤销实现，并带入这两处。
- `main.swift` 与 U1/U2 存在共享：Recorder 采集协调、可选 ScreenReader 构造注入、工具按钮 disabled 条件、转写区域替换为 TranscriptReader、状态栏快捷菜单及 selector、requestTermination 的 OCR 保存前置检查。U1 顶部入口/toggle 以 U1 最终布局为准，但不能重新按 recording/busy 禁用 OCR/文字批阅；U2 状态/结果以其实现为准，并保留 microphoneReserved 与转写 drain/后台保存区别。
- 新视图/模型位于现有 ScreenReader.swift，无新生产源文件，无需改 Xcode 工程或构建源列表。U2 最近记录继续扫描原 OCR 目录格式，不需索引更新。
- `Tests/workflow/run.sh` 截取 main.swift 应用启动分支之前的真实代码，再接 fixture 入口，避免启动正常应用/权限请求；如果入口编译条件发生变化需同步该截取标记。

## 人工验收限制

未测试真实状态栏菜单操作、Esc、混合 DPI 多屏、全屏空间、窗口切换、屏幕权限拒绝/撤销及真实截图内容；这些需集成人工使用非私人测试桌面验收。没有增加全局快捷键注册，快捷入口为菜单和面板按钮。真实会议期间工具切换、系统音频/麦克风持续性、系统 Speech 收尾以及真实触控板滚动体验仍需设备验收；离线测试证明本应用状态和视图行为，不证明系统框架时延或硬件表现。PM 另行集成验收并合入 origin/main 后再关闭清理。
