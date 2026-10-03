import CoreGraphics
import Foundation

/// Pixel-based vertical stitcher for scrolling screenshots (iShot's 长截图
/// approach: repeated captures of a fixed rect + template matching, so it works
/// in any app — browsers, chat windows, documents).
///
/// For each new frame we locate the previous accepted frame's probe strip
/// inside the new frame; the vertical shift `dy` tells us how far the content
/// moved, and the rows it revealed get appended. Frames that can't be matched
/// (too-fast scroll) are skipped — the next frame is matched against the last
/// *accepted* one.
///
/// Sticky footers (chat input bars, bottom toolbars, cookie banners) are rows
/// that stay identical while the content scrolls. They are kept out of the
/// probe (otherwise they drag the match towards dy = 0) and out of the appended
/// strips (otherwise they repeat every few hundred pixels); the footer of the
/// last frame is added once at the very bottom of the result.
///
/// Scrolling up is the same problem upside down: a `reversed` stitcher flips
/// every frame vertically on the way in (a sticky header becomes a sticky
/// footer) and flips the result back on the way out.
///
/// Overlay scrollbars float over the right edge while scrolling. Each content
/// row is seen in several frames at different screen heights, and the knob
/// covers it in only a few of them, so the final image takes the per-pixel
/// median of those observations across a `scrollbarBand` at the right edge.
final class ImageStitcher {

    struct MatchResult {
        /// Pixels the content scrolled up between frames. 0 = unchanged.
        var dy: Int
        /// Horizontal drift; nonzero means the user scrolled sideways.
        var dx: Int
    }

    private let width: Int
    private let height: Int
    private let bytesPerRow: Int

    /// Stitched content so far, top-down BGRA rows (premultiplied-first,
    /// 32-bit little endian). Appending is amortized O(strip), unlike redrawing
    /// a taller CGContext for every frame.
    private var pixels: [UInt8]
    private var rowCount: Int
    /// The last accepted frame (== bottom of the canvas).
    private var prev: Frame
    /// Rows [0, contentBottom) of `prev` are already in the canvas; the rows
    /// below are the (possibly sticky) tail that is only added on output.
    private var contentBottom: Int
    private(set) var frameCount = 0
    let reversed: Bool

    /// Right-edge strip of one accepted frame: frame row k is canvas row
    /// `canvasOffset + k` for k < `rows`.
    private struct BandSample {
        var bytes: [UInt8]
        var canvasOffset: Int
        var rows: Int
    }
    private let bandWidth: Int
    private var bandSamples: [BandSample] = []

    init?(firstFrame: CGImage, reversed: Bool = false, scrollbarBand: Int = 0) {
        width = firstFrame.width
        height = firstFrame.height
        bytesPerRow = width * 4
        self.reversed = reversed
        bandWidth = max(0, min(scrollbarBand, firstFrame.width / 4))
        guard width > 16, height > 64,
              let frame = ImageStitcher.decode(firstFrame, flipped: reversed) else { return nil }
        prev = frame
        pixels = frame.bgra
        rowCount = height
        contentBottom = height
        frameCount = 1
        recordBand(of: frame, canvasOffset: 0, rows: height)
    }

    /// Stitched image including the sticky tail of the last frame.
    var currentImage: CGImage? { makeImage(cleanScrollbar: false) }

    /// Final result: like `currentImage`, with the scrollbar band cleaned.
    var finalImage: CGImage? { makeImage(cleanScrollbar: true) }

