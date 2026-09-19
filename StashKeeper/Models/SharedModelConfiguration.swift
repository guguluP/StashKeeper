//
//  SharedModelConfiguration.swift
//  StashKeeper
//
//  The main app, the widget extension, and App Intents each construct
//  their own ModelContainer (they're separate processes/targets and can't
//  share a live container instance). All three point at the same
//  App Group container so they read and write the identical on-disk
//  SwiftData store — without this, the widget extension would silently
//  create its own separate, permanently-empty database instead of ever
//  seeing real inventory data, since an extension process can't see the
//  main app's default (sandboxed, per-target) storage location at all.
//
//  This requires the App Group entitlement
//  ("group.com.piyushpatnaik.StashKeeper") to be added to BOTH the main
//  app target and the StashKeeperWidgetsExtension target in Xcode's
//  Signing & Capabilities tab (entitlements files are already provided at
//  StashKeeper/StashKeeper.entitlements and
//  StashKeeperWidgets/StashKeeperWidgetsExtension.entitlements — Xcode's
//  "+ Capability > App Groups" button will pick these up, or you can point
//  each target's CODE_SIGN_ENTITLEMENTS build setting at them directly).
//
//  IMPORTANT: unlike most SwiftData setup failures, an App Group identifier
//  that isn't actually present in the *installed* provisioning profile
//  doesn't throw — it's an uncatchable `fatalError` raised inside Apple's
//  own SwiftData framework (SwiftData/DataUtilities.swift) while resolving
//  the group container's file path, before this file's `do/catch` ever
//  gets a chance to run. That's a hard crash on-device, since a real
//  provisioning profile is enforced there; automatic signing when
//  building straight to "My Mac" is more permissive about entitlements
//  that reference unregistered capabilities and won't reproduce it.
//
//  Because of that, whether the shared container is even *attempted* is
//  gated by `useAppGroupContainer` below, not just wrapped in try/catch.
//  Flip it on once:
//    1. The StashKeeperWidgetsExtension target actually exists in Xcode
//       (it's source-only on disk right now — see StashKeeperWidgets/), and
//    2. Your Apple ID is enrolled in the paid Apple Developer Program
//       (App Groups aren't available on the free personal-team tier), and
//    3. group.com.piyushpatnaik.StashKeeper is registered under that team
//       and both targets' provisioning profiles include it.
//

import Darwin
import Foundation
import SwiftData

enum SharedModelConfiguration {
    nonisolated static let appGroupIdentifier = "group.com.piyushpatnaik.StashKeeper"

    /// Shared App Group store for the app, widgets, and App Intents.
    /// Requires `group.com.piyushpatnaik.StashKeeper` on both targets'
    /// provisioning profiles (paid team). If launch aborts, confirm the
    /// group is enabled in Signing & Capabilities.
    nonisolated static let useAppGroupContainer = true

    static let sharedSchema = Schema([StashItem.self, StorageLocation.self, StreakRecord.self])

    static var sharedConfiguration: ModelConfiguration {
        ModelConfiguration(schema: sharedSchema, groupContainer: .identifier(appGroupIdentifier))
    }

    /// Must pass `groupContainer: .none`. The `ModelConfiguration(schema:)`
    /// overload defaults to `.automatic`, which reuses the App Group store
    /// whenever the entitlement is present — so a "fallback" without `.none`
    /// opens the same `default.store` that just failed (NSCocoaError 256 /
    /// SQLITE_AUTH 23) and then `fatalError`s.
    static var defaultConfiguration: ModelConfiguration {
        ModelConfiguration(schema: sharedSchema, groupContainer: .none)
    }

    static func makeContainer() -> ModelContainer {
        if useAppGroupContainer {
            if let container = openOrRepair(sharedConfiguration, storeDirectory: appGroupStoreDirectory) {
                return container
            }
        }
        if let container = openOrRepair(defaultConfiguration, storeDirectory: applicationSupportStoreDirectory) {
            return container
        }
        // Last resort: in-memory so launch never hard-crashes. Inventory
        // will be empty for this session only.
        do {
            return try ModelContainer(
                for: sharedSchema,
                configurations: [ModelConfiguration(schema: sharedSchema, isStoredInMemoryOnly: true)]
            )
        } catch {
            fatalError("Failed to create even an in-memory ModelContainer: \(error)")
        }
    }

    private static func openOrRepair(
        _ configuration: ModelConfiguration,
        storeDirectory: URL?
    ) -> ModelContainer? {
        if let container = tryCreate(configuration) {
            return container
        }
        // Quarantine xattrs on SQLite files in the group container cause
        // SQLITE_AUTH (23) / NSCocoaErrorDomain 256 "couldn't be opened".
        clearQuarantine(in: storeDirectory)
        if let container = tryCreate(configuration) {
            return container
        }
        destroyStoreFiles(in: storeDirectory)
        return tryCreate(configuration)
    }

    private static func tryCreate(_ configuration: ModelConfiguration) -> ModelContainer? {
        do {
            return try ModelContainer(for: sharedSchema, configurations: [configuration])
        } catch {
            return nil
        }
    }

    private static var appGroupStoreDirectory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    private static var applicationSupportStoreDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    private static func clearQuarantine(in directory: URL?) {
        guard let directory else { return }
        for url in storeFileURLs(in: directory) {
            try? FileManager.default.setAttributes(
                [.extensionHidden: false],
                ofItemAtPath: url.path
            )
            let _ = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return }
                removexattr(path, "com.apple.quarantine", 0)
            }
        }
    }

    private static func destroyStoreFiles(in directory: URL?) {
        guard let directory else { return }
        for url in storeFileURLs(in: directory) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func storeFileURLs(in directory: URL) -> [URL] {
        let names = [
            "default.store",
            "default.store-wal",
            "default.store-shm",
        ]
        return names.map { directory.appendingPathComponent($0) }
    }
}

/// Single SwiftData container for the app, App Intents, and widget writes.
enum ModelContainerProvider {
    static let shared: ModelContainer = SharedModelConfiguration.makeContainer()
}
