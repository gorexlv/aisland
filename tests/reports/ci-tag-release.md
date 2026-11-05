# CI / tag Release 验证记录

日期：2026-11-05；基线 `ff8e344cf55602a8d4ffff380f01c5079d4c53fc`。本工作仅新增发布基础设施、README 和 Python 缓存忽略项，未修改应用交互、视觉资源、本地 build/sign-local 脚本或签名材料。

## 设计与边界

- `.github/workflows/ci.yml`：PR、main/ci/** push、手动验证；所有 tag push 先严格解析。macos-15 arm64，运行时断言架构。官方 checkout v7.0.1、upload-artifact v7.0.2、download-artifact v8.0.2 均固定完整 SHA，来自各官方仓库 release/tag API。
- validate 默认 contents:read，release job 单独 contents:write、needs validate；不使用 pull_request_target，不向 PR 暴露 secrets。checkout 不保留凭据。没有第三方包依赖，不添加无效缓存。
- 非签名编译直接发行与 APP_STORE；正式 App Store Xcode 工程包含 NotesHelper。Apple Silicon linker 自带 ad-hoc Mach-O 签名不等于证书签名；打包时显式补全 app 的 ad-hoc 签名并验证。
- 只选择 Foundation/合成 PCM/注入依赖测试；不执行 AppKit 窗口/剪贴板/离屏 UI、TCC、self-test、真实 Speech、采集、Notes、外部 AI。编译生产代码不等于执行这些路径。真实 GUI 和隐私权限仍需设备验收。
- tag 需为 main 历史提交且未移动。发布串行，同 tag 已存在 Release/草稿一律拒绝；API 失败终止；先上传全部资产到草稿，再公开。网络失败的草稿留给维护者检查，不自动删改。
- 仓库 `gh secret list` 成功且无名称；Actions variables API 返回空列表，Actions enabled=true。未读取任何 secret 值。当前只实现 ad-hoc/未公证路径，无 Apple 配置需求，不宣称 Developer ID 或公证。

## 本地验证

本机 Xcode 26.2 (17C52)，arm64。以下命令均成功：

```sh
bash scripts/ci/test.sh
python3 -m unittest discover -s scripts/ci -p 'test_*.py' -v
bash -n scripts/ci/build.sh scripts/ci/package.sh scripts/ci/publish.sh scripts/ci/test.sh
shellcheck scripts/ci/*.sh
actionlint -shellcheck /tmp/aisland-ci-tools/shellcheck-v0.11.0/shellcheck .github/workflows/ci.yml
bash scripts/ci/build.sh /tmp/aisland-ci-direct v1.2.3-rc.1
bash scripts/ci/package.sh /tmp/aisland-ci-direct v1.2.3-rc.1
xcodebuild -project outputs/DuckIsland/DuckIsland.xcodeproj -scheme DuckIsland \
  -configuration Release -derivedDataPath /tmp/aisland-ci-store \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
git diff --check
```

lint 工具下载到 `/tmp/aisland-ci-tools`（actionlint 1.7.12 / shellcheck 0.11.0），未改全局安装。Python 7 项测试覆盖版本边界、预发布、非法输入、重复/移动/off-main tag、API/上传/校验失败不公开、先草稿后发布；Git/GitHub CLI 均由临时 fake 替代，测试没有创建 tag/Release。

离线 Swift 套件覆盖双版本历史记录、禁用 AI、保存失败、写入排序、超时与取消、两版完整 swiftc 编译、NotesHelper 编译、识别队列容量/错误/迟到结果/收尾/排序。原会议脚本 tracked 路径为小写 `outputs/DuckIsland/tests/meeting`，入口遵循 tracked 路径；不变更既有大小写布局。

本地 ZIP 成功展开，顶层 `Duck Island.app`（ditto 可附带 `__MACOSX` 资源元数据）；SHA256 匹配，解压后二进制逐字节一致，bundle 严格签名验证通过，Info.plist 数字版本为 1.2.3、完整 tag 为 v1.2.3-rc.1、commit 与 build-info 一致。codesign 显示 Signature=adhoc、TeamIdentifier=not set；未运行 app，未改变 Gatekeeper。

完整本地输出：`/tmp/aisland-ci-tests.log`、`/tmp/aisland-ci-direct.log`、`/tmp/aisland-ci-store.log`；这些是临时验证文件，不纳入仓库。

## 官方依据

- [GitHub runner 规格](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)：公开仓库 macos-15 为 M1 arm64；工作流仍断言真实架构。
- [Release API](https://docs.github.com/en/rest/releases/releases#create-a-release) 与 [gh release create](https://cli.github.com/manual/gh_release_create)：contents write、verify-tag、draft、generate-notes；[gh release edit](https://cli.github.com/manual/gh_release_edit) 用于上传完成后公开。
- [Apple 版本格式](https://developer.apple.com/help/glossary/version-number/)：CFBundleShortVersionString 使用三段数字，预发布后缀另存。
- [Apple Gatekeeper 说明](https://support.apple.com/en-us/102445)：ad-hoc 不等于可信 Developer ID/公证，下载可能被系统阻止。

正式 tag 发布没有实际执行；测试与普通 CI 构建不代表已完成真实 Release 端到端发布。