    private func makeImage(cleanScrollbar: Bool) -> CGImage? {
        let tail = height - contentBottom
        let total = rowCount + tail
        var out = [UInt8](repeating: 0, count: total * bytesPerRow)
        out.withUnsafeMutableBufferPointer { dst in
            pixels.withUnsafeBufferPointer { src in
                UnsafeMutableRawPointer(dst.baseAddress!)
                    .copyMemory(from: src.baseAddress!, byteCount: rowCount * bytesPerRow)
            }
            if tail > 0 {
                prev.bgra.withUnsafeBufferPointer { src in
                    UnsafeMutableRawPointer(dst.baseAddress! + rowCount * bytesPerRow)
                        .copyMemory(from: src.baseAddress! + contentBottom * bytesPerRow, byteCount: tail * bytesPerRow)
                }
            }
        }
        if cleanScrollbar { cleanScrollbarBand(in: &out) }
        var data = Data(capacity: total * bytesPerRow)
        out.withUnsafeBufferPointer { buf in
            if reversed {
                for row in stride(from: total - 1, through: 0, by: -1) {
                    data.append(buf.baseAddress! + row * bytesPerRow, count: bytesPerRow)
                }
            } else {
                data.append(buf.baseAddress!, count: total * bytesPerRow)
            }
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: total,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: ImageStitcher.bitmapInfo),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    var stitchedHeight: Int { rowCount + height - contentBottom }

    /// Compares `frame` against the last accepted frame and appends the fresh
    /// rows. Returns the match result, or nil when the frame can't be matched.
    @discardableResult
    func append(_ frame: CGImage) -> MatchResult? {
        guard frame.width == width, frame.height == height,
              let new = ImageStitcher.decode(frame, flipped: reversed) else { return nil }

        // Quick identity check: unchanged frame → dy 0.
        if ImageStitcher.meanAbsDiff(prev.gray, new.gray, width: width, height: height) < 0.7 {
            prev = new
            frameCount += 1
            return MatchResult(dy: 0, dx: 0)
        }

        // Rows identical in both frames at the same position form the sticky
        // footer. A blank stretch of real content can look static too; that
        // only postpones those rows (see the bookkeeping below), never loses
        // or duplicates them.
        let footer = ImageStitcher.staticBottomRows(prev.gray, new.gray, width: width,
                                                    height: height, maxRows: height / 2)
        let contentEnd = height - footer
        let bottom = min(contentBottom, contentEnd)

        guard let match = matchFrame(prev: prev.gray, new: new.gray,
                                     contentEnd: contentEnd, maxShift: bottom)
        else { return nil }
        guard match.dx == 0 else { return match }   // caller aborts; keep canvas intact

        // Drop any canvas rows that turned out to be footer, then append the
        // content the scroll revealed: new-frame rows [bottom - dy, contentEnd).
        if var last = bandSamples.popLast() {
            last.rows = min(last.rows, bottom)       // its rows below `bottom` were footer
            bandSamples.append(last)
        }
        rowCount -= contentBottom - bottom
        let start = bottom - match.dy
        pixels.removeSubrange((rowCount * bytesPerRow)...)
        pixels.append(contentsOf: new.bgra[(start * bytesPerRow)..<(contentEnd * bytesPerRow)])
        rowCount += contentEnd - start
        contentBottom = contentEnd
        prev = new
        frameCount += 1
        recordBand(of: new, canvasOffset: rowCount - contentEnd, rows: contentEnd)
        return match
    }

    // MARK: - Scrollbar band

    private func recordBand(of frame: Frame, canvasOffset: Int, rows: Int) {
        guard bandWidth > 0 else { return }
        let bandBytes = bandWidth * 4
        var bytes = [UInt8](repeating: 0, count: height * bandBytes)
        frame.bgra.withUnsafeBufferPointer { src in
            bytes.withUnsafeMutableBufferPointer { dst in
                for row in 0..<height {
                    UnsafeMutableRawPointer(dst.baseAddress! + row * bandBytes)
                        .copyMemory(from: src.baseAddress! + row * bytesPerRow + (width - bandWidth) * 4,
                                    byteCount: bandBytes)
                }
            }
        }
        bandSamples.append(BandSample(bytes: bytes, canvasOffset: canvasOffset, rows: rows))
    }

    /// Replaces each band pixel with the median (by luminance) of every
    /// observation of that content pixel. Rows seen fewer than 3 times keep
    /// their pixels — there is no majority to trust.
    private func cleanScrollbarBand(in out: inout [UInt8]) {
        guard bandWidth > 0, bandSamples.count >= 3 else { return }
        let bandBytes = bandWidth * 4
        var candidates: [(lum: Int, sample: Int, row: Int)] = []
        out.withUnsafeMutableBufferPointer { dst in
            for canvasRow in 0..<rowCount {
                var seen: [(sample: Int, row: Int)] = []
                for (i, s) in bandSamples.enumerated() {
                    let k = canvasRow - s.canvasOffset
                    if k >= 0, k < s.rows { seen.append((i, k)) }
                }
                guard seen.count >= 3 else { continue }
                let rowBase = canvasRow * bytesPerRow + (width - bandWidth) * 4
                for x in 0..<bandWidth {
                    candidates.removeAll(keepingCapacity: true)
                    for (i, k) in seen {
                        let off = k * bandBytes + x * 4
                        let b = bandSamples[i].bytes
                        let lum = Int(b[off]) * 29 + Int(b[off + 1]) * 150 + Int(b[off + 2]) * 77
                        candidates.append((lum, i, k))
                    }
                    candidates.sort { $0.lum < $1.lum }
                    let pick = candidates[candidates.count / 2]
                    let off = pick.row * bandBytes + x * 4
                    for c in 0..<4 { dst[rowBase + x * 4 + c] = bandSamples[pick.sample].bytes[off + c] }
                }
            }
        }
    }

    // MARK: - Matching

    /// Finds how far the previous frame's content moved up in the new frame.
    /// `contentEnd` excludes the sticky footer; `maxShift` bounds dy so the
    /// appended strip starts inside the new frame.
    private func matchFrame(prev: [UInt8], new: [UInt8], contentEnd: Int, maxShift: Int) -> MatchResult? {
        let w = width
        let h = height

        // Probe strip: content rows just above the footer of the previous frame.
        let probeH = min(280, h / 3)
        let probeTop = contentEnd - probeH - 12
        guard probeTop > 8 else { return nil }
        let maxDy = min(probeTop, maxShift)      // probe must stay inside the new frame
        guard maxDy >= 1 else { return nil }

        return prev.withUnsafeBufferPointer { pa -> MatchResult? in
            new.withUnsafeBufferPointer { pb -> MatchResult? in
                let a = pa.baseAddress!, b = pb.baseAddress!

                // Single-pixel scan across the whole range: coarse stepping can
                // land on near-miss offsets that look plausible on banded content
                // (text lines, table rows), and then fail the ambiguity gate.
                var bestDy = 0
                var bestCost = Double.greatestFiniteMagnitude
                var secondBest = Double.greatestFiniteMagnitude
                for dy in 1...maxDy {
                    let cost = ImageStitcher.stripDiff(a, b, width: w, height: h,
                                                       topA: probeTop, dy: dy, probeH: probeH,
                                                       cutoff: secondBest)
                    if cost < bestCost {
                        secondBest = bestCost
                        bestCost = cost
                        bestDy = dy
                    } else if cost < secondBest {
                        secondBest = cost
                    }
                }

                guard bestDy > 0, bestCost < 6.0 else { return nil }     // no confident match
                // Require the winner to be clearly better than the runner-up,
                // unless the match is essentially perfect (uniform content repeats).
                guard bestCost < 1.0 || bestCost < secondBest * 0.85 else { return nil }

                // Verification pass with *dense* row sampling. Sparse sampling can
                // rate a near-miss dy as 0 on banded content, and the smallest such
                // dy then wins — a systematic 1–2 px shrink per frame.
                var refinedDy = bestDy
                if bestCost < 1.0 {
                    var denseBest = Double.greatestFiniteMagnitude
                    for cand in max(1, bestDy - 4)...min(maxDy, bestDy + 4) {
                        let cost = ImageStitcher.stripDiff(a, b, width: w, height: h,
                                                           topA: probeTop, dy: cand, probeH: probeH,
                                                           stepY: 1, stepX: 4)
                        if cost < denseBest {
                            denseBest = cost
                            refinedDy = cand
                        }
                    }
                }
                let refinedCost = ImageStitcher.stripDiff(a, b, width: w, height: h,
                                                          topA: probeTop, dy: refinedDy, probeH: probeH)

                // Horizontal drift check at the winning dy. Require a clear win so
                // sub-pixel rendering noise doesn't abort a vertical capture.
                var bestDx = 0
                var bestDxCost = refinedCost
                for dx in [-6, -4, -2, -1, 1, 2, 4, 6] {
                    let cost = ImageStitcher.stripDiff(a, b, width: w, height: h,
                                                       topA: probeTop, dy: refinedDy, probeH: probeH, dx: dx)
                    if cost < bestDxCost * 0.5 && refinedCost > 1.0 { bestDxCost = cost; bestDx = dx }
                }

                return MatchResult(dy: refinedDy, dx: bestDx)
            }
        }
    }

    // MARK: - Pixel helpers

    private struct Frame {
        /// Top-down BGRA rows, `width * 4` bytes each.
        var bgra: [UInt8]
        /// Luminance, one byte per pixel.
        var gray: [UInt8]
    }

    private static let bitmapInfo =
        CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// Normalizes a frame by redrawing it into a tightly packed bitmap (so
    /// cropped sub-images, whose data provider shares the parent's buffer,
    /// read right) and derives its luminance.
    private static func decode(_ image: CGImage, flipped: Bool = false) -> Frame? {
        let w = image.width, h = image.height
        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        let drew = bgra.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo) else { return false }
            if flipped {
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: 1, y: -1)
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }

