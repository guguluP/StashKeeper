//
//  GroceryList.swift
//  StashKeeper
//
//  The buy list other Apple apps can see: par shortfalls plus anything
//  added by hand. Siri and Shortcuts read it through App Intents. Reminders
//  gets a copy when that share is turned on, so Reminders, Siri, and
//  Shortcuts actions that use Reminders see the same groceries.
//

import Foundation
import SwiftData
import CoreSpotlight
import EventKit

struct GroceryLine: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var quantity: Int
    var detail: String

    var spoken: String {
        "\(quantity) \(name)"
    }
}

enum GroceryList {
    @MainActor
    static func current(in context: ModelContext) -> [GroceryLine] {
        let items = (try? context.fetch(FetchDescriptor<StashItem>())) ?? []
        let needs = (try? context.fetch(FetchDescriptor<PurchaseNeed>())) ?? []
        return lines(items: items, needs: needs)
    }

    static func lines(items: [StashItem], needs: [PurchaseNeed]) -> [GroceryLine] {
        var lines: [GroceryLine] = []
        for item in items where item.parQuantity > item.quantity {
            let missing = item.parQuantity - item.quantity
            lines.append(GroceryLine(
                id: "par:\(item.id.uuidString)",
                name: item.name,
                quantity: missing,
                detail: "Have \(item.quantity), keep \(item.parQuantity)"
            ))
        }
        for need in needs where !need.isChecked {
            let trimmed = need.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append(GroceryLine(
                id: "need:\(need.id.uuidString)",
                name: trimmed,
                quantity: max(1, need.quantity),
                detail: "Added to the buy list"
            ))
        }
        return lines.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Spotlight plus Reminders, when sharing is already allowed.
    @MainActor
    static func publish() async {
        let context = ModelContainerProvider.shared.mainContext
        let lines = current(in: context)
        await indexForSpotlight(lines)
        await GroceryRemindersSync.shared.syncIfEnabled(lines)
    }

    @MainActor
    static func indexForSpotlight(_ lines: [GroceryLine]? = nil) async {
        let resolved = lines ?? current(in: ModelContainerProvider.shared.mainContext)
        let defaults = UserDefaults.standard
        let key = "StashKeeper.indexedGroceryIDs"
        let previous = defaults.stringArray(forKey: key) ?? []
        let currentIDs = Set(resolved.map(\.id))
        let removed = previous.filter { !currentIDs.contains($0) }
        let entities = resolved.map { line in
            GrocerySpotlightItem(id: line.id, name: line.name, detail: line.detail, quantity: line.quantity)
        }
        do {
            if !removed.isEmpty {
                try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: removed)
            }
            let items = entities.map { entity -> CSSearchableItem in
                let attributes = CSSearchableItemAttributeSet(contentType: .content)
                attributes.title = "Buy \(entity.quantity) \(entity.name)"
                attributes.displayName = entity.name
                attributes.contentDescription = entity.detail
                attributes.keywords = [entity.name, "grocery", "buy", "StashKeeper"]
                attributes.domainIdentifier = "stashkeeper.groceries"
                return CSSearchableItem(
                    uniqueIdentifier: entity.id,
                    domainIdentifier: "stashkeeper.groceries",
                    attributeSet: attributes
                )
            }
            if !items.isEmpty {
                try await CSSearchableIndex.default().indexSearchableItems(items)
            }
            defaults.set(Array(currentIDs), forKey: key)
        } catch {
            // Search indexing is best-effort.
        }
    }
}

private struct GrocerySpotlightItem {
    var id: String
    var name: String
    var detail: String
    var quantity: Int
}

@MainActor
final class GroceryRemindersSync {
    static let shared = GroceryRemindersSync()
    static let listTitle = "StashKeeper Groceries"
    private let notePrefix = "stashkeeper-grocery:"
    private let store = EKEventStore()

    private init() {}

    func requestAccessAndSync() async -> Bool {
        let granted = await requestAccess()
        guard granted else { return false }
        StashSettings.shareGroceriesWithReminders = true
        let lines = GroceryList.current(in: ModelContainerProvider.shared.mainContext)
        await sync(lines)
        return true
    }

    func syncIfEnabled(_ lines: [GroceryLine]) async {
        guard StashSettings.shareGroceriesWithReminders else { return }
        guard isAuthorized else { return }
        await sync(lines)
    }

    private var isAuthorized: Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .fullAccess { return true }
        if status == .authorized { return true }
        return false
    }

    private func requestAccess() async -> Bool {
        if isAuthorized { return true }
        do {
            return try await store.requestFullAccessToReminders()
        } catch {
            return false
        }
    }

    private func sync(_ lines: [GroceryLine]) async {
        guard let calendar = groceryCalendar() else { return }
        let existing = await reminders(in: calendar)
        var seen = Set<String>()
        for line in lines {
            let note = notePrefix + line.id
            seen.insert(note)
            let reminder = existing.first { $0.notes == note } ?? EKReminder(eventStore: store)
            reminder.calendar = calendar
            reminder.title = "Buy \(line.quantity) \(line.name)"
            reminder.notes = note
            reminder.isCompleted = false
            try? store.save(reminder, commit: false)
        }
        for reminder in existing {
            guard let notes = reminder.notes, notes.hasPrefix(notePrefix), !seen.contains(notes) else { continue }
            try? store.remove(reminder, commit: false)
        }
        try? store.commit()
    }

    private func groceryCalendar() -> EKCalendar? {
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == Self.listTitle }) {
            return existing
        }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = Self.listTitle
        calendar.source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first { $0.sourceType == .calDAV }
            ?? store.sources.first { $0.sourceType == .local }
        guard calendar.source != nil else { return nil }
        do {
            try store.saveCalendar(calendar, commit: true)
            return calendar
        } catch {
            return nil
        }
    }

    private func reminders(in calendar: EKCalendar) async -> [EKReminder] {
        let box = ReminderBox()
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: store.predicateForReminders(in: [calendar])) { reminders in
                box.value = reminders ?? []
                continuation.resume()
            }
        }
        return box.value
    }
}

private final class ReminderBox: @unchecked Sendable {
    var value: [EKReminder] = []
}
