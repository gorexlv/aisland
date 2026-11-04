# U1 操作可预期交付

基线：08275f59b1655aae407e9c1265314baf4415536b；分支 gorexlv/ux-predictable-actions。仅当前 worktree；未合并、未推送，保留 session/worktree。

## 验收与实现

- 黄鸭及右键功能菜单只切换控制面板；录制中重复会议入口不会结束或再启动采集。独立「结束会议」按钮和右键结束入口复用有 busy/recording 防重的 stopMeeting；录制状态及秒级时长常显。菜单保留动物并常驻「会议记录 / 提取文字 / 截图批阅」，菜单和顶部动画遵循 reduce motion。面板高度为文字标签及录制条预留空间。
- 画布与侧栏单击均只选中；只有麦克风按钮启动语音。选区切换、删除、撤销和关闭沿用 finishAndWait，最终语音先写回原选区再修改身份。
- 支持删除选中标记（含其意见）、删除截图及其全部意见、撤销最近新增标记/删除操作（会话内最多30步）。截图删除确认显示意见数量，完成反馈明确可撤销。侧栏及画布支持 Cmd+Delete / Cmd+Z；文本编辑器保留正常文本编辑语义。撤销保留仍存在区域的新文字；删除和撤销立即持久化，失败保留内存内容和可重试状态。
- 最后一张截图删除后持久化空清单，重开不复活旧内容；清单提交后清理旧截图原图和导出图，撤销从内存原始字节重新写入。截取时间持久化并显示于侧栏及冻结画布。
- 文案为「截取画面并标注 / 返回实时窗口」，不暗示暂停目标应用。「复制全部」不关闭截图或会话；「保存并关闭」继续 await 持久化，失败不关闭。

## 可控行为测试

新增 Tests/PredictableActions.swift 与 Tests/run-predictable-actions.sh。脚本仅替换生产 main.swift 的应用启动入口，实际编译 Recorder、ReviewModel、ReviewStore、VoiceInput 等生产类型，没有镜像实现。虚构 PNG、临时目录、合成 receiveTranscript 回调覆盖：录制中黄鸭菜单、重复启动/结束幂等、选区切换等待最终回调、跨截图意见归属、删除截图/标记、撤销新增标记、撤销期间最终语音归属、持久化重开、删除全部截图及物理文件清理、恢复删除内容、关闭时语音排空和保存失败保留内容。

## 精确验证命令

工作目录为本 worktree 根目录，除注明外所有最终运行 exit 0：

1. `bash outputs/DuckIsland/Tests/run-predictable-actions.sh`：PASS menu/start/stop idempotence, selection speech barrier, delete/undo, persistence/empty recovery, failed close retention。
2. `bash outputs/DuckIsland/Tests/run-save-reliability.sh`：local/store 保存可靠性测试通过；两种 swiftc 无签名主程序及 NotesHelper 构建通过。
3. `zsh outputs/DuckIsland/Tests/meeting/run.sh`：确定性队列/超限/排空/超时/旧回调/双源时序测试通过。
4. `xcodebuild -project outputs/DuckIsland/DuckIsland.xcodeproj -scheme DuckIsland -configuration Release -derivedDataPath /tmp/duck-u1-release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`：BUILD SUCCEEDED；项目 Release 编译条件 APP_STORE。完整日志 /tmp/u1-xcode.log。
5. 在 outputs/DuckIsland 目录运行 `swiftc main.swift MeetingCapture.swift MeetingRecognition.swift NotesExport.swift MeetingAnalysis.swift SpeechProbe.swift ScreenWindows.swift ScreenReader.swift VoiceInput.swift ReviewModel.swift ReviewPanels.swift ReviewExport.swift SelfTests.swift -o /tmp/duck-u1-self/DuckIsland -framework Cocoa -framework SwiftUI -framework Speech -framework AVFoundation -framework ScreenCaptureKit -framework Vision -target arm64-apple-macosx15.0`，随后 `/tmp/duck-u1-self/DuckIsland --self-test`：句数、虚构图像 OCR、批阅导出/坐标/图文往返、后台保存与会议测试通过。
6. `git diff --check`：通过。

曾出现一次构建期间源文件正在修改导致 swiftc 拒绝构建，以及新增测试中 throwing autoclosure 编译错误；均已修复并重新运行通过，未将非零检查视为通过。

## 文件与集成接口

- outputs/DuckIsland/main.swift：Recorder.toggle、meeting 防重复、recordingStartedAt/启动停止赋值；IslandView 顶部/菜单/右键/减少动画；AppDelegate.position 面板高度（新增菜单文字和录制条）。U2/U3 cherry-pick 时需人工保留各自共享 main.swift 修改，尤其 meeting guards、结果区布局和窗口高度。
- outputs/DuckIsland/ReviewModel.swift：截图时间、可观察截图列表、结构撤销历史、删除/撤销及保存屏障、空会话、复制语义。
- outputs/DuckIsland/ReviewPanels.swift：仅选中、删除确认/数量、撤销/键盘、时间、明确捕获和保存关闭文案。
- outputs/DuckIsland/ReviewExport.swift：StoredReviewShot.capturedAt 可选字段、空会话读取、提交清单后清理旧图片。
- outputs/DuckIsland/Tests/PredictableActions.swift
- outputs/DuckIsland/Tests/run-predictable-actions.sh
- reports/U1-predictable-actions.md

未修改 build.sh、Xcode源码列表、VoiceInput、ScreenReader 或 U2/U3 分支。新增测试不需要注册应用 target。现有存储 version=1 保持兼容，旧截图无 capturedAt 显示“未知（旧记录）”；无需迁移。

## 限制

未真实采集麦克风/屏幕、未真实 Notes/外部 AI、未签名运行或验证真实 UI/VoiceOver。界面布局通过代码及构建检查，未声称人工视觉验收通过。撤销历史仅当前会话内存在，关闭重开恢复的是最后持久化数据而非撤销栈；最多30步，不提供复杂拖拽缩放或 redo。文件系统多文件导出不是整体原子事务，沿用清单最后提交策略；清理失败会明确报保存失败并保留当前会话。
