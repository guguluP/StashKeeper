//
//  ExpiryReminders.swift
//  StashKeeper
//
//  Shared by the app and the widget. Schedules local reminders from the
//  fire date (so the day count matches the day the banner appears) and
//  keeps the pending set inside iOS's 64-notification cap.
//

import Foundation
import UserNotifications

nonisolated enum ExpiryReminderBudget {
    /// One slot stays free for the daily overflow digest.
    static let individualBudget = 63

    /// How many leading items fit in `budget` notification slots.
    /// Each entry is that item's slot count. An item is kept whole or
    /// left for the digest — a two-slot item is never split.
    static func keptCount(slotNeeds: [Int], budget: Int = individualBudget) -> Int {
        var used = 0
        var kept = 0
        for need in slotNeeds {
            let slots = max(0, need)
            if slots == 0 { continue }
            if used + slots > budget { break }
            used += slots
            kept += 1
        }
        return kept
    }
}

nonisolated enum ExpiryReminderCopy {
    static func days(from fireDate: Date, until expiryDate: Date, calendar: Calendar = .current) -> Int {
        let comps = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: fireDate),
            to: calendar.startOfDay(for: expiryDate)
        )
        return comps.day ?? 0
    }

    static func warningBody(name: String, place: String, days: Int) -> String {
        if days <= 0 {
            return "\(name) at \(place) expires today."
        } else if days == 1 {
            return "\(name) at \(place) expires tomorrow."
        } else {
            return "\(name) at \(place) expires in \(days) days."
        }
    }
}

enum StashReminders {
    static let expiringCategoryID = "ITEM_EXPIRING_SOON"
    static let expiredCategoryID = "ITEM_EXPIRED"
    static let markUsedActionID = "MARK_USED"
    static let snoozeActionID = "SNOOZE_ONE_DAY"
    static let digestRequestID = "stashkeeper.expiry.digest"

    static func cancel(ids: [String]) async {
        guard !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    @MainActor
    static func sync(_ item: StashItem) async {
        let center = UNUserNotificationCenter.current()
        if !item.scheduledNotificationIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: item.scheduledNotificationIDs)
        }
        item.scheduledNotificationIDs = []
        var stored: [String] = []
        for request in requests(for: item) {
            do {
                try await center.add(request)
                stored.append(request.identifier)
            } catch {
                break
            }
        }
        item.scheduledNotificationIDs = stored
    }

    /// Cancels this catalog's pending reminders and schedules the soonest
    /// items first. Items that do not fit go into one daily digest.
    @MainActor
    static func resyncAll(_ items: [StashItem]) async {
        let center = UNUserNotificationCenter.current()
        let existingIDs = items.flatMap(\.scheduledNotificationIDs)
        center.removePendingNotificationRequests(withIdentifiers: existingIDs + [digestRequestID])
        for item in items {
            item.scheduledNotificationIDs = []
        }

        let upcoming = items
            .filter { item in
                item.quantity > 0
                    && item.isPerishable
                    && (item.expiryDate ?? .distantPast) > .now
            }
            .sorted { ($0.expiryDate ?? .distantFuture) < ($1.expiryDate ?? .distantFuture) }

        let needs = upcoming.map { requests(for: $0).count }
        let kept = ExpiryReminderBudget.keptCount(slotNeeds: needs)
        for item in upcoming.prefix(kept) {
            var ids: [String] = []
            for request in requests(for: item) {
                do {
                    try await center.add(request)
                    ids.append(request.identifier)
                } catch {
                    break
                }
            }
            item.scheduledNotificationIDs = ids
        }

        let overflow = Array(upcoming.dropFirst(kept))
        if let digest = digestRequest(for: overflow) {
            try? await center.add(digest)
        }
    }

    @MainActor
    private static func requests(for item: StashItem) -> [UNNotificationRequest] {
        guard item.quantity > 0,
              item.isPerishable,
              let expiryDate = item.expiryDate,
              expiryDate > .now else {
            return []
        }

        var requests: [UNNotificationRequest] = []
        let place = item.location?.name ?? "your stash"
        if let warnDate = Calendar.current.date(
            byAdding: .day,
            value: -StashItem.warningWindowDays,
            to: expiryDate
        ), warnDate > .now {
            let content = UNMutableNotificationContent()
            content.title = "Expiring Soon"
            content.body = ExpiryReminderCopy.warningBody(
                name: item.name,
                place: place,
                days: ExpiryReminderCopy.days(from: warnDate, until: expiryDate)
            )
            content.sound = .default
            content.categoryIdentifier = expiringCategoryID
            content.interruptionLevel = .active
            content.userInfo = ["itemID": item.id.uuidString]
            requests.append(makeRequest(content, fireDate: warnDate))
        }

        let expired = UNMutableNotificationContent()
        expired.title = "Item Expired"
        expired.body = "\(item.name) at \(place) has expired."
        expired.sound = .default
        expired.categoryIdentifier = expiredCategoryID
        expired.interruptionLevel = .timeSensitive
        expired.userInfo = ["itemID": item.id.uuidString]
        requests.append(makeRequest(expired, fireDate: expiryDate))
        return requests
    }

    private static func makeRequest(
        _ content: UNMutableNotificationContent,
        fireDate: Date
    ) -> UNNotificationRequest {
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
    }

    private static func digestRequest(for items: [StashItem]) -> UNNotificationRequest? {
        guard !items.isEmpty else { return nil }
        let content = UNMutableNotificationContent()
        content.title = "More items need attention"
        let names = items.prefix(6).map(\.name)
        let extra = items.count - names.count
        var body = names.joined(separator: ", ")
        if extra > 0 {
            body += ", and \(extra) more"
        }
        content.body = "\(items.count) more perishable items are outside the individual reminders: \(body)."
        content.sound = .default
        content.categoryIdentifier = expiringCategoryID
        content.interruptionLevel = .active
        var comps = DateComponents()
        comps.hour = 9
        comps.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        return UNNotificationRequest(identifier: digestRequestID, content: content, trigger: trigger)
    }
}
