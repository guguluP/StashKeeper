//
//  StashScanActivityAttributes.swift
//  StashKeeper
//  ⚠️ SYNCED COPY: this file is duplicated from the main app target
//  (StashKeeper/Models or StashKeeper/Services) because Xcode's
//  file-system-synchronized-group feature ties a folder to a single
//  target's root, so it can't be natively shared between the app and
//  this widget extension without re-parenting the whole app source tree.
//  If you edit the original, copy your changes here too (or, cleaner:
//  move both into a shared Swift Package/framework target later so
//  there's only one copy for real).
//
//
//  ActivityKit attributes for a Live Activity that tracks progress while
//  StashKeeper analyzes photos during the Add Item flow — genuinely
//  "live" content (a real, changing background task with a real duration),
//  unlike e.g. an expiry countdown which doesn't need second-by-second
//  updates and is better served by a regular notification.
//
//  IMPORTANT — manual Xcode setup required:
//  Live Activities are rendered by a Widget Extension target, which is a
//  separate app-extension bundle that can't be safely added by editing
//  project.pbxproj by hand (a malformed target entry risks corrupting the
//  whole project file in ways that are hard to recover without Xcode's own
//  repair tools). This file, and the code in
//  Services/StashScanActivityController.swift that starts/updates/ends the
//  activity, are both written and ready to use — but to actually see the
//  Live Activity render, do this once in Xcode:
//
//  1. File > New > Target… > Widget Extension. Name it e.g.
//     "StashKeeperWidgets", uncheck "Include Configuration Intent" (not
//     needed for this), and CHECK "Include Live Activity".
//  2. Xcode will scaffold a widget bundle with a starter Live Activity
//     view — delete its generated ActivityAttributes struct and instead
//     add a reference to THIS file (StashScanActivityAttributes.swift) to
//     the new widget extension target's membership (select the file in
//     the file inspector, check the new target's box under "Target
//     Membership") so both the app and the widget extension compile
//     against the identical attributes type, which ActivityKit requires.
//  3. Replace the scaffolded Live Activity SwiftUI view with the
//     `StashScanActivityView` provided in
//     LiveActivity/StashScanActivityView.swift (also needs its Target
//     Membership checkbox set for the new widget extension target).
//  4. Add `NSSupportsLiveActivities = YES` to the main app's Info.plist
//     (Xcode's target editor > Info tab > add row) — this project doesn't
//     currently have a dedicated Info.plist entry visible for it since
//     it's likely using Xcode's generated-Info.plist mechanism, so add it
//     under Target > StashKeeper > Info > Custom iOS Target Properties.
//
//  Everything else (starting the activity, pushing progress updates,
//  ending it) is already wired into the Add Item flow below and needs no
//  further code changes once the target exists.
//

import Foundation
#if os(iOS)
import ActivityKit

struct StashScanActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var progressMessage: String
        var fractionComplete: Double
        var itemsFoundSoFar: Int
        var isComplete: Bool
    }

    var totalPhotoCount: Int
}
#endif
