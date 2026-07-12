//
//  VideoFrameExtractor.swift
//  StashKeeper
//
//  Lets the user add items from a short video instead of a still photo —
//  useful for panning across a shelf or turning an item to show labels.
//  We don't store the video itself; we extract the sharpest, most
//  information-dense frame(s) and feed those through the normal
//  photo-analysis pipeline (VisionAnalyzer -> Foundation Models).
//

import Foundation
@preconcurrency import AVFoundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum VideoFrameExtractorError: Error {
    case noFramesExtracted
    case exportFailed
}

actor VideoFrameExtractor {

    /// How many candidate frames to sample across the video's duration
    /// before picking the best ones.
    private let sampleCount = 12

    /// How many best frames to return for downstream analysis. Multiple
    /// frames help when the user pans across several items — each frame
    /// may reveal different items or angles.
    private let maxFramesToReturn = 3

    /// Extracts and returns JPEG data for the best (sharpest, most
    /// content-rich) frames found in the video at `url`.
    func extractBestFrames(from url: URL) async throws -> [Data] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw VideoFrameExtractorError.noFramesExtracted
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let times = (0..<sampleCount).map { index -> CMTime in
            let fraction = Double(index + 1) / Double(sampleCount + 1)
            return CMTime(seconds: durationSeconds * fraction, preferredTimescale: 600)
        }

        var scoredFrames: [(image: CGImage, sharpness: Double, time: CMTime)] = []

        for time in times {
            guard let cgImage = try? await generateImage(generator: generator, at: time) else { continue }
            let sharpness = Self.sharpnessScore(cgImage)
            scoredFrames.append((cgImage, sharpness, time))
        }

        guard !scoredFrames.isEmpty else {
            throw VideoFrameExtractorError.noFramesExtracted
        }

        // Prefer sharper frames (less motion blur), and prefer frames spread
        // across the timeline rather than clustered together so different
        // items panned past the camera all get a chance to be represented.
        let best = scoredFrames
            .sorted { $0.sharpness > $1.sharpness }
            .prefix(maxFramesToReturn)

        return try best.map { frame in
            guard let data = Self.jpegData(from: frame.image, quality: 0.85) else {
                throw VideoFrameExtractorError.exportFailed
            }
            return data
        }
    }

    private func generateImage(generator: AVAssetImageGenerator, at time: CMTime) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { cgImage, _, error in
                if let cgImage {
                    continuation.resume(returning: cgImage)
                } else {
                    continuation.resume(throwing: error ?? VideoFrameExtractorError.noFramesExtracted)
                }
            }
        }
    }

    /// A cheap relative sharpness estimate using a Laplacian-like variance
    /// measure over a downsampled luminance grid. Not a rigorous metric —
    /// just enough to rank candidate frames against each other and avoid
    /// picking obviously blurry ones caused by motion during the pan.
    nonisolated private static func sharpnessScore(_ cgImage: CGImage) -> Double {
        let sampleSize = 64
        guard let context = CGContext(
            data: nil,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        guard let data = context.data else { return 0 }

        let buffer = data.bindMemory(to: UInt8.self, capacity: sampleSize * sampleSize)
        var sumSquaredDiff: Double = 0
        var count = 0

        for y in 1..<(sampleSize - 1) {
            for x in 1..<(sampleSize - 1) {
                let center = Double(buffer[y * sampleSize + x])
                let left = Double(buffer[y * sampleSize + (x - 1)])
                let right = Double(buffer[y * sampleSize + (x + 1)])
                let up = Double(buffer[(y - 1) * sampleSize + x])
                let down = Double(buffer[(y + 1) * sampleSize + x])
                let laplacian = (left + right + up + down) - (4 * center)
                sumSquaredDiff += laplacian * laplacian
                count += 1
            }
        }

        guard count > 0 else { return 0 }
        return sumSquaredDiff / Double(count)
    }

    nonisolated private static func jpegData(from cgImage: CGImage, quality: CGFloat) -> Data? {
        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            outputData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return outputData as Data
    }
}
