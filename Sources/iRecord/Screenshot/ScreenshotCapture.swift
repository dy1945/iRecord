import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Still-image screen capture for the screenshot feature.
///
/// Screen flow overview (mirrors iShot): entering screenshot mode first freezes
/// the screen — every display is captured once up front — and the selection
/// overlay shows that frozen frame. Region capture is then a crop of the frozen
/// pixels, so pinned screenshots (pin windows) naturally appear in subsequent
/// captures ("二次截屏"). The freeze uses a CGWindowList display composite,
/// which — unlike SCScreenshotManager — includes transient UI such as open
/// dropdown menus, so a menu can be captured while it is open.
enum ScreenshotCapture {

    /// One frozen display: its CG image (native pixels) and Cocoa global frame.
    struct FrozenDisplay {
        let displayID: CGDirectDisplayID
        let image: CGImage
        /// Global Cocoa frame (bottom-left origin) of the display.
        let frame: CGRect
        /// Pixels-per-point of `image` relative to `frame`.
        var scale: CGFloat { CGFloat(image.width) / frame.width }
    }

    /// Captures every connected display once.
    static func freezeDisplays() async throws -> [FrozenDisplay] {
        let displays = ScreenInfo.displays()
        guard !displays.isEmpty else { throw CaptureError.noDisplays }
        return try freezeWithWindowList(displays)
    }

    /// Live-captures a global Cocoa rect right now (used by scrolling capture,
    /// where the screen keeps changing under a fixed rectangle).
    static func capture(globalRect: CGRect) -> CGImage? {
        let q = quartzRect(from: globalRect)
        return CGWindowListCreateImage(q, .optionOnScreenOnly, kCGNullWindowID,
                                       [.bestResolution, .boundsIgnoreFraming])
    }

    /// Crops a global Cocoa rect out of the frozen displays. Returns nil when
    /// the rect does not intersect any frozen display.
    static func crop(globalRect: CGRect, from frozen: [FrozenDisplay]) -> CGImage? {
        var canvas: CGImage?
        // Compose in case the selection spans displays: draw all intersections
        // into a single bitmap sized to the (possibly cross-display) rect.
        let scale = frozen.first?.scale ?? 2
        let pxW = Int((globalRect.width * scale).rounded())
        let pxH = Int((globalRect.height * scale).rounded())
        guard pxW > 0, pxH > 0,
              let ctx = CGContext(data: nil, width: pxW, height: pxH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        var drew = false
        for d in frozen {
            let inter = d.frame.intersection(globalRect)
            guard !inter.isNull, inter.width > 0, inter.height > 0 else { continue }
            // Crop rect in the display image's pixel space (top-left origin).
            let localX = inter.origin.x - d.frame.origin.x
            let localYBottom = inter.origin.y - d.frame.origin.y
            let localYTop = d.frame.height - localYBottom - inter.height
            let cropPx = CGRect(x: (localX * d.scale).rounded(),
                                y: (localYTop * d.scale).rounded(),
                                width: (inter.width * d.scale).rounded(),
                                height: (inter.height * d.scale).rounded())
            guard let piece = d.image.cropping(to: cropPx) else { continue }
            // Destination in the output bitmap (also top-left origin pixels).
            let dstX = ((inter.origin.x - globalRect.origin.x) * scale).rounded()
            let dstYBottom = inter.origin.y - globalRect.origin.y
            let dstYTop = globalRect.height - dstYBottom - inter.height
            let dst = CGRect(x: dstX, y: (dstYTop * scale).rounded(),
                             width: cropPx.width, height: cropPx.height)
            ctx.draw(piece, in: dst)
            drew = true
        }
        guard drew else { return nil }
        canvas = ctx.makeImage()
        return canvas
    }

    enum CaptureError: Error, LocalizedError {
        case noDisplays
        case captureFailed
        var errorDescription: String? {
            switch self {
            case .noDisplays: return "No displays available to capture."
            case .captureFailed: return "Screen capture failed. Check Screen Recording permission."
            }
        }
    }

    // MARK: - Backends

    /// Full-display composite via CGWindowListCreateImage: everything the
    /// WindowServer draws for the display, including open menus and popovers
    /// (SCScreenshotManager's display filter omits those transient windows).
    private static func freezeWithWindowList(_ displays: [DisplayInfo]) throws -> [FrozenDisplay] {
        var result: [FrozenDisplay] = []
        for d in displays {
            let rect = quartzRect(from: d.frame)
            if let img = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID,
                                                 [.bestResolution, .boundsIgnoreFraming]) {
                result.append(FrozenDisplay(displayID: d.id, image: img, frame: d.frame))
            }
        }
        if result.isEmpty { throw CaptureError.captureFailed }
        return result
    }

    // MARK: - Coordinates

    /// Global Cocoa (bottom-left origin) → Quartz display coordinates
    /// (top-left origin at the primary display), for CGWindowListCreateImage.
    static func quartzRect(from cocoa: CGRect) -> CGRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: cocoa.origin.x,
                      y: primaryH - cocoa.origin.y - cocoa.height,
                      width: cocoa.width, height: cocoa.height)
    }

    /// Quartz → global Cocoa.
    static func cocoaRect(from quartz: CGRect) -> CGRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: quartz.origin.x,
                      y: primaryH - quartz.origin.y - quartz.height,
                      width: quartz.width, height: quartz.height)
    }
}
