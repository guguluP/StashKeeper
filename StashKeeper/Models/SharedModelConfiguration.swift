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

    static var defaultConfiguration: ModelConfiguration {
        ModelConfiguration(schema: sharedSchema)
    }

    static func makeContainer() -> ModelContainer {
        guard useAppGroupContainer else {
            return makeDefaultContainer()
        }

        do {
            return try ModelContainer(for: sharedSchema, configurations: [sharedConfiguration])
        } catch {
            // NOTE: in practice this catch is only reachable for *other*
            // ModelContainer failures (e.g. schema migration errors) — a
            // missing/unprovisioned App Group itself crashes unconditionally
            // before this can run, per the note above. Kept as defense in
            // depth for the errors that genuinely are throwable.
            return makeDefaultContainer()
        }
    }

    private static func makeDefaultContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: sharedSchema, configurations: [defaultConfiguration])
        } catch {
            fatalErrorUnrecoverable(error)
        }
    }

    private static func fatalErrorUnrecoverable(_ error: Error) -> Never {
        fatalError("Failed to create ModelContainer even with fallback configuration: \(error)")
    }
}

/// Single SwiftData container for the app, App Intents, and widget writes.
enum ModelContainerProvider {
    static let shared: ModelContainer = SharedModelConfiguration.makeContainer()
}
