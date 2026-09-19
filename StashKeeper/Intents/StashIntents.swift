//
//  StashIntents.swift
//  StashKeeper
//
//  App Intents power Siri requests, Shortcuts automations, and Spotlight
//  actions, e.g. "Ask StashKeeper what's expiring soon" or a Shortcuts
//  automation that runs every morning.
//

import AppIntents
import SwiftData
import SwiftUI

struct WhatsExpiringIntent: AppIntent {

    static let title: LocalizedStringResource = "What's Expiring Soon"
    static let description = IntentDescription(
        "Lists items in your stash that are expiring soon or have expired."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog & ShowsSnippetView {
        let context = ModelContainerProvider.shared.mainContext
        let descriptor = FetchDescriptor<StashItem>()
        let items = (try? context.fetch(descriptor)) ?? []
        let attention = ExpiryEngine.shared.attentionNeeded(items: items)

        guard !attention.isEmpty else {
            return .result(value: [], dialog: "Nothing is expiring soon. You're all caught up.", view: ExpiringSnippetView(lines: ["All clear"]))
        }

        let summaries = attention.prefix(10).map { item -> String in
            let where_ = item.location?.name ?? "your stash"
            if item.expiryStatus == .expired {
                return "\(item.name) at \(where_) has expired"
            }
            let days = item.daysUntilExpiry ?? 0
            return "\(item.name) at \(where_), expiring in \(days) day\(days == 1 ? "" : "s")"
        }

        let dialog = "You have \(attention.count) item\(attention.count == 1 ? "" : "s") needing attention: " + summaries.joined(separator: "; ")
        return .result(value: summaries, dialog: IntentDialog(stringLiteral: dialog), view: ExpiringSnippetView(lines: Array(summaries)))
    }
}

struct FindItemIntent: AppIntent {

    static let title: LocalizedStringResource = "Find an Item in Storage"
    static let description = IntentDescription(
        "Finds where an item is stored, e.g. 'Where is my passport?'"
    )

    @Parameter(title: "Item Name")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Find \(\.$query) in storage")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let context = ModelContainerProvider.shared.mainContext
        let descriptor = FetchDescriptor<StashItem>()
        let items = (try? context.fetch(descriptor)) ?? []

        let matches = items.filter { $0.searchableText.localizedCaseInsensitiveContains(query) }

        guard let first = matches.first else {
            return .result(value: "", dialog: "I couldn't find anything matching \"\(query)\" in your stash.")
        }

