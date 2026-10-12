//
//  NotificationManager.swift
//  StashKeeper
//
//  Schedules and manages local notifications for perishable item reminders.
//  Uses category-based actions so the user can act (mark used / snooze)
//  right from the notification, and interruption levels so expired-item
//  alerts are appropriately prominent without being obnoxious.
//

import Foundation
import SwiftData
import UserNotifications

@MainActor
final class NotificationManager: NSObject {

    static let shared = NotificationManager()

    static let expiringCategoryID = StashReminders.expiringCategoryID
    static let expiredCategoryID = StashReminders.expiredCategoryID

    static let markUsedActionID = StashReminders.markUsedActionID
    static let snoozeActionID = StashReminders.snoozeActionID

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
        registerCategories()
    }

    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    private func registerCategories() {
        let markUsed = UNNotificationAction(
            identifier: Self.markUsedActionID,
            title: "Mark as Used",
            options: [.destructive]
        )
        let snooze = UNNotificationAction(
            identifier: Self.snoozeActionID,
            title: "Remind Tomorrow",
            options: []
        )

        let expiringCategory = UNNotificationCategory(
            identifier: Self.expiringCategoryID,
            actions: [markUsed, snooze],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let expiredCategory = UNNotificationCategory(
            identifier: Self.expiredCategoryID,
            actions: [markUsed],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        center.setNotificationCategories([expiringCategory, expiredCategory])
    }

    func cancelNotifications(ids: [String]) async {
        await StashReminders.cancel(ids: ids)
    }

    /// Applies a notification action to the store directly. Posting only
    /// through NotificationCenter drops the action when the app is launched
    /// from a killed state and the view is not listening yet.
    @MainActor
    static func applyAction(actionID: String, itemID: UUID) {
        if actionID == UNNotificationDefaultActionIdentifier {
            StashPendingRoute.itemID = itemID
            NotificationCenter.default.post(
                name: .openStashItem,
                object: nil,
                userInfo: ["itemID": itemID]
            )
            return
        }

        let context = ModelContainerProvider.shared.mainContext
        let items = (try? context.fetch(FetchDescriptor<StashItem>())) ?? []
        guard let item = items.first(where: { $0.id == itemID }) else { return }

        switch actionID {
        case markUsedActionID:
            _ = item.consumeOneUnit(in: context)
            Task { await StashItemLifecycle.afterEdit(item, in: context) }
        case snoozeActionID:
            item.snoozeExpiry(days: 1, in: context)
            Task { await StashItemLifecycle.afterEdit(item, in: context) }
        default:
            break
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {

    /// Show banners even while the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .badge, .sound]
    }

    /// Handles the "Mark as Used" / "Remind Tomorrow" actions from the notification itself.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let actionID = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        guard let itemIDString = userInfo["itemID"] as? String,
              let itemID = UUID(uuidString: itemIDString) else { return }

        await MainActor.run {
            NotificationManager.applyAction(actionID: actionID, itemID: itemID)
        }
    }
}

extension Notification.Name {
    /// Posted when the user taps a notification action; observed by the app's
    /// root view to route to the item and apply the action (mark used / snooze).
    static let stashItemNotificationAction = Notification.Name("stashItemNotificationAction")
}
