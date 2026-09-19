//
//  InteractiveWidgetIntents.swift
//  StashKeeper
//
//  App Intents the Home Screen widget buttons invoke. Compiled into both
//  the app and the widget extension so WidgetKit can resolve them.
//

import AppIntents
import SwiftData
#if canImport(WidgetKit)
import WidgetKit
#endif

struct ConsumeStashItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Use One"
    static let description = IntentDescription("Decrements an item's quantity by one from the widget or Shortcuts.")
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Item ID")
    var itemID: String

    init() { itemID = "" }
    init(itemID: UUID) { self.itemID = itemID.uuidString }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let uuid = UUID(uuidString: itemID) else {
            return .result(dialog: "Couldn't find that item.")
        }
        let context = ModelContainerProvider.shared.mainContext
        let items = (try? context.fetch(FetchDescriptor<StashItem>())) ?? []
        guard let item = items.first(where: { $0.id == uuid }) else {
            return .result(dialog: "That item is no longer in your stash.")
        }
        let remaining = item.consumeOneUnit(in: context)
        Self.reloadTimelines()
        if remaining == 0 {
            return .result(dialog: "Used the last \(item.name).")
        }
        return .result(dialog: "Used one \(item.name). \(remaining) left.")
    }

    private static func reloadTimelines() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

struct SnoozeStashItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Remind Tomorrow"
    static let description = IntentDescription("Pushes an item's expiry reminder by one day.")
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Item ID")
    var itemID: String

    init() { itemID = "" }
    init(itemID: UUID) { self.itemID = itemID.uuidString }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let uuid = UUID(uuidString: itemID) else {
            return .result(dialog: "Couldn't find that item.")
        }
        let context = ModelContainerProvider.shared.mainContext
        let items = (try? context.fetch(FetchDescriptor<StashItem>())) ?? []
        guard let item = items.first(where: { $0.id == uuid }) else {
            return .result(dialog: "That item is no longer in your stash.")
        }
        item.snoozeExpiry(days: 1, in: context)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        return .result(dialog: "I'll remind you about \(item.name) tomorrow.")
    }
}
