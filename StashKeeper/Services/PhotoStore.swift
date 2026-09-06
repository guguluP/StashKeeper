//
//  PhotoStore.swift
//  StashKeeper
//
//  Stores item photos on disk rather than inline in SwiftData, keeping the
//  database lean. Uses ImageIO/CGImage directly (rather than UIImage/NSImage)
//  so this file compiles cleanly on both iOS and macOS without any
//  platform-specific imports.
//
//  Photos live in the App Group container (same as the shared SwiftData
//  store) so the widget extension, Live Activities, and notification
//  attachments can read the same files the main app writes. Falls back to
//  Application Support if the App Group entitlement isn't available yet,
//  and one-time migrates any legacy Application Support photos into the
//  shared container on first access.
//

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum PhotoStore {

    private static let photosFolderName = "StashKeeperPhotos"
    private static var didAttemptLegacyMigration = false

    static var photosDirectory: URL {
        let directory = preferredPhotosDirectory()
        ensureDirectoryExists(directory)
        migrateLegacyPhotosIfNeeded(into: directory)
        return directory
    }

    /// Preferred location: App Group so all targets share photos.
    /// Fallback: per-app Application Support (pre-App-Group installs / missing entitlement).
    ///
    /// Gated behind the same `useAppGroupContainer` flag as
    /// `SharedModelConfiguration` — calling
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` for a group ID
    /// that isn't actually present in the installed provisioning profile
    /// isn't guaranteed to just return nil; on a sandboxed app it can raise
    /// the same kind of uncatchable abort as the ModelContainer path. Only
    /// attempt it once the App Group is genuinely provisioned.
    private static func preferredPhotosDirectory() -> URL {
        guard SharedModelConfiguration.useAppGroupContainer else {
            return legacyPhotosDirectory
        }
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedModelConfiguration.appGroupIdentifier
        ) {
            return groupURL.appendingPathComponent(photosFolderName, isDirectory: true)
        }
        return legacyPhotosDirectory
    }

    private static var legacyPhotosDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(photosFolderName, isDirectory: true)
    }

    private static func ensureDirectoryExists(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// Moves files from the old Application Support folder into the App Group
    /// once, so existing installs don't lose thumbnails after the shared-container change.
    private static func migrateLegacyPhotosIfNeeded(into destination: URL) {
        guard !didAttemptLegacyMigration else { return }
        didAttemptLegacyMigration = true

        let legacy = legacyPhotosDirectory
        guard destination.standardizedFileURL != legacy.standardizedFileURL,
              FileManager.default.fileExists(atPath: legacy.path) else { return }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: legacy,
            includingPropertiesForKeys: nil
        ) else { return }

        for fileURL in contents {
            let target = destination.appendingPathComponent(fileURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: fileURL)
                continue
            }
            do {
                try FileManager.default.moveItem(at: fileURL, to: target)
            } catch {
                // Best-effort: leave the file in place if move fails so we
                // can still resolve via the dual-path load below.
            }
        }

        if let remaining = try? FileManager.default.contentsOfDirectory(atPath: legacy.path),
           remaining.isEmpty {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    /// Saves image data to disk under a new UUID filename and returns that filename.
    /// Re-encodes through CGImage/ImageIO to normalize the format and compress as HEIC.
    @discardableResult
    static func save(imageData: Data) throws -> String {
        let filename = "\(UUID().uuidString).heic"
        let url = photosDirectory.appendingPathComponent(filename)

        guard let heicData = Self.reencodeAsHEIC(imageData: imageData, compressionQuality: 0.85) else {
            try imageData.write(to: url)
            return filename
        }
        try heicData.write(to: url)
        return filename
    }

    static func url(for filename: String) -> URL {
        let primary = photosDirectory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: primary.path) {
            return primary
        }
        // Resolve pre-migration files still sitting in Application Support.
        let legacy = legacyPhotosDirectory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: legacy.path) {
            return legacy
        }
        return primary
    }

    static func loadData(filename: String) -> Data? {
        try? Data(contentsOf: url(for: filename))
    }

    static func delete(filename: String) {
        let primary = photosDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: primary)
        let legacy = legacyPhotosDirectory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    // MARK: - ImageIO-based re-encoding (cross-platform, no UIKit/AppKit)

    private static func reencodeAsHEIC(imageData: Data, compressionQuality: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            outputData, UTType.heic.identifier as CFString, 1, nil
        ) else {
            return nil
        }

        // `CGImageSourceCreateImageAtIndex` does NOT apply EXIF orientation.
        // Re-attach orientation so portrait captures don't appear rotated.
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: compressionQuality]
        if let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let orientation = sourceProperties[kCGImagePropertyOrientation] {
            options[kCGImagePropertyOrientation] = orientation
        }

        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return outputData as Data
    }
}
