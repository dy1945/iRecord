# iRecord

[English](README.md) · **简体中文**

一款原生 macOS 录屏工具，用 Swift 从零重写，主打**高性能视频输出**。

Kap 本身是一个 Electron 应用，通过 `ffmpeg` 转码帧数据；而 iRecord 使用 Apple 现代原生技术栈，让捕获到的 GPU 画面直接进入硬件视频编码器，全程**零中间拷贝**：

```
ScreenCaptureKit（SCStream，IOSurface 承载的 BGRA 帧）
        │  零拷贝 CMSampleBuffer
        ▼
AVAssetWriter + VideoToolbox  →  硬件 H.264 / HEVC  →  .mp4 / .mov
                                                     └→ ImageIO → .gif
```

## Kap 式工作流

iRecord 沿用 Kap 的两阶段模型：

1. **录制前 —— 悬浮捕获工具栏。** 选择「选取区域」后，所有显示器会变暗，出现一个可拖拽的选区和悬浮工具栏：**裁剪 · 窗口 · ● 录制 · 全屏 · ⋯**（⋯ 菜单包含光标 / 点击高亮 / 系统音 / 麦克风 / 捕获帧率开关）。框好画面后，按下大红按钮开始录制。
2. **录制后 —— 导出编辑器。** 录制时会先保存一份高质量的中间文件；停止后会打开一个编辑器窗口，提供视频预览、**裁剪（trim）**，以及底部用于选择**输出参数**的工具栏 —— 尺寸（宽×高）、缩放百分比、帧率、格式（MP4 H264 / MP4 HEVC / MOV / GIF）和去向（保存到文件… / 复制到剪贴板），然后点击**转换（Convert）**。

## 功能特性（对齐 Kap 核心）

- **捕获目标**：整个显示器、拖拽框选**自定义区域**（变暗遮罩 + 悬浮捕获工具栏），或选取指定的**应用窗口**。
- **高性能捕获**：通过 VideoToolbox 进行硬件加速 H.264 编码，直接喂入 ScreenCaptureKit 的 IOSurface 帧 —— 在 Retina 屏上可稳定 60 fps。
- **录制后导出**（`ExportEngine`）：通过 `AVAssetExportSession`（H.264/HEVC）和 ImageIO（GIF）进行裁剪 + 缩放 + 帧率 + 格式的重编码。
- **输出格式**：MP4（H.264/HEVC）、MOV、动态 **GIF**。
- **裁剪**：编辑器预览中提供原生 QuickTime 风格的裁剪手柄。
- **音频**：系统音频（macOS 13+）与**麦克风**（macOS 15 的 SCStream 麦克风通道）。
- **光标与点击**：可选的光标捕获，外加**点击高亮** —— 每次鼠标点击都会绘制一圈动画涟漪并合成进录像。
- **可配置保存位置**：可选择任意输出文件夹（默认 `~/Movies`）。
- **录制控制**：开始 / **暂停** / 继续 / 停止；录制时菜单栏图标变**红**并显示实时计时。
- **菜单栏应用**：以辅助程序方式运行（无 Dock 图标）。

> 有意**排除**的内容：Kap 的插件架构（这是项目目标决定的）。

## 系统要求

- macOS 13.0+（在 macOS 15.7 上构建并验证）。
- Swift 工具链（Command Line Tools 即可 —— **无需完整 Xcode**）。

## 构建与运行

```bash
./scripts/build_app.sh              # release 构建 → build/iRecord.app
./scripts/build_app.sh release run  # 构建并启动
open build/iRecord.app
```

首次启动时，请在*系统设置 ▸ 隐私与安全性 ▸ 屏幕录制*中授予**屏幕录制**权限（如果启用麦克风捕获，还需授予**麦克风**权限），然后重新启动应用。

## 验证流水线（无界面）

内置的自检会录制主显示器并校验输出文件 —— 无需界面或点击操作：

```bash
# 捕获流水线（录制主显示器并校验文件）：
./build/iRecord.app/Contents/MacOS/iRecord --selftest 2 60 h264

# 导出流水线（录制约 2 秒，然后裁剪到 1 秒 + 尺寸减半 + 30fps + 重编码）：
./build/iRecord.app/Contents/MacOS/iRecord --exporttest mp4
./build/iRecord.app/Contents/MacOS/iRecord --exporttest hevc
./build/iRecord.app/Contents/MacOS/iRecord --exporttest gif

# 窗口枚举：
./build/iRecord.app/Contents/MacOS/iRecord --listwindows
```

每项都会打印结果文件的尺寸/时长/大小，PASS 时以退出码 `0` 结束。
（运行它的终端必须拥有屏幕录制权限，**且显示器必须处于唤醒状态** —— 屏幕休眠时 ScreenCaptureKit 会报告没有可用显示器。）

本机上的验证结果（3456×2234 Retina 显示器）：

| 测试            | 输出                                    | 验证内容                     |
|-----------------|-----------------------------------------|------------------------------|
| selftest h264   | 3456×2234，约 1.5 MB/s，60 fps          | 硬件捕获通道                 |
| exporttest mp4  | 裁剪 2s→1.00s，1728×1116，30fps         | 裁剪 + 缩放 + 帧率重编码     |
| exporttest hevc | 同上，比 H.264 小约 40%                 | HEVC 导出                    |
| exporttest gif  | 26 帧                                   | 带裁剪的 GIF 导出            |

## 项目结构

```
Sources/iRecord/
  AppMain.swift                  菜单栏应用入口，状态项 + 弹出框，--selftest
  Recording/
    RecordingConfiguration.swift 编解码器 / 格式 / 目标 / 帧率 模型
    RecordingController.swift     ObservableObject：设置、状态、计时器、文件输出
  Capture/
    ScreenRecorder.swift          SCStream → AVAssetWriter 硬件编码引擎
  Export/
    ExportEngine.swift            裁剪 + 缩放 + 帧率 + 格式重编码（录制后）
    GIFExporter.swift             AVAssetImageGenerator + ImageIO GIF 写入（带裁剪）
  Permissions/
    PermissionsManager.swift      屏幕录制 + 麦克风 TCC 处理
  UI/
    AreaSelectionController.swift 变暗遮罩 + 悬浮捕获工具栏（录制前）
    ExportEditorWindow.swift      录制后编辑器：预览、裁剪、输出参数、转换
    ClickHighlighter.swift        合成进视频的点击动画涟漪
    ControlPanelView.swift        SwiftUI 菜单栏弹出框（目标、窗口选择、捕获设置）
    AppCoordinator.swift          权限流程 + 区域/窗口选择器 + 完成后打开编辑器
  Support/
    ScreenInfo.swift              显示器枚举 + 坐标转换
    SelfTest.swift                无界面的捕获 + 导出流水线验证
Resources/Info.plist             Bundle 元数据、LSUIElement、用途说明字符串
scripts/build_app.sh             SPM 构建 + .app 组装 + ad-hoc 代码签名
```

## 性能说明

- 帧以 **IOSurface 承载的 BGRA** 形式捕获，直接追加到编码器输入 —— 热路径上没有 CPU 像素拷贝，也没有格式转换。
- `AVVideoAverageBitRateKey` 由分辨率 × 帧率推导得出（约 0.1 bpp，带钳制），针对清晰的屏幕内容做了调优；可通过 `RecordingConfiguration.bitrate` 覆盖。
- `expectsMediaDataInRealTime = true` 让写入器与实时捕获保持节奏同步。
- 关键帧间隔为 2 秒；启用帧重排序以获得更好的压缩率。
