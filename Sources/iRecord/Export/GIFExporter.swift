import Foundation
import AVFoundation
@preconcurrency import ImageIO
import CoreServices
import UniformTypeIdentifiers
import CoreGraphics

/// Converts a recorded movie into an animated GIF using ImageIO.
///
/// We use `AVAssetImageGenerator` to pull frames at the target GIF frame rate,
/// then write them with `CGImageDestination`. Generation is done with tolerance
/// zero for accurate frame timing.
enum GIFExporter {
    enum GIFError: LocalizedError {
        case noVideoTrack
        case destinationFailed
        case finalizeFailed

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The recording has no video track to convert."
            case .destinationFailed: return "Could not create the GIF file."
            case .finalizeFailed: return "Could not finalize the GIF file."
            }
        }
    }

    static func export(from sourceURL: URL,
                       to destURL: URL,
                       fps: Int,
                       maxWidth: CGFloat = 1024,
                       startTime: CMTime = .zero,
                       endTime: CMTime? = nil) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw GIFError.noVideoTrack
        }

        let assetDuration = try await asset.load(.duration)
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let size = naturalSize.applying(transform)
        let absSize = CGSize(width: abs(size.width), height: abs(size.height))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        // Downscale large captures so GIFs stay a reasonable size.
        if absSize.width > maxWidth {
            let scale = maxWidth / absSize.width
            generator.maximumSize = CGSize(width: maxWidth, height: (absSize.height * scale).rounded())
        }

        let start = max(0, startTime.seconds)
        let end = min(assetDuration.seconds, (endTime ?? assetDuration).seconds)
        let totalSeconds = end - start
        guard totalSeconds > 0 else { throw GIFError.noVideoTrack }
        let frameCount = max(1, Int(totalSeconds * Double(fps)))
        let frameDelay = 1.0 / Double(fps)

        var times: [NSValue] = []
        for i in 0..<frameCount {
            let t = CMTime(seconds: start + Double(i) * frameDelay, preferredTimescale: 600)
            times.append(NSValue(time: t))
        }

        let typeIdentifier = UTType.gif.identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(destURL as CFURL, typeIdentifier, frameCount, nil) else {
            throw GIFError.destinationFailed
        }

        let gifProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0
            ]
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: frameDelay,
                kCGImagePropertyGIFUnclampedDelayTime as String: frameDelay
            ]
        ]

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var remaining = times.count
            var didResume = false
            let lock = NSLock()

            generator.generateCGImagesAsynchronously(forTimes: times) { _, image, _, result, error in
                lock.lock()
                if let image, result == .succeeded {
                    CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
                }
                remaining -= 1
                let done = remaining <= 0
                lock.unlock()

                if done && !didResume {
                    didResume = true
                    if CGImageDestinationFinalize(destination) {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: GIFError.finalizeFailed)
                    }
                }
                _ = error
            }
        }
    }
}
