# U2 状态与结果闭环交付

基线：08275f59b1655aae407e9c1265314baf4415536b。工作树：ux-status-results。仅本工作树开发；未合并、推送、签名、真实录音、访问 Notes 或发送转写至 AI。

## 实现与验收对应

- 停止录音后主面板保持展开，明确停止录音、录音已停止/转写收尾、原文落盘、可选 AI、最终本地记录和 Notes 同步状态；无百分比。收起后可由菜单栏“最近记录与任务”找回。任务错误不依赖 toast，保留跨会话结果与独立重试闭包，重复任务受 running 集合保护。
- 新增 RecentRecords.swift：独立可缩放最近记录窗口按磁盘修改时间降序扫描 Meetings/*.txt、ScreenReads/*/文字.txt、Reviews/*/review.txt。排除 diagnostics；包含类型、标题、预览、本地可读取状态、打开位置、结果查看/复制。不存在目录为空态，缺失/非法 UTF-8 明确降级，旧会议全文和旧批阅文字明确标注。批阅没有虚构历史编辑恢复。
- 会议结果独立窗口原文/总结/待办分栏，复制明确命名且范围与所选分栏一致；空总结/待办禁用复制。现有渲染结果的 Tickets 区段保留为待办，并不宣称额外结构化数据。无法识别的旧文本按原文展示，不推测总结。
- 两版均首次开始前说明全部系统声音与麦克风、原音不保存、Apple 优先本地/可能在线。直接发行版自动总结默认关闭，可见开关持久化；启用前确认文字发送至 Codex，关闭保留本地/Notes 保存。APP_STORE 分支不调用分析器，MeetingAnalysis.swift 整体编译条件排除。
- finishMeetingInBackground 在 AI 前尝试原文落盘，之后继续独立最终本地保存与 Notes 尝试。保留原有有界进程、串行磁盘写入、取消、退出恢复和部分转写警告。后台结果按旧 session ID 写入任务窗口，不覆盖新会议。
- 未变更持久格式，不删除/迁移旧记录。历史 Notes 状态一律诚实显示未知；当前进程任务使用真实回执。任务运行日志和重试闭包仅进程内保留，重启后从现有磁盘文字恢复，不声称恢复未完成外部任务。

## 离线验证

所有测试仅用虚构临时文件、注入 analyzer/exporter、测试子进程，无真实录音/Notes/AI。

1. `bash tests/run-recent-records.sh`（LOCAL_BUILD、APP_STORE）通过：真实磁盘三类型扫描和重新加载、空目录、损坏 UTF-8、文件删除、旧格式、诊断排除、原文/总结/待办范围、关闭 AI 零调用、APP_STORE 即使请求分析仍零调用、AI 前原文已落盘、网络失败后两种保存独立、阶段回调和部分警告。
2. `bash outputs/DuckIsland/Tests/run-save-reliability.sh`：两模式保存故障矩阵、进程超时/强杀/取消、写入顺序、跨会话未保存恢复、两模式无签名构建及 NotesHelper 构建。
3. `bash tests/run-integration-termination.sh` 通过：生产 Recorder/Delegate/recognition/review 的部分识别、磁盘/语音失败拒绝退出、重试、退出超时与重复退出。
4. `bash tests/run-review-recovery.sh` 通过：多截图恢复、损坏、保存失败保留、OCR Retina 预算、迟到语音切换和关闭。
5. 普通发行 Release：在 outputs/DuckIsland 下 `swiftc -O main.swift RecentRecords.swift MeetingCapture.swift MeetingRecognition.swift NotesExport.swift MeetingAnalysis.swift SpeechProbe.swift ScreenWindows.swift ScreenReader.swift VoiceInput.swift ReviewModel.swift ReviewPanels.swift ReviewExport.swift SelfTests.swift -o /tmp/u2-release -framework Cocoa -framework SwiftUI -framework Speech -framework AVFoundation -framework ScreenCaptureKit -framework Vision -target arm64-apple-macosx15.0` 成功。
6. `xcodebuild -project outputs/DuckIsland/DuckIsland.xcodeproj -scheme DuckIsland -configuration Release -derivedDataPath /tmp/u2-store-build CODE_SIGNING_ALLOWED=NO build` 成功。二进制断言不包含 `/opt/homebrew/bin/codex` 和 `--ignore-user-config` 通过。
7. `git diff --check` 通过。

测试过程中一次并发构建遇到源文件修改而失败，停止修改后完整重跑保存回归；不是忽略非零测试。日志：/tmp/u2-records.log、/tmp/u2-tests.log、/tmp/u2-termination.log、/tmp/u2-review.log、/tmp/u2-release.log、/tmp/u2-store.log（本机临时路径）。

## 集成共享接口与冲突

- 新源文件 RecentRecords.swift 必须加入所有显式编译列表；已更新 build.sh、Xcode PBX main target、run-save-reliability.sh、run-integration-termination.sh。NotesHelper 不依赖新模块。
- NotesExport.finishMeetingInBackground 新增末尾默认参数 `stage: (String) -> Void`，现有调用兼容；磁盘写入会先写一次原文，再写最终结果，故注入测试不得假设只写一次。
- main.swift 所有权交界：Recorder AI 设置与 disclosure、stopMeeting 展开状态/消息、enqueueSave 调度、独立快照重试、结果区新增按钮/开关、复制文案、菜单栏入口、面板展开高度 352→408。U1/U3 合并需手动保留各自入口、并发 guards、录制时长与滚动跟随变更。本提交没有修改 ScrollView 跟随逻辑、Review 编辑模块、OCR/Voice。
- main.swift 已有旧 showRecords（APP_STORE 打开目录）方法保留兼容，但菜单改用新的 recentRecords。

## 限制与后续验收

未做真实硬件、实际网络、Notes Apple Events、签名/沙盒权限及 GUI 布局/截图验收；构建与离线逻辑不能替代这些检查。历史文字解析依赖现有固定标题，未知格式只显示全文；文本可读不代表截图/批阅 manifest 完整，窗口文案只承诺文字可读取。历史 Notes 状态不持久化，不显示成功。独立集成 session 应统一 GUI 验收（尤其 U1 新入口/时长、面板高度、深浅色和窄屏）并推送 origin/main；本会话保留等待 PM 确认，不清理工作树。
