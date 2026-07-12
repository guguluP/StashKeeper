//
//  StashItemLifecycle.swift
//  StashKeeper
//
//  Single path for permanently removing a StashItem so every call site
//  (detail screen, list swipe, notification "Mark as Used") also cleans up
//  on-disk photos and cancels pending local notifications. Without this,
//  some paths deleted only the SwiftData row and left orphan HEIC files and
//  scheduled reminders behind.
//

import Foundation
import SwiftData

enum StashItemLifecycle {

    /// Deletes photos, cancels scheduled notifications, then removes the
    /// model object and saves the context. Safe to call from any main-actor
    /// UI handler; notification cancellation is async and fire-and-forget
    /// after the row is gone (IDs are captured first).
    @MainActor
    static func delete(_ item: StashItem, from context: ModelContext) {
        let photoFilenames = item.photoFilenames
        let notificationIDs = item.scheduledNotificationIDs

        for filename in photoFilenames {
            PhotoStore.delete(filename: filename)
        }

        context.delete(item)
        try? context.save()

        if !notificationIDs.isEmpty {
            Task {
                await NotificationManager.shared.cancelNotifications(ids: notificationIDs)
            }
        }
    }
}
