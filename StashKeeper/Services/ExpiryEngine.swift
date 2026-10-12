//
//  ExpiryEngine.swift
//  StashKeeper
//
//  Central place that decides *when* to remind the user about a perishable
//  item, and re-evaluates all items (e.g. on app launch / background refresh)
//  to keep notifications in sync with current data.
//

import Foundation
import SwiftData

@MainActor
final class ExpiryEngine {

    static let shared = ExpiryEngine()

    /// Re-schedules notifications for a single item based on its current expiry date.
    /// Call this whenever an item is created or its expiry date changes.
    func syncNotifications(for item: StashItem) async {
        await StashReminders.sync(item)
    }

    /// Sweeps every item and makes sure notification state matches current data.
    /// Useful after bulk edits, imports, or as a periodic background task.
    /// Soonest items get individual reminders. The rest share one daily digest
    /// so the 64-pending cap cannot drop them silently.
    func resyncAll(items: [StashItem]) async {
        await StashReminders.resyncAll(items)
    }

    /// Items due for in-app "expiring soon" / "expired" surfacing, most urgent first.
    func attentionNeeded(items: [StashItem]) -> [StashItem] {
        StashItem.needingAttention(in: items)
    }
}
