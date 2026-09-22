# iRecord

**English** · [简体中文](README.zh-CN.md)

A native macOS screen recorder rebuilt from scratch in Swift for **high video-output performance**.

Where the original  is an Electron app that pipes frames through `ffmpeg`,
iRecord uses Apple's modern native stack so captured GPU surfaces flow straight
into the hardware video encoder with no intermediate copies:

```
ScreenCaptureKit (SCStream, IOSurface-backed BGRA frames)
        │  zero-copy CMSampleBuffer
        ▼
AVAssetWriter + VideoToolbox  →  hardware H.264 / HEVC  →  .mp4 / .mov
                                                         └→ ImageIO → .gif
```

## The iRecord flow

iRecord follows iRecord's two-phase model:

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

## Features (iRecord core parity)

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

## Screenshots (iShot-style)

A full screenshot suite modelled on iShot lives next to the recorder:

- **Region screenshot** — freezes every display, with a visible arrow cursor,
  full-screen guide lines and a live `W × H` readout. Resize a selection from
  its edges or drag inside it to move it. The floating toolbar offers
  **annotations · long screenshot · pin · OCR · copy · save · cancel**.
  Keys: **Enter** copy · **Space** save · **S** scrolling · **T** pin ·
  **R / H** copy pixel RGB / HEX · **Esc** discard. Double-click inside or
  outside the selected area to copy the screenshot, including annotations,
  and exit with a confirmation toast. When local saving is enabled, the same
  image is also saved to the configured folder. An accidental single click
  outside the selection keeps the screenshot open.
- **Scrolling screenshot (长截图)** — pick the scrollable region, then scroll
  (wheel / trackpad / auto-scroll button). Frames are captured ~6×/s and
  stitched pixel-accurately by template matching — works in *any* app, not
  just browsers. A live preview grows beside the region; Enter finishes,
  no-movement auto-stops, horizontal scroll aborts. The result opens in the
  annotation editor.
- **Annotation editor (截屏编辑)** — line · arrow · rectangle · ellipse ·
  numbered marker · **mosaic** (pixel-block) · text, with ⌘Z undo.
  The screenshot toolbar uses one colour button; its popup offers five preset
  colours and **Small (20 pt) / Large (30 pt)** text sizes. Flattened output
  can be saved, copied or pinned.
- **OCR** — extracts Chinese and English text from the original frozen
  selection using Apple Vision, without annotation interference. Results
  preserve line breaks and can be edited before **Copy All**. If no text is
  recognized, select the region again.
- **Pin (贴图)** — floats the shot always-on-top: drag to move, scroll to
  zoom, hover for close button + opacity slider, right-click menu (Annotate /
  Copy / Save / Close), double-click or Esc closes. Because pins are ordinary
  on-screen pixels, the next screenshot captures them — iShot's **二次截屏**.
  Right-click ▸ Annotate reopens the editor and bakes the result back into
  the pin (**二次标注**). A hotkey pins the clipboard image; another hides /
  shows all pins.
- **Hotkeys** (all remappable in the panel's Shortcuts screen): region
  screenshot ⌘E · scrolling ⌃⌘S · pin clipboard ⌃⌘V · hide/show pins ⌃⌘H ·
  full-screen-to-clipboard (unbound by default). If another screenshot app is
  running it may already own a combo — iRecord logs failed registrations to
  Console so you can rebind.

Headless checks: `--stitchtest` (synthetic page → stitch engine must rebuild
it pixel-exactly) and `--shottest` (freeze displays, crop, write a PNG).

> Intentionally **excluded**: iRecord's plugin architecture (per the project goal).

## Command-line control

The App includes an `irecord` CLI for Agent-driven window recording. Install it
from **General Settings → Command-line Tools**, then run `irecord -h`.
Commands cover window search and preview, start, pause, resume and stop, with
JSON results. Recordings follow the App's save directory; `--crop-points` can
remove browser chrome, and `--max-edge` controls output size.
See the [CLI installation and usage guide (简体中文)](docs/CLI.zh-CN.md).

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

# Screenshot pipelines:
./build/iRecord.app/Contents/MacOS/iRecord --shottest    # freeze displays → crop → PNG
./build/iRecord.app/Contents/MacOS/iRecord --stitchtest  # scrolling-stitch engine (synthetic page)
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
  Screenshot/
    ScreenshotCapture.swift       Still capture: freeze displays, region crop, live rect capture
    ScreenshotOverlayController.swift Frozen-screen selection overlay (resize, guides, toolbar, OCR)
    ScreenshotEditorWindow.swift  Annotation editor (line/arrow/rect/marker/mosaic/text, undo)
    PinWindow.swift               Always-on-top pinned images (贴图, zoom/opacity/二次标注)
    ScrollingCaptureController.swift Scrolling capture loop, HUD, live preview
    ImageStitcher.swift           Template-match vertical stitcher for 长截图
  Support/
    ScreenInfo.swift              Display enumeration + coordinate conversion
    SelfTest.swift                Headless capture + export pipeline verification
Resources/Info.plist             Bundle metadata, LSUIElement, usage strings
Resources/AppIcon.icns           App icon (regenerate with scripts/render_icon.sh)
Resources/Icon/                  Icon source: AppIcon.svg master, variants/, showcase.html
scripts/build_app.sh             SPM build + .app assembly + ad-hoc codesign
scripts/render_icon.sh           Render icon SVG → multi-resolution .icns (headless Chrome)
```

## Performance notes

- Frames are captured as **IOSurface-backed BGRA** and appended directly to the
  encoder input — no CPU pixel copies, no format conversion on the hot path.
- `AVVideoAverageBitRateKey` is derived from resolution × fps (≈0.1 bpp, clamped),
  tuned for sharp screen content; override via `RecordingConfiguration.bitrate`.
- `expectsMediaDataInRealTime = true` keeps the writer pacing with live capture.
- Keyframe interval is 2 s; frame reordering enabled for better compression.
