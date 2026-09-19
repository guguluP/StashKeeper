import Testing
import Foundation
import SwiftData
@testable import StashKeeper

@Suite("Expiry and export")
struct ExpiryLogicTests {

    @Test @MainActor func needingAttentionOrdersSoonestFirst() throws {
        let container = try ModelContainer(
            for: StashItem.self, StorageLocation.self, StreakRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let expired = StashItem(name: "Milk", category: "Dairy", isPerishable: true, expiryDate: Date().addingTimeInterval(-86_400))
        let soon = StashItem(name: "Yogurt", category: "Dairy", isPerishable: true, expiryDate: Date().addingTimeInterval(86_400))
        let fresh = StashItem(name: "Rice", category: "Pantry & Food", isPerishable: true, expiryDate: Date().addingTimeInterval(86_400 * 30))
        let durable = StashItem(name: "Hammer", category: "Tools & Hardware", isPerishable: false)

        for item in [expired, soon, fresh, durable] { context.insert(item) }

        let attention = StashItem.needingAttention(in: [expired, soon, fresh, durable])
        #expect(attention.map(\.name) == ["Milk", "Yogurt"])
    }

    @Test func settingsClampsWarningWindow() {
        #expect(StashSettings.clamp(5) == 5)
        #expect(StashSettings.clamp(99) == StashSettings.defaultWarningWindowDays)
        #expect(StashSettings.clamp(3) == 3)
    }

    @Test @MainActor func inventoryExportRoundTrip() throws {
        let container = try ModelContainer(
            for: StashItem.self, StorageLocation.self, StreakRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let loc = StorageLocation(name: "Fridge")
        context.insert(loc)
        let item = StashItem(name: "Milk", category: "Dairy", quantity: 2, isPerishable: true, location: loc)
        context.insert(item)
        try context.save()

        let data = try InventoryExport.makeBackup(items: [item], locations: [loc])
        let empty = try ModelContainer(
            for: StashItem.self, StorageLocation.self, StreakRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let importContext = ModelContext(empty)
        let count = try InventoryExport.importBackup(data, into: importContext)
        #expect(count == 1)
        let imported = try importContext.fetch(FetchDescriptor<StashItem>())
        #expect(imported.first?.name == "Milk")
        #expect(imported.first?.location?.name == "Fridge")
    }
}
