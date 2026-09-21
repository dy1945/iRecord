# iRecord 命令行

CLI 与 App 一起构建、签名和分发，路径为 `iRecord.app/Contents/Helpers/irecord`。
录屏由同一个 GUI App 执行，不依赖辅助功能窗口，也无需为 CLI 单独授予屏幕录制权限。

## 安装、升级、卸载

- 拖动 App 到 `/Applications` 后，打开 App，在「通用设置 → 命令行工具」点击安装。
- 也可运行：`/Applications/iRecord.app/Contents/Helpers/irecord install`。
- 开发部署：`./scripts/build_app.sh release` 后运行 `./scripts/install_app.sh`。
- 安装器创建 `~/.local/bin/irecord` 链接，在 `.zprofile` 和现有 Bash 登录配置（默认 `.bash_profile`）添加带 iRecord 标记的 PATH 段。无需 sudo，不覆盖其他命令。打开新终端生效；当前终端可运行 `export PATH="$HOME/.local/bin:$PATH"`。Fish 等其他 shell 自行配置 PATH。
- 在同一路径替换 App 后，命令链接自动使用新版。正在运行的旧 App 需退出后重开；安装器不强制结束录屏。移动 App 后重新安装链接。
- `irecord uninstall` 移除命令链接及 PATH 段，保留 App 和录像。删除 App 前先卸载 CLI。
- App 未运行时，CLI 自动从所属 bundle 启动它；旧 App 已运行但不支持 CLI 时返回 `app_unavailable`，不会再启动一个实例。

## Agent 工作流

```sh
irecord status --json
irecord permission request --json
irecord ls --search 'ego' --json
irecord preview --window-id 123 --output /tmp/ego-window.png --json
irecord start --window-id 123 --json
# 从 values.session_id 读取会话 ID，然后操作浏览器。
irecord pause --session-id SESSION --json
irecord resume --session-id SESSION --json
irecord stop --session-id SESSION --json
```

Agent 控制浏览器时，不建议切换浏览器全屏。先用窗口预览判断浏览器顶部栏的像素高度，停止时通过四边裁剪排除地址栏，同时保持浏览器窗口、窗口 ID 和自动化坐标稳定：

```bash
irecord stop --session-id SESSION --crop-insets 180,0,0,0 --json
```

`--crop-insets` 的顺序为 `上,右,下,左`，单位是原始录屏像素。它当前支持 MP4 和 MOV；导出仍会在裁剪后应用 `--max-edge`。

运行 `irecord -h` 查看简洁的命令菜单。`ls / preview / start / pause / resume / stop / permission` 是推荐短命令；旧版 `windows list / windows preview / recording ... / permission request` 仍兼容。

当前版本支持窗口录制，沿用 App 的声音、鼠标、输出帧率、格式和保存目录设置。未指定 `--output` 时，会在 App 的录制目录中自动生成不重复的文件名。默认将长边限制到 1920 像素并保持比例；可用 `--max-edge 1280` 调低，或用 `--max-edge 0` 保留原始像素。已有文件默认拒绝，显式 `--overwrite` 才原子替换。

Agent 在开录前必须先调用 `windows preview` 并实际检查 PNG 画面，不能只依赖应用名或窗口标题。浏览器可能存在后台标签页或同应用的其他窗口；预览不符合目标页面时，不得开始录制。

`start` 在采集进入 recording 状态后返回。Agent 应在可见操作前 `start`/`resume`，在模型生成、下载或人工等待前 `pause`，结果出现后再 `resume`。`stop` 等待文件收尾及导出完成，返回 `output`、`duration_seconds`、实际输出 `width`、`height`。CLI 创建的录屏不打开视频预览；普通 GUI 录屏仍使用预览流程。在 GUI 中停止 CLI 录屏后，可再调用 CLI stop 导出。重复 stop 同一已导出会话返回原结果。

交付前必须运行 `scripts/validate_cli_recording.sh <video> <App录制目录> [max-edge]`。它会同时检查保存目录、输出尺寸和画面是否有有效场景变化；只检查 MP4 可打开或存在 H.264 流不算通过。

JSON 外层含 `ok`、`code`、`message`、`values`，窗口列表为 `windows`；values 与窗口字段当前均为字符串。成功退出码 0，操作失败 1，参数错误 2。`permission_required` 表示需在系统设置授权 App；CLI 不自动弹出权限确认。socket 超时不会取消录屏或导出，应先查 status，再用同一 session_id 重试。

活动/未导出 CLI 会话不会被重复 start 覆盖。导出失败保留原始素材，status 返回 source_path；可修正输出路径后重试。会话只在 App 当前进程有效，重启后不恢复会话；重启前务必导出。App 被强制结束后的临时素材需手动恢复。

本地 IPC 使用 Unix socket，目录权限 0700、socket 0600，并校验对端 UID。不开放网络端口；同一 macOS 用户下的进程可以控制 App。录屏权限仍受系统 TCC 控制。开发构建默认使用 ad-hoc 签名，升级仍可能重新要求授权。安装公司证书后，用 `IRECORD_SIGN_IDENTITY="Apple Development: …" ./scripts/build_app.sh release` 构建；同一 bundle ID 和稳定签名可保留 TCC 授权。CLI 可用 `irecord permission request` 触发首次授权入口，但 macOS 权限选择仍需用户完成。

## 验证

```sh
# 使用 Xcode 的 XCTest（仅 Command Line Tools 不包含 XCTest）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ControlProtocolTests
python3 scripts/test_cli.py
# 已授权且空闲时，指定一个窗口做真实录制/导出测试；测试视频会清理。
python3 scripts/test_cli.py --window-id 123
```
