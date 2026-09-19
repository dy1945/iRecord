import CoreGraphics
import Foundation

/// Pixel-based vertical stitcher for scrolling screenshots (iShot's 长截图
/// approach: repeated captures of a fixed rect + template matching, so it works
/// in any app — browsers, chat windows, documents).
///
/// For each new frame we locate the previous accepted frame's bottom probe
/// strip inside the new frame; the vertical shift `dy` tells us how far the
/// content moved. The bottom `dy` pixels of the new frame are fresh content
/// and get appended. Frames that can't be matched (too-fast scroll) are
/// skipped — the next frame is matched against the last *accepted* one.
final class ImageStitcher {

    struct MatchResult {
        /// Pixels the content scrolled up between frames. 0 = unchanged.
        var dy: Int
        /// Horizontal drift; nonzero means the user scrolled sideways.
        var dx: Int
    }

    private let width: Int
    private let height: Int

    /// The growing stitched image, as a BGRA bitmap context.
    private var canvas: CGContext
    private var canvasHeight: Int
    /// Luminance of the last accepted frame (== canvas bottom); kept so a
    /// failed frame never poisons the next comparison.
    private var prevGray: Gray
    private(set) var frameCount = 0

    init?(firstFrame: CGImage) {
        width = firstFrame.width
        height = firstFrame.height
        canvasHeight = height
        guard let ctx = ImageStitcher.makeContext(width: width, height: height),
              let gray = ImageStitcher.grayBuffer(firstFrame) else { return nil }
        canvas = ctx
        prevGray = gray
        canvas.draw(firstFrame, in: CGRect(x: 0, y: 0, width: width, height: height))
        frameCount = 1
    }

    var currentImage: CGImage? { canvas.makeImage() }
    var stitchedHeight: Int { canvasHeight }

    /// Compares `frame` against the last accepted frame and appends the fresh
    /// strip. Returns the match result, or nil when the frame can't be matched.
    @discardableResult
    func append(_ frame: CGImage) -> MatchResult? {
        guard frame.width == width, frame.height == height,
              let newGray = ImageStitcher.grayBuffer(frame),
              let match = matchFrame(prev: prevGray, new: newGray)
        else { return nil }

        prevGray = newGray          // accepted: canvas bottom is now this frame
        if match.dy > 0 {
            grow(by: match.dy, from: frame)
        }
        frameCount += 1
        return match
    }

    /// Appends the bottom `dy` pixels of `frame` to the canvas.
    private func grow(by dy: Int, from frame: CGImage) {
        guard let old = canvas.makeImage(),
              let newCanvas = ImageStitcher.makeContext(width: width, height: canvasHeight + dy),
              let freshStrip = frame.cropping(to: CGRect(x: 0, y: height - dy, width: width, height: dy))
        else { return }
        // CGContext draws y-up, CGImage crops are top-left origin. Old content
        // stays at the top of the taller canvas, the fresh strip at the bottom.
        newCanvas.draw(old, in: CGRect(x: 0, y: dy, width: width, height: canvasHeight))
        newCanvas.draw(freshStrip, in: CGRect(x: 0, y: 0, width: width, height: dy))
        canvas = newCanvas
        canvasHeight += dy
    }

    // MARK: - Matching

