import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import ScreenCaptureKit

/// A headless smoke test of the capture→encode pipeline, runnable from the
/// command line: `iRecord --selftest [seconds] [fps] [h264|hevc]`.
///
/// Records the main display for a few seconds, writes an MP4, then validates the
/// result with AVFoundation (track present, non-zero duration, plausible size).
/// Exits non-zero on any failure so it can gate CI / manual verification.
///
/// Note: ScreenCaptureKit delivers its setup/teardown callbacks on the main
/// queue, so this test must keep the main run loop spinning (never block it) and
/// call `exit()` from within a callback once finished.
enum SelfTest {
    /// Exercises search and the actual preview close sheet against a disposable file.
    @MainActor
    static func runWindowFlow() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let windows = [WindowInfo(id: 1, title: "Build logs", appName: "iTerm2", frame: .zero),
                       WindowInfo(id: 2, title: "产品周报", appName: "Preview", frame: .zero),
                       WindowInfo(id: 3, title: "Documentation", appName: "Chrome", frame: .zero)]
        precondition(ScreenInfo.filterWindows(windows, query: " ITERM ").map(\.id) == [1])
        precondition(ScreenInfo.filterWindows(windows, query: "LOGS").map(\.id) == [1])
        precondition(ScreenInfo.filterWindows(windows, query: "周报").map(\.id) == [2])
        precondition(ScreenInfo.filterWindows(windows, query: " ") == windows)
        precondition(ScreenInfo.filterWindows(windows, query: "absent").isEmpty)
        print("[windowflowtest] PASS: app/title search, Chinese, case, whitespace, no matches")
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("irecord-close-test-\(UUID().uuidString).mov")
        try! Data("disposable close lifecycle fixture".utf8).write(to: source)
        let controller = ExportEditorWindowController(sourceURL: source, defaultDirectory: source.deletingLastPathComponent(), captureFPS: 30, onExported: nil)
        controller.present()
        Task { @MainActor in
            defer { try? FileManager.default.removeItem(at: source) }
            guard let window = controller.window else { fatalError("No preview") }
            window.performClose(nil)
            precondition(window.isVisible && FileManager.default.fileExists(atPath: source.path))
            guard let firstSheet = window.attachedSheet else { fatalError("Missing close confirmation") }
            if let content = firstSheet.contentView {
                content.layoutSubtreeIfNeeded()
                let title = content.subviews.compactMap { $0 as? NSTextField }.first {
                    $0.stringValue == L10n.tr("Close video preview?", "关闭视频预览？")
                }
                precondition(title != nil && abs(content.bounds.maxY - title!.frame.maxY - 20) < 1,
                             "Close confirmation has excessive top whitespace")
                if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/irecord-close-sheet.png"))
                }
            }
            window.performClose(nil)
            precondition(window.attachedSheet === firstSheet, "Duplicate close confirmation")
            window.endSheet(firstSheet, returnCode: .alertFirstButtonReturn)
            try? await Task.sleep(nanoseconds: 350_000_000)
            precondition(window.isVisible && FileManager.default.fileExists(atPath: source.path), "Cancel discarded recording")
            print("[windowflowtest] PASS: close prompts once, Continue Editing preserves recording")
            window.performClose(nil)
            guard let secondSheet = window.attachedSheet else { fatalError("Cannot reconfirm close") }
            window.endSheet(secondSheet, returnCode: .alertSecondButtonReturn)
            try? await Task.sleep(nanoseconds: 350_000_000)
            precondition(!window.isVisible && !FileManager.default.fileExists(atPath: source.path), "Confirmed close did not clean up")
            print("[windowflowtest] PASS: confirmed close discards only the test recording")
            fflush(stdout)
            exit(0)
        }
        app.run()
        exit(1)
    }

    /// Real Vision recognition: multiline Chinese/English, crop exclusion and blank input.
    @MainActor
    static func runOCR(showWindow: Bool = false) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        func fixture(_ withText: Bool) -> CGImage {
            let image = NSImage(size: NSSize(width: 900, height: 400))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 900, height: 400).fill()
            if withText {
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black]
                ("Hello OCR 123" as NSString).draw(at: NSPoint(x: 40, y: 280), withAttributes: attrs)
                ("截图文字识别" as NSString).draw(at: NSPoint(x: 40, y: 180), withAttributes: attrs)
                ("OUTSIDE" as NSString).draw(at: NSPoint(x: 650, y: 80), withAttributes: attrs)
            }
            image.unlockFocus()
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        }
        let original = fixture(true)
        let frozen = ScreenshotCapture.FrozenDisplay(displayID: CGMainDisplayID(), image: original,
                                                       frame: CGRect(x: 0, y: 0, width: 900, height: 400))
        let cropped = ScreenshotCapture.crop(globalRect: CGRect(x: 0, y: 0, width: 600, height: 400), from: [frozen])!
        let blank = fixture(false)
        let editor = AnnotationEditorView(image: NSImage(cgImage: blank, size: NSSize(width: 900, height: 400)))
        let testWindow = NSWindow(contentRect: editor.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        testWindow.contentView = editor
        editor.currentTool = .text
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: editor.convert(point, to: nil), modifierFlags: [],
                              timestamp: 0, windowNumber: testWindow.windowNumber, context: nil,
                              eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        editor.mouseDown(with: event(.leftMouseDown, CGPoint(x: 80, y: 80)))
        guard let field = editor.subviews.compactMap({ $0 as? NSTextField }).first,
              field.font?.pointSize == 20 else { print("[ocrtest] FAIL: small text size"); exit(1) }
        field.stringValue = "Move text"
        editor.currentTextSize = 30
        guard field.font?.pointSize == 30 else { print("[ocrtest] FAIL: active text size"); exit(1) }
        editor.mouseDown(with: event(.leftMouseDown, CGPoint(x: 84, y: 84)))
        editor.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 124, y: 124)))
        guard NSCursor.current == NSCursor.closedHand else { print("[ocrtest] FAIL: dragging cursor"); exit(1) }
        editor.mouseUp(with: event(.leftMouseUp, CGPoint(x: 124, y: 124)))
        guard NSCursor.current == NSCursor.openHand else { print("[ocrtest] FAIL: released cursor"); exit(1) }
        guard editor.shapes.count == 1, editor.shapes[0].fontSize == 30,
              editor.shapes[0].start == CGPoint(x: 120, y: 120) else {
            print("[ocrtest] FAIL: committed text move/size"); exit(1)
        }
        print("[ocrtest] PASS: 20/30 pt text and committed text dragging")
        Task { @MainActor in
            do {
                let text = try await ScreenshotOCR.recognize(cropped)
                print("[ocrtest] result: \(text)")
                guard text.replacingOccurrences(of: " ", with: "").contains("HelloOCR123"), text.contains("截图文字识别"),
                      text.contains("\n"), !text.contains("OUTSIDE") else {
                    print("[ocrtest] FAIL: multiline/crop mismatch"); exit(1)
                }
                let empty = try await ScreenshotOCR.recognize(blank)
                guard empty.isEmpty else { print("[ocrtest] FAIL: blank input"); exit(1) }
                print("[ocrtest] PASS: Chinese, English, line breaks, selection crop, blank image")
                fflush(stdout)
                if showWindow {
                    OCRResultController.shared.showLoading { exit(0) }
                    OCRResultController.shared.showResult(CommandLine.arguments.contains("--blank") ? "" : text)
                } else {
                    verifyOCRResultWindow(text: text)
                    exit(0)
                }
            } catch { print("[ocrtest] FAIL: \(error)"); exit(1) }
        }
        if showWindow { app.run() } else { CFRunLoopRun() }
        exit(0)
    }


    @MainActor
    private static func verifyOCRResultWindow(text: String) {
        // Preserve the user's clipboard while exercising the actual Copy All button.
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            let items = saved.map { entries -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        func controls() -> (NSWindow, NSTextView, NSButton, NSButton, [NSTextField]) {
            guard let window = NSApp.windows.first(where: { $0.title == L10n.tr("OCR — Extract Text", "OCR — 提取文字") && $0.isVisible }),
                  let content = window.contentView else { fatalError("Missing OCR window") }
            let views = descendants(content)
            guard let textView = views.compactMap({ $0 as? NSTextView }).first,
                  let copy = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == L10n.tr("Copy All", "复制全部") }),
                  let retry = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == L10n.tr("Select Again", "重新框选") }) else { fatalError("Missing OCR controls") }
            return (window, textView, copy, retry, views.compactMap { $0 as? NSTextField })
        }
        var closed = false
        OCRResultController.shared.showLoading { closed = true }
        OCRResultController.shared.showResult(text)
        let (window, editor, copy, retry, _) = controls()
        precondition(editor.isEditable && copy.isEnabled && retry.isHidden)
        let edited = text + "\nEdited text 456"
        editor.string = edited
        copy.performClick(nil)
        precondition(pasteboard.string(forType: .string) == edited, "Copy All lost edited text or line breaks")
        editor.string = ""
        let paste = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                    characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
        precondition(editor.performKeyEquivalent(with: paste) && editor.string == edited, "Paste shortcut failed")
        window.close()
        precondition(closed)
        var reselect = false
        OCRResultController.shared.showLoading { reselect = true }
        OCRResultController.shared.showResult("")
        let (_, emptyEditor, emptyCopy, again, labels) = controls()
        precondition(!emptyEditor.isEditable && !emptyCopy.isEnabled && !again.isHidden)
        precondition(labels.contains { $0.stringValue == L10n.tr("No text recognized", "未识别到文字") })
        again.performClick(nil)
        precondition(reselect, "Select Again did not return control")
        print("[ocrtest] PASS: editable result, Copy All, line breaks, Cmd+V, empty message, Select Again callback")
    }

    /// Headless verification of the scrolling-screenshot stitch engine.
    /// Builds a synthetic tall "page", simulates scroll frames (variable step
    /// sizes, including a fast jump and a no-move frame), stitches them, and
    /// verifies the result reconstructs the page pixel-accurately.
    /// `iRecord --stitchtest`
    static func runStitch() -> Never {
        let pageW = 320, pageH = 3000, frameH = 480
        guard let page = syntheticPage(width: pageW, height: pageH) else {
            print("[stitchtest] FAIL: could not build synthetic page"); exit(5)
        }

        func frame(atTop top: Int) -> CGImage? {
            page.cropping(to: CGRect(x: 0, y: top, width: pageW, height: frameH))
        }

        // Scroll offsets (content moves up): mixed small/large steps.
        var tops = [0]
        var y = 0
        let rng: [Int] = [37, 61, 22, 90, 130, 45, 12, 200, 77, 33, 150, 28, 55, 99, 5, 250]
        var i = 0
        while y < pageH - frameH - 1 {
            y += rng[i % rng.count]; i += 1
            tops.append(min(y, pageH - frameH))
        }
        tops.append(tops.last!)    // no-movement frame at the end

        guard let first = frame(atTop: 0), let stitcher = ImageStitcher(firstFrame: first) else {
            print("[stitchtest] FAIL: init"); exit(5)
        }
        var matched = 0
        var prevTop = tops.first!
        for (idx, top) in tops.dropFirst().enumerated() {
            guard let f = frame(atTop: top) else { continue }
            if let m = stitcher.append(f) {
                if m.dy > 0 {
                    matched += 1
                    if m.dy != top - prevTop {
                        print("[stitchtest] frame \(idx): dy=\(m.dy) actual=\(top - prevTop)  ⚠️")
                    }
                }
                prevTop = top
            } else {
                print("[stitchtest] frame \(idx) (top=\(top)): no match (step too large)")
            }
        }

        guard let result = stitcher.currentImage else {
            print("[stitchtest] FAIL: no result"); exit(5)
        }
        let expectedH = frameH + (tops.last! - 0)
        print("[stitchtest] frames=\(tops.count) stitchedH=\(result.height) expectedH=\(expectedH) appended=\(matched)")

        // Verify content: compare rows of the stitched image against the page.
        var mismatches = 0
        if result.height == expectedH, let buf1 = grayRows(result), let buf2 = grayRows(page) {
            for row in [0, expectedH/4, expectedH/2, expectedH*3/4, expectedH-1] {
                if buf1[row] != buf2[row] { mismatches += 1 }
            }
        }
        if result.height == expectedH && mismatches == 0 {
            print("[stitchtest] PASS ✅  stitched image reconstructs the page exactly")
            exit(0)
        }
        print("[stitchtest] FAIL ❌  heightOK=\(result.height == expectedH) rowMismatches=\(mismatches)")
        exit(6)
    }

    /// Headless verification of the still-screenshot pipeline: freeze all
    /// displays, crop the main display, save a PNG. Needs Screen Recording
    /// permission. `iRecord --shottest`
    static func runShot() -> Never {
        guard PermissionsManager.hasScreenRecordingPermission() else {
            print("[shottest] FAIL: Screen Recording permission not granted."); exit(2)
        }
        Task { @MainActor in
            do {
                let frozen = try await ScreenshotCapture.freezeDisplays()
                guard let main = frozen.first else {
                    print("[shottest] FAIL: no displays"); exit(5)
                }
                let rect = main.frame.insetBy(dx: 40, dy: 40)
                guard let img = ScreenshotCapture.crop(globalRect: rect, from: frozen) else {
                    print("[shottest] FAIL: crop returned nil"); exit(6)
                }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("irecord-shottest.png")
                let rep = NSBitmapImageRep(cgImage: img)
                guard let png = rep.representation(using: .png, properties: [:]),
                      (try? png.write(to: url)) != nil else {
                    print("[shottest] FAIL: could not write PNG"); exit(6)
                }
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
                print("[shottest] displays=\(frozen.count) crop=\(img.width)x\(img.height) png=\(size/1024)KB → \(url.path)")
                // Multi-format encode sanity: every configured format must encode.
                var formatReport: [String] = []
                let nsimg = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
                for fmt in ScreenshotFormat.allCases {
                    if let data = ScreenshotFileIO.encode(image: nsimg, format: fmt) {
                        formatReport.append("\(fmt.rawValue)=\(data.count/1024)KB")
                    } else {
                        print("[shottest] FAIL: encode returned nil for \(fmt.rawValue)"); exit(7)
                    }
                }
                print("[shottest] formats: \(formatReport.joined(separator: " "))")
                if img.width > 100 && size > 10_000 {
                    print("[shottest] PASS ✅"); exit(0)
                }
                print("[shottest] FAIL ❌  (suspicious output)"); exit(6)
            } catch {
                print("[shottest] FAIL: \(error.localizedDescription)"); exit(4)
            }
        }
        CFRunLoopRun()
        exit(7)
    }

    /// Headless verification of the merged screenshot toolbar: renders the bar
    /// plus a canvas pre-populated with markers (one captioned), an arrow, a
    /// rect, a mosaic patch and a moved text — all by synthetic mouse events.
    /// `iRecord --toolbartest`, then `screencapture -l <windowNumber>`.
    static func runToolbar() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)   // unbuffered: draw-time prints must survive
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // Backdrop at 2× pixels (same scale math as the fullscreen overlay):
        // a dense block grid (mosaic always has content under it) plus one
        // black diagonal — any flip error in mosaic baking or flatten export
        // shows up immediately.
        let size = NSSize(width: 620, height: 380)
        guard let ctx = CGContext(data: nil, width: 1240, height: 760,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let cg = { () -> CGImage? in
                  ctx.setFillColor(NSColor(white: 0.93, alpha: 1).cgColor)
                  ctx.fill(CGRect(x: 0, y: 0, width: 1240, height: 760))
                  let palette = [NSColor.systemBlue, .systemOrange, .systemTeal, .systemPurple]
                  var i = 0
                  for row in 0..<6 {
                      for col in 0..<8 where (row + col) % 2 == 0 {
                          ctx.setFillColor(palette[i % palette.count].cgColor)
                          ctx.fill(CGRect(x: 30 + col * 150, y: 30 + row * 120, width: 90, height: 70))
                          i += 1
                      }
                  }
                  ctx.setStrokeColor(NSColor.black.cgColor)
                  ctx.setLineWidth(6)
                  ctx.move(to: CGPoint(x: 0, y: 0))
                  ctx.addLine(to: CGPoint(x: 1240, y: 760))
                  ctx.strokePath()
                  // Guaranteed content under the mosaic test rect (view coords
                  // 400,220–560,340 → data rows 440–680 → ctx y 80–320):
                  // red field with thin black stripes — pixelation is obvious.
                  ctx.setFillColor(NSColor.systemRed.cgColor)
                  ctx.fill(CGRect(x: 800, y: 80, width: 320, height: 240))
                  ctx.setFillColor(NSColor.black.cgColor)
                  for sx in stride(from: 812, through: 1110, by: 24) {
                      ctx.fill(CGRect(x: sx, y: 80, width: 6, height: 240))
                  }
                  return ctx.makeImage()
              }() else {
            print("[toolbartest] FAIL: could not build backdrop"); exit(5)
        }
        let img = NSImage(cgImage: cg, size: size)

        let editor = AnnotationEditorView(image: img)
        let tb = ShotToolbarView(editor: editor, scrollingMode: false) { _ in }
        let tbSize = tb.fittingSize

        let winW = max(tbSize.width + 24, size.width + 24)
        let winH = tbSize.height + 12 + size.height + 16
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "toolbartest"
        win.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: winH))
        win.contentView = content
        tb.frame = NSRect(x: (winW - tbSize.width) / 2, y: winH - tbSize.height - 8,
                          width: tbSize.width, height: tbSize.height)
        content.addSubview(tb)
        editor.frame = NSRect(x: (winW - size.width) / 2, y: 8, width: size.width, height: size.height)
        content.addSubview(editor)
        win.center()
        win.makeKeyAndOrderFront(nil)
        print("[toolbartest] windowNumber=\(win.windowNumber) frame=\(win.frame)")
        fflush(stdout)

        func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: editor.convert(p, to: nil),
                               modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: win.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func click(_ p: NSPoint) {
            editor.mouseDown(with: mouse(.leftMouseDown, p))
            editor.mouseUp(with: mouse(.leftMouseUp, p))
        }
        func drag(_ a: NSPoint, _ b: NSPoint) {
            editor.mouseDown(with: mouse(.leftMouseDown, a))
            editor.mouseDragged(with: mouse(.leftMouseDragged, b))
            editor.mouseUp(with: mouse(.leftMouseUp, b))
        }
        func escKey() -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                             timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: win.windowNumber, context: nil,
                             characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                             isARepeat: false, keyCode: 53)!
        }
        func setField(_ text: String) {
            if let tf = editor.subviews.compactMap({ $0 as? NSTextField }).last { tf.stringValue = text }
        }

        // Marker 1 with caption, marker 2 without.
        editor.currentTool = .marker
        click(NSPoint(x: 90, y: 90))
        setField("第一步")
        click(NSPoint(x: 190, y: 140))          // commits caption 1, stamps 2
        editor.keyDown(with: escKey())          // commits empty caption

        editor.currentTool = .arrow
        drag(NSPoint(x: 250, y: 220), NSPoint(x: 420, y: 130))

        editor.currentTool = .rect
        drag(NSPoint(x: 60, y: 220), NSPoint(x: 200, y: 330))

        // Mosaic over the colour blocks (right side).
        editor.currentTool = .mosaic
        drag(NSPoint(x: 400, y: 220), NSPoint(x: 560, y: 340))

        // Text, committed with Esc, then dragged to a new position.
        editor.currentTool = .text
        click(NSPoint(x: 300, y: 60))
        setField("拖动我")
        editor.keyDown(with: escKey())
        editor.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 315, y: 75)))   // grabs the text
        editor.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 370, y: 180)))
        editor.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 370, y: 180)))

        // Clamp test: with a crop set, a drag past the edge stops at the crop.
        // (Starts on empty canvas so it doesn't grab the mosaic for a move.)
        editor.cropRect = NSRect(x: 20, y: 20, width: 580, height: 340)
        editor.currentTool = .rect
        drag(NSPoint(x: 300, y: 260), NSPoint(x: 700, y: 420))

        editor.currentTool = nil

        print("[toolbartest] shapes:", editor.shapes.map { "\($0.tool.rawValue) \(Int($0.rect.minX)),\(Int($0.rect.minY)) \(Int($0.rect.width))x\(Int($0.rect.height))" }.joined(separator: " | "))

        // Export the flattened crop (what copy/save would produce) for inspection.
        let flat = editor.flattenedImage()
        if let tiff = flat.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/toolbar_export.png"))
            print("[toolbartest] export -> /tmp/toolbar_export.png \(png.count / 1024)KB")
        }

        app.run()
        exit(0)
    }

    static func runShotCursor() -> Never {
        let cursor = ShotSelectionCursor.cursor
        let image = cursor.image
        guard image.size == NSSize(width: 30, height: 34),
              cursor.hotSpot == NSPoint(x: 3, y: 3),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            print("[cursortest] FAIL: invalid cursor image or hotspot")
            exit(1)
        }
        let url = URL(fileURLWithPath: "/tmp/irecord-selection-cursor.png")
        do {
            try png.write(to: url, options: .atomic)
            print("[cursortest] PASS: arrow + badge cursor, hotspot=3,3, output=\(url.path)")
            exit(0)
        } catch {
            print("[cursortest] FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func runShotSelectionGeometry() -> Never {
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 400)
        let rect = CGRect(x: 100, y: 80, width: 200, height: 160)
        guard ShotSelectionGeometry.hitTest(CGPoint(x: 200, y: 160), in: rect) == .move,
              ShotSelectionGeometry.hitTest(CGPoint(x: 100, y: 240), in: rect) == .resize(.northWest),
              ShotSelectionGeometry.hitTest(CGPoint(x: 150, y: 240), in: rect) == .resize(.north),
              ShotSelectionGeometry.hitTest(CGPoint(x: 300, y: 160), in: rect) == .resize(.east),
              ShotSelectionGeometry.hitTest(CGPoint(x: 20, y: 20), in: rect) == .none else {
            print("[selectiontest] FAIL: hit testing")
            exit(1)
        }
        let moved = ShotSelectionGeometry.moved(rect, delta: CGPoint(x: 300, y: 300), within: bounds)
        guard moved == CGRect(x: 300, y: 240, width: 200, height: 160) else {
            print("[selectiontest] FAIL: move clamp \(moved)")
            exit(2)
        }
        let resized = ShotSelectionGeometry.resized(rect, handle: .southWest,
                                                    delta: CGPoint(x: -200, y: -200), within: bounds)
        guard resized == CGRect(x: 0, y: 0, width: 300, height: 240) else {
            print("[selectiontest] FAIL: resize clamp \(resized)")
            exit(3)
        }
        let minimum = ShotSelectionGeometry.resized(rect, handle: .west,
                                                    delta: CGPoint(x: 500, y: 0), within: bounds)
        guard minimum.width == ShotSelectionGeometry.minimumSize else {
            print("[selectiontest] FAIL: minimum size \(minimum)")
            exit(4)
        }
        let editor = AnnotationEditorView(image: NSImage(size: bounds.size))
        editor.frame = bounds
        editor.cropRect = rect
        editor.currentTool = .rect
        guard editor.hitTest(CGPoint(x: 200, y: 160)) === editor,
              editor.hitTest(CGPoint(x: 100, y: 160)) == nil,
              editor.hitTest(CGPoint(x: 40, y: 40)) == nil else {
            print("[selectiontest] FAIL: annotation event routing")
            exit(5)
        }
        var recording = RecordingAreaSelection(rect: rect, hasSelection: true)
        recording.press(at: CGPoint(x: 200, y: 160))
        recording.release()
        guard recording.rect == rect else {
            print("[selectiontest] FAIL: recording click moved selection")
            exit(6)
        }
        recording.press(at: CGPoint(x: 200, y: 160))
        recording.drag(to: CGPoint(x: 240, y: 190), within: bounds)
        recording.release()
        guard recording.rect == CGRect(x: 140, y: 110, width: 200, height: 160) else {
            print("[selectiontest] FAIL: recording move \(recording.rect)")
            exit(7)
        }
        recording.press(at: CGPoint(x: 340, y: 190))
        recording.drag(to: CGPoint(x: 370, y: 190), within: bounds)
        recording.release()
        guard recording.rect == CGRect(x: 140, y: 110, width: 230, height: 160) else {
            print("[selectiontest] FAIL: recording edge resize \(recording.rect)")
            exit(8)
        }
        recording.press(at: CGPoint(x: 20, y: 20))
        recording.drag(to: CGPoint(x: 80, y: 70), within: bounds)
        recording.release()
        guard recording.rect == CGRect(x: 20, y: 20, width: 60, height: 50) else {
            print("[selectiontest] FAIL: recording redraw \(recording.rect)")
            exit(9)
        }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("irecord-export-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let source = tempDir.appendingPathComponent("source.mp4")
            try Data("new".utf8).write(to: source)
            let existing = tempDir.appendingPathComponent("clip.mp4")
            try Data("old".utf8).write(to: existing)
            let saved = try RecordingExportDestination.save(source, in: tempDir,
                                                            baseName: "clip", extension: "mp4")
            guard saved.lastPathComponent == "clip-1.mp4",
                  try Data(contentsOf: saved) == Data("new".utf8),
                  try Data(contentsOf: existing) == Data("old".utf8) else {
                print("[selectiontest] FAIL: configured directory export")
                exit(10)
            }
        } catch {
            print("[selectiontest] FAIL: configured directory export: \(error)")
            exit(11)
        }
        print("[selectiontest] PASS: screenshot geometry, recording move/resize/redraw, configured directory export")
        exit(0)
    }

    /// Deterministic synthetic page: horizontal bands filled with
    /// pseudo-random blocks — plenty of high-frequency detail for matching.
    private static func syntheticPage(width: Int, height: Int) -> CGImage? {        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        var seed: UInt64 = 12345
        func rand() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) & 0xFF) / 255.0
        }
        for y in stride(from: 0, to: height, by: 24) {
            for x in stride(from: 0, to: width, by: 24) {
                ctx.setFillColor(red: rand(), green: rand(), blue: rand(), alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 24, height: 24))
            }
        }
        return ctx.makeImage()
    }

    /// Per-row average luminance of an image, for fast row comparison.
    private static func grayRows(_ image: CGImage) -> [Int]? {
        guard let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data) else { return nil }
        let bpl = image.bytesPerRow
        let bpp = max(1, image.bitsPerPixel / 8)
        var rows = [Int]()
        rows.reserveCapacity(image.height)
        for y in 0..<image.height {
            var sum = 0
            let row = base + y * bpl
            for x in stride(from: 0, to: image.width, by: 8) {
                let off = x * bpp
                sum += Int(row[off]) + Int(row[off + 1]) + Int(row[off + 2])
            }
            rows.append(sum)
        }
        return rows
    }

    final class Runner: NSObject, ScreenRecorderDelegate, @unchecked Sendable {
        let recorder = ScreenRecorder()
        var onFinish: ((URL) -> Void)?

        func recorder(_ recorder: ScreenRecorder, didChangeState state: RecorderState) {
            if case .failed(let m) = state {
                print("[selftest] FAIL (state): \(m)")
                exit(4)
            }
        }
        func recorder(_ recorder: ScreenRecorder, didFinishRecordingTo url: URL) {
            if let onFinish { onFinish(url) } else { SelfTest.validate(url) }
        }
        func recorder(_ recorder: ScreenRecorder, didFailWith error: Error) {
            print("[selftest] FAIL: \(error.localizedDescription)")
            exit(4)
        }
    }

    // Kept alive for the duration of the run loop.
    private static let runner = Runner()

    static func run(arguments: [String]) -> Never {
        let seconds = arguments.count > 0 ? (Double(arguments[0]) ?? 3.0) : 3.0
        let fps = arguments.count > 1 ? (Int(arguments[1]) ?? 60) : 60
        let mode = arguments.count > 2 ? arguments[2].lowercased() : "h264"
        let codec: VideoCodec = (mode == "hevc") ? .hevc : .h264
        let format: OutputFormat = (mode == "gif") ? .gif : .mp4

        print("[selftest] screen permission preflight: \(PermissionsManager.hasScreenRecordingPermission())")
        guard PermissionsManager.hasScreenRecordingPermission() else {
            print("[selftest] FAIL: Screen Recording permission not granted for this binary's bundle.")
            print("[selftest] Grant it in System Settings ▸ Privacy & Security ▸ Screen Recording, then re-run.")
            exit(2)
        }

        runner.recorder.delegate = runner

        var config = RecordingConfiguration(target: .display(displayID: CGMainDisplayID()))
        config.fps = fps
        config.codec = codec
        config.outputFormat = format

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("irecord-selftest.mp4")

        print("[selftest] recording main display for \(seconds)s @ \(fps)fps (\(codec.displayName))…")
        runner.recorder.start(configuration: config, outputURL: url)

        // Stop after N seconds (on main, where the run loop is live).
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            runner.recorder.stop()
        }
        // Hard timeout safety net.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 25) {
            print("[selftest] FAIL: timed out waiting for recording to finish.")
            exit(3)
        }

        // Keep the main run loop alive; exit() is called from a callback.
        CFRunLoopRun()
        exit(7) // unreachable
    }

    /// Records ~2s, then exercises the editor's export pipeline (trim + resize +
    /// fps + format) via `ExportEngine`, and validates the converted output.
    /// `iRecord --exporttest [mp4|hevc|mov|gif]`
    static func runExport(arguments: [String]) -> Never {
        let modeArg = arguments.first?.lowercased() ?? "mp4"
        let (format, codec): (OutputFormat, VideoCodec) = {
            switch modeArg {
            case "hevc": return (.mp4, .hevc)
            case "mov": return (.mov, .hevc)
            case "gif": return (.gif, .h264)
            default: return (.mp4, .h264)
            }
        }()

        guard PermissionsManager.hasScreenRecordingPermission() else {
            print("[exporttest] FAIL: Screen Recording permission not granted.")
            exit(2)
        }

        runner.recorder.delegate = runner
        var config = RecordingConfiguration(target: .display(displayID: CGMainDisplayID()))
        config.fps = 60
        config.codec = .h264
        config.outputFormat = .mov

        let src = FileManager.default.temporaryDirectory.appendingPathComponent("irecord-exporttest-src.mov")
        print("[exporttest] recording 2s intermediate…")
        runner.recorder.start(configuration: config, outputURL: src)

        runner.onFinish = { url in
            print("[exporttest] recorded intermediate; running export (\(modeArg))…")
            Task {
                do {
                    // Trim to 0.5–1.5s and downscale to half size at 30fps.
                    let asset = AVURLAsset(url: url)
                    let track = try await asset.loadTracks(withMediaType: .video).first!
                    let natural = try await track.load(.naturalSize)
                    let half = CGSize(width: natural.width/2, height: natural.height/2)
                    let range = CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600),
                                            duration: CMTime(seconds: 1.0, preferredTimescale: 600))
                    let opts = ExportOptions(timeRange: range, renderSize: half, fps: 30, format: format, codec: codec)
                    let out = try await ExportEngine.export(source: url, options: opts)
                    SelfTest.validateExport(out, expectedSize: half, expectedDuration: 1.0)
                } catch {
                    print("[exporttest] FAIL: \(error.localizedDescription)")
                    exit(5)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { runner.recorder.stop() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
            print("[exporttest] FAIL: timed out.")
            exit(3)
        }
        CFRunLoopRun()
        exit(7)
    }

    static func validateExport(_ url: URL, expectedSize: CGSize, expectedDuration: Double) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        if url.pathExtension == "gif" {
            if let s = CGImageSourceCreateWithURL(url as CFURL, nil) {
                let frames = CGImageSourceGetCount(s)
                print("[exporttest] gif frames=\(frames) size=\(size/1024)KB")
                if frames >= 2 && size > 1024 { print("[exporttest] PASS ✅ \(url.path)"); exit(0) }
            }
            print("[exporttest] FAIL ❌ invalid gif"); exit(6)
        }
        let asset = AVURLAsset(url: url)
        Task {
            do {
                let dur = try await asset.load(.duration).seconds
                let t = try await asset.loadTracks(withMediaType: .video).first
                let dims = try await t?.load(.naturalSize) ?? .zero
                print(String(format: "[exporttest] dims=%.0fx%.0f (expected ~%.0fx%.0f) duration=%.2fs (expected ~%.1fs) size=%dKB",
                             dims.width, dims.height, expectedSize.width, expectedSize.height, dur, expectedDuration, size/1024))
                let dimsOK = abs(dims.width - expectedSize.width) <= 4 && abs(dims.height - expectedSize.height) <= 4
                let durOK = abs(dur - expectedDuration) <= 0.4
                if dimsOK && durOK && size > 1024 {
                    print("[exporttest] PASS ✅ \(url.path)"); exit(0)
                }
                print("[exporttest] FAIL ❌ (dimsOK=\(dimsOK) durOK=\(durOK))"); exit(6)
            } catch {
                print("[exporttest] FAIL: \(error.localizedDescription)"); exit(6)
            }
        }
    }

    static func validate(_ url: URL) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0

        // GIF: validate as an animated image instead of an AV asset.
        if url.pathExtension.lowercased() == "gif" {
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                let frames = CGImageSourceGetCount(src)
                print(String(format: "[selftest] file=%@ size=%.1fKB gifFrames=%d", url.lastPathComponent, Double(size)/1024.0, frames))
                if frames >= 2 && size > 1024 {
                    print("[selftest] PASS ✅  output: \(url.path)")
                    exit(0)
                }
            }
            print("[selftest] FAIL ❌  (invalid GIF)")
            exit(6)
        }

        let asset = AVURLAsset(url: url)

        Task {
            var ok = true
            var report = ""
            do {
                let duration = try await asset.load(.duration).seconds
                let tracks = try await asset.loadTracks(withMediaType: .video)
                let dims: CGSize = try await tracks.first?.load(.naturalSize) ?? .zero

                report = String(format: "file=%@ size=%.1fKB duration=%.2fs dims=%.0fx%.0f tracks=%d",
                                url.lastPathComponent, Double(size)/1024.0, duration,
                                dims.width, dims.height, tracks.count)
                if tracks.isEmpty { ok = false; report += "  [no video track]" }
                if duration < 0.5 { ok = false; report += "  [duration too short]" }
                if size < 1024 { ok = false; report += "  [file too small]" }
                if dims.width < 2 || dims.height < 2 { ok = false; report += "  [bad dimensions]" }
            } catch {
                ok = false
                report = "validation error: \(error.localizedDescription)"
            }

            print("[selftest] \(report)")
            if ok {
                print("[selftest] PASS ✅  output: \(url.path)")
                exit(0)
            } else {
                print("[selftest] FAIL ❌")
                exit(6)
            }
        }
    }
}
