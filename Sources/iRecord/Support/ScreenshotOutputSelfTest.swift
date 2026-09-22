import AppKit
import ImageIO

/// Output smoke test. Supply argument-domain overrides so user preferences and
/// the general clipboard are never modified by this test.
@MainActor
enum ScreenshotOutputSelfTest {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await verify()
                print("[shotoutputtest] PASS")
                fflush(stdout)
                exit(0)
            } catch {
                print("[shotoutputtest] FAIL: \(error)")
                fflush(stdout)
                exit(1)
            }
        }
        app.run()
        exit(1)
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    private static func verify() async throws {
        let defaults = UserDefaults.standard
        var args = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        for key in ["shotAlsoSaves", "shotSameAsRec", "shotDir", "shotCopyClip"] {
            try require(args[key] != nil, "Missing command-line override -\(key)")
        }
        try require(!defaults.bool(forKey: "shotSameAsRec") && !defaults.bool(forKey: "shotCopyClip"),
                    "Use -shotSameAsRec NO -shotCopyClip NO")
        // CLI values arrive as strings; mirror the typed booleans persisted
        // by Settings, while keeping the override entirely process-local.
        for key in ["shotAlsoSaves", "shotSameAsRec", "shotCopyClip"] {
            args[key] = defaults.bool(forKey: key)
        }
        defaults.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
        guard let path = args["shotDir"] as? String, !path.isEmpty else {
            throw Failure(description: "-shotDir must name an empty temporary test folder")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        let tempRoots = [fm.temporaryDirectory, URL(fileURLWithPath: "/tmp", isDirectory: true)]
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        try require(tempRoots.contains { directory.path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
                    && !tempRoots.contains(directory.path), "Refusing output outside a temporary subfolder")

        let controller = RecordingController.shared
        try require(controller.effectiveScreenshotDirectory.resolvingSymlinksInPath().standardizedFileURL == directory,
                    "Effective screenshot directory did not use the temporary override")
        try require(!controller.shotCopyToClipboard && !controller.screenshotUsesRecordingDir,
                    "Controller did not honor argument-domain settings")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = Set(try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
        try require(existing.isEmpty, "Test folder must be empty to avoid touching existing files")
        let board = NSPasteboard(name: NSPasteboard.Name("iRecord.ScreenshotOutputSelfTest.\(UUID().uuidString)"))
        defer {
            ScreenshotCopyToast.shared.hide()
            board.releaseGlobally()
            if let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for file in files where !existing.contains(file) { try? fm.removeItem(at: file) }
            }
        }

        guard let context = CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(description: "Could not create image fixture")
        }
        context.setFillColor(CGColor(red: 0.12, green: 0.65, blue: 0.32, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        guard let bitmap = context.makeImage() else { throw Failure(description: "Empty image fixture") }
        let image = NSImage(cgImage: bitmap, size: NSSize(width: 96, height: 64))
        ScreenshotFileIO.handleScreenshotCopy(image: image, forceClipboard: true, pasteboard: board)
        guard let copied = board.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
              let copiedBitmap = copied.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Failure(description: "Explicit copy did not write an image to the named pasteboard")
        }
        try require(copiedBitmap.width == 96 && copiedBitmap.height == 64, "Clipboard image dimensions changed")
        let added = Set(try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)).subtracting(existing)
        if controller.screenshotAlsoSaves {
            try require(added.count == 1, "Configured auto-save should write exactly one file")
            guard let file = added.first, let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let saved = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let type = CGImageSourceGetType(source) else {
                throw Failure(description: "Auto-saved file is not a decodable image")
            }
            try require(saved.width == 96 && saved.height == 64, "Saved image dimensions changed")
            try require(file.pathExtension == controller.screenshotImageFormat.fileExtension
                        && (type as String) == controller.screenshotImageFormat.destinationUTI,
                        "Saved image did not use the configured format")
        } else {
            try require(added.isEmpty, "Clipboard-only setting unexpectedly wrote a file")
        }
        print("[shotoutputtest] PASS: explicit copy with clipboard setting off; auto-save=\(controller.screenshotAlsoSaves), format=\(controller.screenshotImageFormat.rawValue)")

        let screen = NSRect(x: -1920, y: -200, width: 1920, height: 1080)
        let frame = ScreenshotCopyToast.frame(for: NSSize(width: 220, height: 46), in: screen)
        try require(screen.contains(frame) && abs(frame.midX - screen.midX) < 0.5,
                    "Toast position does not respect the target screen")
        let toast = ScreenshotCopyToast.shared
        let keyWindow = NSApp.keyWindow
        let wasActive = NSApp.isActive
        toast.show(message: "已复制到剪贴板")
        guard let panel = toast.panel else { throw Failure(description: "No toast panel") }
        try require(panel.frame.width >= 180 && panel.frame.height == 46,
                    "Toast content lost its dimensions when attached to the panel")
        try require(toast.isVisible && panel.ignoresMouseEvents && !panel.canBecomeKey && !panel.canBecomeMain
                    && panel.styleMask.contains(.nonactivatingPanel), "Toast blocks interaction or is not visible")
        try require(NSApp.keyWindow === keyWindow && NSApp.isActive == wasActive, "Toast stole focus")
        if let content = panel.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: "/tmp/irecord-copy-toast.png"))
            }
        }
        try await Task.sleep(nanoseconds: 750_000_000)
        toast.show(message: "已复制到剪贴板")
        try require(toast.panel === panel, "Repeated copy created a second toast window")
        try await Task.sleep(nanoseconds: 750_000_000)
        try require(toast.isVisible, "Old dismissal timer hid the refreshed toast")
        try await Task.sleep(nanoseconds: 750_000_000)
        try require(!toast.isVisible, "Toast failed to disappear automatically")
        print("[shotoutputtest] PASS: nonactivating mouse-transparent toast, reuse, extended lifetime, automatic dismissal")
    }
}
