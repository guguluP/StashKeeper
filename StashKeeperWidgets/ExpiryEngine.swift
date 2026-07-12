//
//  ExpiryEngine.swift
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
//  Central place that decides *when* to remind the user about a perishable
//  item, and re-evaluates all items (e.g. on app launch / background refresh)
//  to keep notifications in sync with current data.
//

import Foundation
import SwiftData

@MainActor
final class ExpiryEngine {

    static let shared = ExpiryEngine()

    private let notificationManager = NotificationManager.shared

    /// Re-schedules notifications for a single item based on its current expiry date.
    /// Call this whenever an item is created or its expiry date changes.
    func syncNotifications(for item: StashItem) async {
        await notificationManager.cancelNotifications(ids: item.scheduledNotificationIDs)
        item.scheduledNotificationIDs = []
        item.expiredNotificationSent = false

        guard item.isPerishable, let expiryDate = item.expiryDate, expiryDate > .now else {
            return
        }

        var newIDs: [String] = []

        // Warning notification, N days before expiry.
        if let warnDate = Calendar.current.date(
            byAdding: .day,
            value: -StashItem.warningWindowDays,
            to: expiryDate
        ), warnDate > .now {
            if let id = await notificationManager.scheduleExpiryWarning(for: item, fireDate: warnDate) {
                newIDs.append(id)
            }
        }

        // Day-of expiry notification.
        if let id = await notificationManager.scheduleExpiredNotice(for: item, fireDate: expiryDate) {
            newIDs.append(id)
        }

        item.scheduledNotificationIDs = newIDs
    }

    /// Sweeps every item and makes sure notification state matches current data.
    /// Useful after bulk edits, imports, or as a periodic background task.
    func resyncAll(items: [StashItem]) async {
        for item in items {
            await syncNotifications(for: item)
        }
    }

    /// Items due for in-app "expiring soon" / "expired" surfacing, most urgent first.
    func attentionNeeded(items: [StashItem]) -> [StashItem] {
        items
            .filter { $0.expiryStatus == .expiringSoon || $0.expiryStatus == .expired }
            .sorted { lhs, rhs in
                (lhs.expiryDate ?? .distantFuture) < (rhs.expiryDate ?? .distantFuture)
            }
    }
}
