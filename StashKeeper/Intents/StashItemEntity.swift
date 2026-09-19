//
//  StashItemEntity.swift
//  StashKeeper
//
//  App Entity + Spotlight IndexedEntity so Siri AI can resolve items by
//  meaning ("the milk in the fridge") and View Annotations can point at
//  on-screen rows. Donated into the semantic index on launch and after
//  catalog writes.
//

import AppIntents
import CoreSpotlight
import SwiftData
import SwiftUI

struct StashItemEntity: AppEntity, IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Stash Item")
    }

    static let defaultQuery = StashItemEntityQuery()

    var id: UUID
    var name: String
    var category: String
    var locationName: String
    var quantity: Int
    var expiryCaption: String
    var isPerishable: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(locationName) · ×\(quantity)",
            image: .init(systemName: "shippingbox.fill")
        )
    }

    var defaultAttributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = name
        attributes.displayName = name
        attributes.keywords = [name, category, locationName]
        attributes.contentDescription = [category, locationName, expiryCaption]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        attributes.namedLocation = locationName
        return attributes
    }

    @MainActor
    init(from item: StashItem) {
        id = item.id
        name = item.name
        category = item.category
        locationName = item.location?.name ?? "Unsorted"
        quantity = item.quantity
        expiryCaption = item.expiryCaption
        isPerishable = item.isPerishable
    }
}

struct StashItemEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [StashItemEntity] {
        await MainActor.run {
            let context = ModelContainerProvider.shared.mainContext
            let items = (try? context.fetch(FetchDescriptor<StashItem>())) ?? []
            let wanted = Set(identifiers)
            return items.filter { wanted.contains($0.id) }.map(StashItemEntity.init(from:))
        }
    }

    func suggestedEntities() async throws -> [StashItemEntity] {
        await MainActor.run {
            let context = ModelContainerProvider.shared.mainContext
            let items = (try? context.fetch(FetchDescriptor<StashItem>())) ?? []
            return StashItem.needingAttention(in: items).prefix(8).map(StashItemEntity.init(from:))
        }
    }
}

extension StashItemEntityQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [StashItemEntity] {
        await MainActor.run {
            let context = ModelContainerProvider.shared.mainContext
            let items = (try? context.fetch(FetchDescriptor<StashItem>())) ?? []
            return items
                .filter { $0.searchableText.localizedCaseInsensitiveContains(string) }
                .prefix(15)
                .map(StashItemEntity.init(from:))
        }
    }
}

enum SpotlightIndexer {
    @MainActor
    static func reindexAll() async {
        let context = ModelContainerProvider.shared.mainContext
        let items = (try? context.fetch(FetchDescriptor<StashItem>())) ?? []
        let entities = items.map(StashItemEntity.init(from:))
        do {
            try await CSSearchableIndex.default().deleteAllSearchableItems()
            try await CSSearchableIndex.default().indexAppEntities(entities)
        } catch {
            // Indexing is best-effort — catalog writes still succeed.
        }
    }

    @MainActor
    static func index(item: StashItem) async {
        do {
            try await CSSearchableIndex.default().indexAppEntities([StashItemEntity(from: item)])
        } catch {}
    }

    static func remove(id: UUID) async {
        do {
            try await CSSearchableIndex.default().deleteAppEntities(
                identifiedBy: [id],
                ofType: StashItemEntity.self
            )
        } catch {}
    }
}

struct OpenStashItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Stash Item"
    static let description = IntentDescription("Opens an item in StashKeeper.")
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Item")
    var item: StashItemEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$item)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: .openStashItem,
            object: nil,
            userInfo: ["itemID": item.id]
        )
        return .result()
    }
}

extension Notification.Name {
    static let openStashItem = Notification.Name("openStashItem")
}

struct ExpiringSnippetView: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Needs attention", systemImage: "clock.badge.exclamationmark")
                .font(.headline)
                .foregroundStyle(.orange)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.subheadline)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
