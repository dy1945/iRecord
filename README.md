# iRecord

**English** · [简体中文](README.zh-CN.md)

A native macOS screen recorder rebuilt from scratch in Swift for **high video-output performance**.

Where the original Kap is an Electron app that pipes frames through `ffmpeg`,
iRecord uses Apple's modern native stack so captured GPU surfaces flow straight
into the hardware video encoder with no intermediate copies:

```
ScreenCaptureKit (SCStream, IOSurface-backed BGRA frames)
        │  zero-copy CMSampleBuffer
        ▼
AVAssetWriter + VideoToolbox  →  hardware H.264 / HEVC  →  .mp4 / .mov
                                                         └→ ImageIO → .gif
```

## The Kap flow

iRecord follows Kap's two-phase model:

1. **Before recording — a floating capture toolbar.** Choosing "Select Area" dims
   every display and shows a draggable selection with a floating toolbar:
   **crop · window · ● record · fullscreen · ⋯** (the ⋯ menu holds cursor / clicks
   / audio / mic / capture-FPS toggles). You frame the shot, then press the big red
   button to start.
2. **After recording — an export editor.** Recording captures a high-quality
   intermediate; when you stop, an editor window opens with a video preview,
   **trimming**, and a bottom bar to choose the **output parameters** — Size (W×H),
   scale %, FPS, format (MP4 H264 / MP4 HEVC / MOV / GIF), and destination
   (Save to File… / Copy to Clipboard) — then **Convert**.

## Features (Kap core parity)

- **Capture targets**: full display, drag-to-select a custom **area** (dimmed
  overlay + floating capture toolbar), or pick a specific **application window**.
- **High-performance capture**: hardware-accelerated H.264 via VideoToolbox, fed
  directly from ScreenCaptureKit's IOSurface frames — sustains 60 fps on Retina.
- **Post-record export** (`ExportEngine`): trim + resize + frame-rate + format
  re-encode via `AVAssetExportSession` (H.264/HEVC) and ImageIO (GIF).
- **Output formats**: MP4 (H.264/HEVC), MOV, animated **GIF**.
- **Trimming**: native QuickTime-style trim handles in the editor preview.
- **Audio**: system audio (macOS 13+) and **microphone** (macOS 15 SCStream mic path).
- **Cursor & clicks**: optional cursor capture, plus **click highlighting** — an
  animated ripple is drawn at every mouse click and composited into the recording.
- **Configurable save location**: choose any output folder (defaults to `~/Movies`).
- **Controls**: start / **pause** / resume / stop; the menu-bar icon turns **red**
  with a live timer while recording.
- **Menu-bar app**: runs as an accessory (no Dock icon).

> Intentionally **excluded**: Kap's plugin architecture (per the project goal).

## Requirements

- macOS 13.0+ (built and verified on macOS 15.7).
- Swift toolchain (Command Line Tools are sufficient — **full Xcode not required**).

## Build & Run

```bash
./scripts/build_app.sh            # release build → build/iRecord.app
./scripts/build_app.sh release run  # build and launch
open build/iRecord.app
```

On first launch, grant **Screen Recording** permission in
*System Settings ▸ Privacy & Security ▸ Screen Recording* (and **Microphone** if
you enable mic capture), then relaunch.

## Verify the pipeline (headless)

A built-in self-test records the main display and validates the output file —
no UI or clicking required:

```bash
# Capture pipeline (records the main display, validates the file):
./build/iRecord.app/Contents/MacOS/iRecord --selftest 2 60 h264

# Export pipeline (records ~2s, then trims to 1s + halves size + 30fps + re-encodes):
./build/iRecord.app/Contents/MacOS/iRecord --exporttest mp4
./build/iRecord.app/Contents/MacOS/iRecord --exporttest hevc
./build/iRecord.app/Contents/MacOS/iRecord --exporttest gif

# Window enumeration:
./build/iRecord.app/Contents/MacOS/iRecord --listwindows
```

Each prints the resulting file's dimensions/duration/size and exits `0` on PASS.
(The terminal running it must have Screen Recording permission, **and the display
must be awake** — ScreenCaptureKit reports no displays while the screen is asleep.)

Verified results on this machine (3456×2234 Retina display):

| Test          | Output                                  | Verifies                    |
|---------------|-----------------------------------------|-----------------------------|
| selftest h264 | 3456×2234, ~1.5 MB/s, 60 fps            | hardware capture path       |
| exporttest mp4| trimmed 2s→1.00s, 1728×1116, 30fps      | trim + resize + fps re-encode|
| exporttest hevc| same, ~40% smaller than H.264          | HEVC export                 |
| exporttest gif| 26 frames                               | GIF export with trim        |

## Project layout

```
Sources/iRecord/
  AppMain.swift                  Menu-bar app entry, status item + popover, --selftest
  Recording/
    RecordingConfiguration.swift Codec / format / target / fps model
    RecordingController.swift     ObservableObject: settings, state, timer, file output
  Capture/
    ScreenRecorder.swift          SCStream → AVAssetWriter hardware-encode engine
  Export/
    ExportEngine.swift            Trim + resize + fps + format re-encode (post-record)
    GIFExporter.swift             AVAssetImageGenerator + ImageIO GIF writer (with trim)
  Permissions/
    PermissionsManager.swift      Screen Recording + Microphone TCC handling
  UI/
    AreaSelectionController.swift Dimmed overlay + floating capture toolbar (pre-record)
    ExportEditorWindow.swift      Post-record editor: preview, trim, output params, Convert
    ClickHighlighter.swift        Animated click ripples captured into the video
    ControlPanelView.swift        SwiftUI menu-bar popover (targets, window picker, capture settings)
    AppCoordinator.swift          Permission flow + area/window pickers + opens editor on finish
  Support/
    ScreenInfo.swift              Display enumeration + coordinate conversion
    SelfTest.swift                Headless capture + export pipeline verification
Resources/Info.plist             Bundle metadata, LSUIElement, usage strings
scripts/build_app.sh             SPM build + .app assembly + ad-hoc codesign
```

## Performance notes

- Frames are captured as **IOSurface-backed BGRA** and appended directly to the
  encoder input — no CPU pixel copies, no format conversion on the hot path.
- `AVVideoAverageBitRateKey` is derived from resolution × fps (≈0.1 bpp, clamped),
  tuned for sharp screen content; override via `RecordingConfiguration.bitrate`.
- `expectsMediaDataInRealTime = true` keeps the writer pacing with live capture.
- Keyframe interval is 2 s; frame reordering enabled for better compression.
