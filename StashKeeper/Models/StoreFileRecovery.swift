//
//  StoreFileRecovery.swift
//  StashKeeper
//
//  A failed open must not delete the live SwiftData files. Callers copy
//  them aside for recovery and leave the originals where they are.
//

import Foundation

nonisolated enum StoreFileRecovery {
    static let storeFileNames = [
        "default.store",
        "default.store-wal",
        "default.store-shm",
    ]

    static func storeFileURLs(in directory: URL) -> [URL] {
        storeFileNames.map { directory.appendingPathComponent($0) }
    }

    /// Copies whatever store files exist into a new folder next to them.
    /// Returns nil when there is nothing to copy. Never removes the originals.
    @discardableResult
    static func archiveCopy(in directory: URL) -> URL? {
        let present = storeFileURLs(in: directory).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !present.isEmpty else { return nil }

        let stamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        let backup = directory.appendingPathComponent(
            "StashKeeperStoreBackup-\(stamp)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            for url in present {
                try FileManager.default.copyItem(
                    at: url,
                    to: backup.appendingPathComponent(url.lastPathComponent)
                )
            }
            return backup
        } catch {
            return nil
        }
    }

    /// Moves store files into a backup folder so a new store can be created
    /// at the live path. The backup keeps the bytes. Returns nil if there
    /// is nothing to move or a move fails (originals stay put in that case).
    @discardableResult
    static func relocateAside(in directory: URL) -> URL? {
        let present = storeFileURLs(in: directory).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !present.isEmpty else { return nil }

        let stamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        let backup = directory.appendingPathComponent(
            "StashKeeperStoreBackup-\(stamp)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            for url in present {
                try FileManager.default.moveItem(
                    at: url,
                    to: backup.appendingPathComponent(url.lastPathComponent)
                )
            }
            return backup
        } catch {
            if let moved = try? FileManager.default.contentsOfDirectory(
                at: backup,
                includingPropertiesForKeys: nil
            ) {
                for url in moved {
                    let original = directory.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.moveItem(at: url, to: original)
                }
            }
            try? FileManager.default.removeItem(at: backup)
            return nil
        }
    }
}