    /// Finds how far the previous frame's content moved up in the new frame.
    private func matchFrame(prev: Gray, new: Gray) -> MatchResult? {
        let w = width
        let h = height

        // Quick identity check: unchanged frame → dy 0.
        if ImageStitcher.meanAbsDiff(prev.buf, new.buf, width: w, height: h, dyA: 0, dyB: 0) < 0.7 {
            return MatchResult(dy: 0, dx: 0)
        }

        // Probe strip: rows near the bottom of the previous frame.
        let probeH = min(280, h / 3)
        let probeTop = h - probeH - 24
        guard probeTop > 0 else { return nil }
        let maxDy = probeTop - 8      // probe must stay inside the new frame

        // Single-pixel scan across the whole range: coarse stepping can land on
        // near-miss offsets that look plausible on banded content (text lines,
        // table rows), and then fail the ambiguity gate before refinement.
        var bestDy = 0
        var bestCost = Double.greatestFiniteMagnitude
        var secondBest = Double.greatestFiniteMagnitude

        for dy in 1...maxDy {
            let cost = ImageStitcher.stripDiff(prev.buf, new.buf, width: w,
                                               topA: probeTop, dy: dy, probeH: probeH)
            if cost < bestCost {
                secondBest = bestCost
                bestCost = cost
                bestDy = dy
            } else if cost < secondBest {
                secondBest = cost
            }
        }

        guard bestDy > 0, bestCost < 6.0 else { return nil }     // no confident match
        // Require the winner to be clearly better than the runner-up, unless the
        // match is essentially perfect (uniform content repeats).
        guard bestCost < 1.0 || bestCost < secondBest * 0.85 else { return nil }

        // Verification pass with *dense* row sampling. Sparse sampling can rate
        // a near-miss dy as 0 on banded content (text lines, list rows), and the
        // smallest such dy then wins — a systematic 1–2 px shrink per frame.
        var refinedDy = bestDy
        if bestCost < 1.0 {
            var denseBest = Double.greatestFiniteMagnitude
            for cand in max(1, bestDy - 4)...min(maxDy, bestDy + 4) {
                let cost = ImageStitcher.stripDiff(prev.buf, new.buf, width: w,
                                                   topA: probeTop, dy: cand, probeH: probeH,
                                                   dx: 0, stepY: 1, stepX: 4)
                if cost < denseBest {
                    denseBest = cost
                    refinedDy = cand
                }
            }
        }
        let refinedCost = bestCost

        // Horizontal drift check at the winning dy.
        var bestDx = 0
        var bestDxCost = refinedCost
        for dx in [-6, -4, -2, -1, 1, 2, 4, 6] {
            let cost = ImageStitcher.stripDiff(prev.buf, new.buf, width: w,
                                               topA: probeTop, dy: refinedDy, probeH: probeH, dx: dx)
            if cost < bestDxCost { bestDxCost = cost; bestDx = dx }
        }

        return MatchResult(dy: refinedDy, dx: bestDx)
    }

    // MARK: - Pixel helpers

    private struct Gray {
        var buf: [UInt8]
        var width: Int
        var height: Int
    }

    /// Luminance buffer, normalized by redrawing into a fresh bitmap so cropped
    /// sub-images (whose data provider shares the parent's buffer) read right.
    private static func grayBuffer(_ image: CGImage) -> Gray? {
        let w = image.width, h = image.height
        guard let ctx = makeContext(width: w, height: h),
              let raw = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let base = raw.assumingMemoryBound(to: UInt8.self)
        let bpl = ctx.bytesPerRow
        var buf = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base + y * bpl
            for x in 0..<w {
                let off = x * 4
                // BGRA little-endian: B=off, G=off+1, R=off+2.
                let c0 = UInt32(row[off]), c1 = UInt32(row[off + 1]), c2 = UInt32(row[off + 2])
                buf[y * w + x] = UInt8((c0 * 29 + c1 * 150 + c2 * 77) >> 8)
            }
        }
        return Gray(buf: buf, width: w, height: h)
    }

    /// Mean absolute difference over the full frame (sampled).
    private static func meanAbsDiff(_ a: [UInt8], _ b: [UInt8], width w: Int, height h: Int,
                                    dyA: Int, dyB: Int) -> Double {
        var sum = 0, n = 0
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                sum += abs(Int(a[(y + dyA) * w + x]) - Int(b[(y + dyB) * w + x]))
                n += 1
                x += 8
            }
            y += 8
        }
        return n > 0 ? Double(sum) / Double(n) : .greatestFiniteMagnitude
    }

    /// Mean absolute difference of the probe strip: rows [topA, topA+probeH) of
    /// `a` against rows [topA-dy, ...) of `b` (content moved up by dy), sampled.
    private static func stripDiff(_ a: [UInt8], _ b: [UInt8], width w: Int,
                                  topA: Int, dy: Int, probeH: Int, dx: Int = 0,
                                  stepY: Int = 3, stepX: Int = 6) -> Double {
        var sum = 0, n = 0
        var y = 0
        while y < probeH {
            let ya = topA + y
            let yb = ya - dy
            if yb < 0 { return .greatestFiniteMagnitude }
            var x = 8 + max(0, dx)
            while x < w - 8 + min(0, dx) {
                sum += abs(Int(a[ya * w + x]) - Int(b[yb * w + x - dx]))
                n += 1
                x += stepX
            }
            y += stepY
        }
        return n > 0 ? Double(sum) / Double(n) : .greatestFiniteMagnitude
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }
}
