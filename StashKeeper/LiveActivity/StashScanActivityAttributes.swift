//
//  StashScanActivityAttributes.swift
//  StashKeeper
//
//  ActivityKit attributes for a Live Activity that tracks progress while
//  StashKeeper analyzes photos during the Add Item flow — genuinely
//  "live" content (a real, changing background task with a real duration),
//  unlike e.g. an expiry countdown which doesn't need second-by-second
//  updates and is better served by a regular notification.
//
//  The widget extension already renders this. StashScanLiveActivity in
//  StashKeeperWidgetsBundle registers the Lock Screen and Dynamic Island
//  UI, and Add Item starts, updates, and ends the activity while a photo
//  is analyzed. NSSupportsLiveActivities is set on the app and the extension.
//

import Foundation
#if os(iOS)
import ActivityKit

nonisolated struct StashScanActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var progressMessage: String
        var fractionComplete: Double
        var itemsFoundSoFar: Int
        var isComplete: Bool
    }

    var totalPhotoCount: Int
}
#endif