        var gray = [UInt8](repeating: 0, count: w * h)
        bgra.withUnsafeBufferPointer { src in
            gray.withUnsafeMutableBufferPointer { dst in
                for i in 0..<(w * h) {
                    let off = i * 4
                    // BGRA little-endian: B=off, G=off+1, R=off+2.
                    let c0 = UInt32(src[off]), c1 = UInt32(src[off + 1]), c2 = UInt32(src[off + 2])
                    dst[i] = UInt8((c0 * 29 + c1 * 150 + c2 * 77) >> 8)
                }
            }
        }
        return Frame(bgra: bgra, gray: gray)
    }

    /// Mean absolute difference over the full frame (sampled).
    private static func meanAbsDiff(_ a: [UInt8], _ b: [UInt8], width w: Int, height h: Int) -> Double {
        var sum = 0, n = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                var y = 0
                while y < h {
                    var x = 0
                    while x < w {
                        sum += abs(Int(pa[y * w + x]) - Int(pb[y * w + x]))
                        n += 1
                        x += 8
                    }
                    y += 8
                }
            }
        }
        return n > 0 ? Double(sum) / Double(n) : .greatestFiniteMagnitude
    }

    /// Number of bottom rows that are identical in both frames. A couple of
    /// differing samples per row are tolerated (blinking caret).
    private static func staticBottomRows(_ a: [UInt8], _ b: [UInt8], width w: Int, height h: Int,
                                         maxRows: Int) -> Int {
        a.withUnsafeBufferPointer { pa -> Int in
            b.withUnsafeBufferPointer { pb -> Int in
                var rows = 0
                while rows < maxRows {
                    let base = (h - 1 - rows) * w
                    var changed = 0
                    var x = 0
                    while x < w {
                        if abs(Int(pa[base + x]) - Int(pb[base + x])) > 20 {
                            changed += 1
                            if changed > 2 { return rows }
                        }
                        x += 2
                    }
                    rows += 1
                }
                return rows
            }
        }
    }

    /// Mean absolute difference of the probe strip: rows [topA, topA+probeH) of
    /// `a` against rows [topA-dy, ...) of `b` (content moved up by dy), sampled.
    /// Stops early once the running sum can no longer beat `cutoff`.
    private static func stripDiff(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>,
                                  width w: Int, height h: Int,
                                  topA: Int, dy: Int, probeH: Int, dx: Int = 0,
                                  stepY: Int = 3, stepX: Int = 6,
                                  cutoff: Double = .greatestFiniteMagnitude) -> Double {
        guard topA - dy >= 0, topA + probeH <= h else { return .greatestFiniteMagnitude }
        let x0 = 8 + max(0, dx)
        let x1 = w - 8 + min(0, dx)
        guard x1 > x0 else { return .greatestFiniteMagnitude }
        let perRow = (x1 - x0 + stepX - 1) / stepX
        let rows = (probeH + stepY - 1) / stepY
        let total = perRow * rows
        let budget = cutoff == .greatestFiniteMagnitude ? Int.max : Int(cutoff * Double(total)) + 1

        var sum = 0
        var y = 0
        while y < probeH {
            let ra = a + (topA + y) * w
            let rb = b + (topA + y - dy) * w - dx
            var x = x0
            while x < x1 {
                sum += abs(Int(ra[x]) - Int(rb[x]))
                x += stepX
            }
            if sum > budget { return .greatestFiniteMagnitude }
            y += stepY
        }
        return Double(sum) / Double(total)
    }
}
