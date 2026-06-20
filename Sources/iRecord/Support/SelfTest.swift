import Foundation
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