        let locationName = first.location?.name ?? "an unspecified location"
        let dialog: String
        if matches.count == 1 {
            dialog = "\(first.name) is kept at \(locationName)."
        } else {
            dialog = "\(first.name) is kept at \(locationName). I found \(matches.count) matching items total."
        }
        return .result(value: locationName, dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct HowManyItemsIntent: AppIntent {

    static let title: LocalizedStringResource = "How Many of an Item"
    static let description = IntentDescription(
        "Tells you how many of a given item you have in your stash, e.g. 'How many AA batteries do I have?'"
    )

    @Parameter(title: "Item Name")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("How many \(\.$query) do I have")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let context = ModelContainerProvider.shared.mainContext
        let descriptor = FetchDescriptor<StashItem>()
        let items = (try? context.fetch(descriptor)) ?? []

        let matches = items.filter { $0.searchableText.localizedCaseInsensitiveContains(query) }
        let total = matches.reduce(0) { $0 + $1.quantity }

        guard !matches.isEmpty else {
            return .result(value: 0, dialog: "I couldn't find anything matching \"\(query)\" in your stash.")
        }

        let dialog: String
        if matches.count == 1, let only = matches.first {
            dialog = "You have \(total) \(only.name)\(total == 1 ? "" : "s")."
        } else {
            let locations = Set(matches.compactMap { $0.location?.name }).sorted()
            let locationNote = locations.isEmpty ? "" : ", across \(locations.joined(separator: ", "))"
            dialog = "You have \(total) total across \(matches.count) matching entries\(locationNote)."
        }
        return .result(value: total, dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct ItemsInLocationIntent: AppIntent {

    static let title: LocalizedStringResource = "List Items in a Location"
    static let description = IntentDescription(
        "Lists what's stored in a specific place, e.g. 'What's in my fridge?'"
    )

    @Parameter(title: "Location Name")
    var location: String

    static var parameterSummary: some ParameterSummary {
        Summary("What's in \(\.$location)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let context = ModelContainerProvider.shared.mainContext
        let descriptor = FetchDescriptor<StashItem>()
        let items = (try? context.fetch(descriptor)) ?? []

        let matches = items.filter {
            $0.location?.name.localizedCaseInsensitiveContains(location) ?? false
        }

        guard !matches.isEmpty else {
            return .result(value: [], dialog: "I don't see any items stored in \"\(location)\".")
        }

        let names = matches.prefix(15).map { $0.quantity > 1 ? "\($0.name) (×\($0.quantity))" : $0.name }
        let dialog = "In \(location), you have \(matches.count) item\(matches.count == 1 ? "" : "s"): " + names.joined(separator: ", ")
        return .result(value: names, dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct ItemsInCategoryIntent: AppIntent {

    static let title: LocalizedStringResource = "List Items by Category"
    static let description = IntentDescription(
        "Lists items in a category, e.g. 'What electronics do I have stored?'"
    )

    @Parameter(title: "Category")
    var category: String

    static var parameterSummary: some ParameterSummary {
        Summary("List my \(\.$category) items")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let context = ModelContainerProvider.shared.mainContext
        let descriptor = FetchDescriptor<StashItem>()
        let items = (try? context.fetch(descriptor)) ?? []

        let matches = items.filter {
            $0.category.localizedCaseInsensitiveContains(category)
        }

        guard !matches.isEmpty else {
            return .result(value: [], dialog: "I don't see any items in the \"\(category)\" category.")
        }

        let names = matches.prefix(15).map { $0.name }
        let dialog = "You have \(matches.count) item\(matches.count == 1 ? "" : "s") in \(category): " + names.joined(separator: ", ")
        return .result(value: names, dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct TotalInventoryValueIntent: AppIntent {

    static let title: LocalizedStringResource = "Total Inventory Value"
    static let description = IntentDescription(
        "Totals up the recorded price of everything in your stash, e.g. 'How much is my stuff worth?'"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let context = ModelContainerProvider.shared.mainContext
        let descriptor = FetchDescriptor<StashItem>()
        let items = (try? context.fetch(descriptor)) ?? []

        let priced = items.filter { $0.priceAmount != nil }
        guard !priced.isEmpty else {
            return .result(value: "0", dialog: "None of your items have a recorded price yet.")
        }

        // Group by currency rather than assuming everything's the same
        // currency — StashKeeper supports multiple, and silently summing
        // across currencies would produce a meaningless number.
        let byCurrency = Dictionary(grouping: priced) { $0.priceCurrency ?? "INR" }
        let totalsDescription = byCurrency.map { currency, itemsInCurrency -> String in
            let total = itemsInCurrency.reduce(0.0) { $0 + ($1.priceAmount ?? 0) * Double($1.quantity) }
            return String(format: "%.2f %@", total, currency)
        }.joined(separator: ", plus ")

        let dialog = "Your \(priced.count) priced item\(priced.count == 1 ? "" : "s") total \(totalsDescription)."
        return .result(value: totalsDescription, dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct QuickAddItemIntent: AppIntent {

    static let title: LocalizedStringResource = "Quickly Add an Item"
    static let description = IntentDescription(
        "Adds a basic item to your stash by name, e.g. 'Add batteries to StashKeeper'. For photo-based recognition, open the app instead."
    )

    @Parameter(title: "Item Name")
    var name: String

    @Parameter(title: "Quantity", default: 1)
    var quantity: Int

    @Parameter(title: "Location", default: nil)
    var locationName: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$quantity) \(\.$name) to \(\.$locationName)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = ModelContainerProvider.shared.mainContext

        var location: StorageLocation?
        if let locationName, !locationName.isEmpty {
            let descriptor = FetchDescriptor<StorageLocation>()
            let allLocations = (try? context.fetch(descriptor)) ?? []
            location = allLocations.first {
                $0.name.localizedCaseInsensitiveCompare(locationName) == .orderedSame
            }
            if location == nil {
                let newLocation = StorageLocation(name: locationName)
                context.insert(newLocation)
                location = newLocation
            }
        }

        let item = StashItem(
            name: name,
            category: "Other",
            quantity: max(1, quantity),
            isPerishable: false,
            location: location
        )
        context.insert(item)
        try? context.save()

        let whereText = location.map { " in \($0.name)" } ?? ""
        let dialog = "Added \(quantity) \(name)\(whereText) to your stash. You can add more detail like photos or a category later in the app."
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct StashKeeperShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenAddItemIntent(),
            phrases: [
                "Add an item in \(.applicationName)",
                "Catalog something in \(.applicationName)"
            ],
            shortTitle: "Add Item",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: OpenStashItemIntent(),
            phrases: [
                "Open an item in \(.applicationName)",
                "Show me an item in \(.applicationName)"
            ],
            shortTitle: "Open Item",
            systemImageName: "shippingbox"
        )
        AppShortcut(
            intent: WhatsExpiringIntent(),
            phrases: [
                "What's expiring soon in \(.applicationName)",
                "Check \(.applicationName) for expiring items"
            ],
            shortTitle: "What's Expiring",
            systemImageName: "clock.badge.exclamationmark"
        )
        AppShortcut(
            intent: FindItemIntent(),
            phrases: [
                "Find an item in \(.applicationName)",
                "Where is my item in \(.applicationName)"
            ],
            shortTitle: "Find Item",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: HowManyItemsIntent(),
            phrases: [
                "How many items do I have in \(.applicationName)",
                "Check my item count in \(.applicationName)"
            ],
            shortTitle: "How Many",
            systemImageName: "number"
        )
        AppShortcut(
            intent: ItemsInLocationIntent(),
            phrases: [
                "What's in my storage location in \(.applicationName)",
                "List items by location in \(.applicationName)"
            ],
            shortTitle: "Items by Location",
            systemImageName: "archivebox"
        )
        AppShortcut(
            intent: ItemsInCategoryIntent(),
            phrases: [
                "List my items by category in \(.applicationName)",
                "What category items do I have in \(.applicationName)"
            ],
            shortTitle: "Items by Category",
            systemImageName: "square.grid.2x2"
        )
        AppShortcut(
            intent: TotalInventoryValueIntent(),
            phrases: [
                "How much is my stuff worth in \(.applicationName)",
                "Total inventory value in \(.applicationName)"
            ],
            shortTitle: "Total Value",
            systemImageName: "indianrupeesign.circle"
        )
        AppShortcut(
            intent: QuickAddItemIntent(),
            phrases: [
                "Add an item to \(.applicationName)",
                "Quickly add something to \(.applicationName)"
            ],
            shortTitle: "Quick Add",
            systemImageName: "plus.circle"
        )
    }
}



