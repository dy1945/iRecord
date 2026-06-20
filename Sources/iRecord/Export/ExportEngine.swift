import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics

/// Parameters chosen in the post-recording editor (Kap-style): trim range, output
/// resolution, frame rate, container/codec.
struct ExportOptions {
    var timeRange: CMTimeRange?          // nil = whole clip
    var renderSize: CGSize               // output pixel size
    var fps: Int
    var format: OutputFormat             // .mp4 / .mov / .gif
    var codec: VideoCodec                // used for mp4/mov
}

/// Re-encodes a recorded intermediate into the user's chosen output, applying
/// trim + resize + frame-rate + format. Video/MOV/MP4 go through
/// `AVAssetExportSession` with a scaling `AVVideoComposition`; GIF is produced by
/// `GIFExporter`.
enum ExportEngine {
    enum ExportError: LocalizedError {
        case noVideoTrack
        case sessionCreationFailed
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The recording has no video track."
            case .sessionCreationFailed: return "Could not create the export session."
            case .exportFailed(let m): return "Export failed: \(m)"
            }
        }
    }

    /// Exports to a temp file and returns its URL. Caller decides where it lands.
    ///
    /// `onProgress` is invoked with a 0...1 fraction for the video path (driven by
    /// `AVAssetExportSession.progress`). The GIF path reports no fractional
    /// progress, so callers should fall back to an indeterminate indicator there.
    static func export(source: URL,
                       options: ExportOptions,
                       onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if options.format == .gif {
            return try await exportGIF(source: source, options: options)
        } else {
            return try await exportVideo(source: source, options: options, onProgress: onProgress)
        }
    }

    // MARK: - Video (MP4 / MOV)

    private static func exportVideo(source: URL,
                                    options: ExportOptions,
                                    onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }

        let naturalSize = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let assetDuration = try await asset.load(.duration)

        // Oriented source size.
        let oriented = naturalSize.applying(preferred)
        let srcSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        let target = CGSize(width: max(2, options.renderSize.width.rounded()),
                            height: max(2, options.renderSize.height.rounded()))

        // Build a composition that applies the preferred transform plus a scale to
        // the requested render size.
        let composition = AVMutableVideoComposition()
        composition.renderSize = target
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, options.fps)))

        // The instruction must cover the full source timeline — `session.timeRange`
        // selects the trimmed sub-range, but the composition is evaluated in source
        // time, so a partial instruction range would leave the trimmed window
        // without instructions ("Operation Stopped").
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: assetDuration)

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let sx = target.width / max(1, srcSize.width)
        let sy = target.height / max(1, srcSize.height)
        let transform = preferred.concatenating(CGAffineTransform(scaleX: sx, y: sy))
        layer.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        let preset = (options.codec == .hevc)
            ? AVAssetExportPresetHEVCHighestQuality
            : AVAssetExportPresetHighestQuality

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ExportError.sessionCreationFailed
        }

        let ext = options.format.fileExtension
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("irecord-export-\(UUID().uuidString.prefix(8)).\(ext)")
        try? FileManager.default.removeItem(at: outURL)

        session.outputURL = outURL
        session.outputFileType = (options.format == .mov) ? .mov : .mp4
        session.videoComposition = composition
        session.shouldOptimizeForNetworkUse = true
        if let r = options.timeRange { session.timeRange = r }

        // Poll the session's progress while it runs so the editor can drive a
        // determinate indicator. Cancelled when export() returns.
        let poller: Task<Void, Never>?
        if let onProgress {
            onProgress(0)
            poller = Task {
                while !Task.isCancelled && (session.status == .exporting || session.status == .waiting) {
                    onProgress(Double(session.progress))
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                }
            }
        } else {
            poller = nil
        }

        await session.export()
        poller?.cancel()
        if session.status == .completed { onProgress?(1) }

        switch session.status {
        case .completed:
            return outURL
        case .failed, .cancelled:
            throw ExportError.exportFailed(session.error?.localizedDescription ?? "unknown")
        default:
            throw ExportError.exportFailed("unexpected status \(session.status.rawValue)")
        }
    }

    // MARK: - GIF

    private static func exportGIF(source: URL, options: ExportOptions) async throws -> URL {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("irecord-export-\(UUID().uuidString.prefix(8)).gif")
        try? FileManager.default.removeItem(at: outURL)

        let start = options.timeRange?.start ?? .zero
        let end = options.timeRange.map { CMTimeAdd($0.start, $0.duration) }

        try await GIFExporter.export(from: source,
                                     to: outURL,
                                     fps: options.fps,
                                     maxWidth: max(2, options.renderSize.width),
                                     startTime: start,
                                     endTime: end)
        return outURL
    }
}
