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
import UserNotifications

@MainActor
final class NotificationManager: NSObject {

    static let shared = NotificationManager()

    static let expiringCategoryID = "ITEM_EXPIRING_SOON"
    static let expiredCategoryID = "ITEM_EXPIRED"

    static let markUsedActionID = "MARK_USED"
    static let snoozeActionID = "SNOOZE_ONE_DAY"

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

    /// Schedules a heads-up reminder ahead of expiry. Returns the notification ID if scheduled.
    func scheduleExpiryWarning(for item: StashItem, fireDate: Date) async -> String? {
        let content = UNMutableNotificationContent()
        content.title = "Expiring Soon"
        content.body = expiryWarningBody(for: item)
        content.sound = .default
        content.categoryIdentifier = Self.expiringCategoryID
        content.interruptionLevel = .active
        content.userInfo = ["itemID": item.id.uuidString]
        if let firstPhoto = item.photoFilenames.first {
            content.userInfo["photoFilename"] = firstPhoto
        }

        return await schedule(content: content, fireDate: fireDate)
    }

    /// Schedules the day-of "this has expired" notice.
    func scheduleExpiredNotice(for item: StashItem, fireDate: Date) async -> String? {
        let content = UNMutableNotificationContent()
        content.title = "Item Expired"
        content.body = "\(item.name) at \(item.location?.name ?? "your stash") has expired."
        content.sound = .default
        content.categoryIdentifier = Self.expiredCategoryID
        // Expired items are more time-critical than an advance warning.
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["itemID": item.id.uuidString]

        return await schedule(content: content, fireDate: fireDate)
    }

    private func schedule(content: UNMutableNotificationContent, fireDate: Date) async -> String? {
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let id = UUID().uuidString
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        do {
            try await center.add(request)
            return id
        } catch {
            return nil
        }
    }

    func cancelNotifications(ids: [String]) async {
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    private func expiryWarningBody(for item: StashItem) -> String {
        let days = item.daysUntilExpiry ?? 0
        let where_ = item.location?.name ?? "your stash"
        if days <= 0 {
            return "\(item.name) at \(where_) expires today."
        } else if days == 1 {
            return "\(item.name) at \(where_) expires tomorrow."
        } else {
            return "\(item.name) at \(where_) expires in \(days) days."
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
        guard let itemIDString = response.notification.request.content.userInfo["itemID"] as? String,
              let itemID = UUID(uuidString: itemIDString) else { return }

        await MainActor.run {
            NotificationCenter.default.post(
                name: .stashItemNotificationAction,
                object: nil,
                userInfo: [
                    "itemID": itemID,
                    "actionID": response.actionIdentifier
                ]
            )
        }
    }
}

extension Notification.Name {
    /// Posted when the user taps a notification action; observed by the app's
    /// root view to route to the item and apply the action (mark used / snooze).
    static let stashItemNotificationAction = Notification.Name("stashItemNotificationAction")
}
