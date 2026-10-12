//
//  GroceryIntents.swift
//  StashKeeper
//
//  Siri and Shortcuts can ask what to buy, add a grocery, or mark one
//  bought. The returned list is a normal Shortcuts value, so it can be
//  passed into Reminders, Notes, or any other app action.
//

import AppIntents
import SwiftData
import SwiftUI

struct GroceryLineEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Grocery to Buy")
    }

    static let defaultQuery = GroceryLineQuery()

    var id: String
    var name: String
    var quantity: Int
    var detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "Buy \(quantity) · \(detail)",
            image: .init(systemName: "cart")
        )
    }

    init(_ line: GroceryLine) {
        id = line.id
        name = line.name
        quantity = line.quantity
        detail = line.detail
    }
}

struct GroceryLineQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [GroceryLineEntity.ID]) async throws -> [GroceryLineEntity] {
        let lines = GroceryList.current(in: ModelContainerProvider.shared.mainContext)
        let wanted = Set(identifiers)
        return lines.filter { wanted.contains($0.id) }.map(GroceryLineEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [GroceryLineEntity] {
        GroceryList.current(in: ModelContainerProvider.shared.mainContext).map(GroceryLineEntity.init)
    }
}

struct GroceriesNeededIntent: AppIntent {
    static let title: LocalizedStringResource = "What Groceries Do I Need"
    static let description = IntentDescription(
        "Lists groceries to buy: items below the amount you keep, plus anything added to the buy list. Shortcuts can pass this list to Reminders or another app."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[GroceryLineEntity]> & ProvidesDialog & ShowsSnippetView {
        let lines = GroceryList.current(in: ModelContainerProvider.shared.mainContext)
        await GroceryList.publish()
        guard !lines.isEmpty else {
            return .result(
                value: [],
                dialog: "You don't need to buy any groceries right now.",
                view: GrocerySnippetView(lines: ["Nothing to buy"])
            )
        }
        let entities = lines.map(GroceryLineEntity.init)
        let spoken = lines.map(\.spoken).joined(separator: ", ")
        let dialog = "You need \(lines.count) grocery item\(lines.count == 1 ? "" : "s"): \(spoken)."
        return .result(
            value: entities,
            dialog: IntentDialog(stringLiteral: dialog),
            view: GrocerySnippetView(lines: lines.map(\.spoken))
        )
    }
}

struct AddGroceryNeedIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a Grocery to Buy"
    static let description = IntentDescription("Adds something to the StashKeeper buy list, for example milk.")

    @Parameter(title: "Grocery")
    var name: String

    @Parameter(title: "Quantity", default: 1)
    var quantity: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$quantity) \(\.$name) to the buy list")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "Tell me the name of the grocery to add.")
        }
        let context = ModelContainerProvider.shared.mainContext
        context.insert(PurchaseNeed(name: trimmed, quantity: max(1, quantity)))
        try? context.save()
        await GroceryList.publish()
        return .result(dialog: "Added \(max(1, quantity)) \(trimmed) to your buy list.")
    }
}

struct MarkGroceryBoughtIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark a Grocery as Bought"
    static let description = IntentDescription("Removes a grocery from the buy list, or restocks a kept item up to the amount you keep.")

    @Parameter(title: "Grocery")
    var grocery: GroceryLineEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Mark \(\.$grocery) as bought")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = ModelContainerProvider.shared.mainContext
        if grocery.id.hasPrefix("need:"),
           let uuid = UUID(uuidString: String(grocery.id.dropFirst("need:".count))) {
            let needs = (try? context.fetch(FetchDescriptor<PurchaseNeed>())) ?? []
            if let need = needs.first(where: { $0.id == uuid }) {
                need.isChecked = true
                try? context.save()
                await GroceryList.publish()
                return .result(dialog: "Marked \(grocery.name) as bought.")
            }
        }
        if grocery.id.hasPrefix("par:"),
           let uuid = UUID(uuidString: String(grocery.id.dropFirst("par:".count))) {
            let items = (try? context.fetch(FetchDescriptor<StashItem>())) ?? []
            if let item = items.first(where: { $0.id == uuid }) {
                let added = max(0, item.parQuantity - item.quantity)
                item.quantity = max(item.quantity, item.parQuantity)
                item.noteChange("bought \(added)")
                try? context.save()
                await StashItemLifecycle.afterEdit(item, in: context)
                return .result(dialog: "Restocked \(item.name) to \(item.quantity).")
            }
        }
        return .result(dialog: "That grocery is no longer on the buy list.")
    }
}

struct GrocerySnippetView: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("To buy", systemImage: "cart")
                .font(.headline)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.subheadline)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
