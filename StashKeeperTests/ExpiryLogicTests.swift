import Testing
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
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

        let empty = StashItem(name: "Empty yogurt", category: "Dairy", quantity: 0, isPerishable: true, expiryDate: Date().addingTimeInterval(-3_600))
        let attention = StashItem.needingAttention(in: [expired, soon, fresh, durable, empty])
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
        #expect(count.inserted == 1)
        #expect(count.updated == 0)
        let imported = try importContext.fetch(FetchDescriptor<StashItem>())
        #expect(imported.first?.name == "Milk")
        #expect(imported.first?.location?.name == "Fridge")

        item.quantity = 5
        item.nutritionCalories = 42
        item.notes = "Opened"
        let updatedData = try InventoryExport.makeBackup(items: [item], locations: [loc])
        let again = try InventoryExport.importBackup(updatedData, into: importContext)
        #expect(again.inserted == 0)
        #expect(again.updated == 1)
        let refreshed = try importContext.fetch(FetchDescriptor<StashItem>())
        #expect(refreshed.count == 1)
        #expect(refreshed.first?.quantity == 5)
        #expect(refreshed.first?.nutritionCalories == 42)
        #expect(refreshed.first?.notes == "Opened")
    }

    @Test @MainActor func differentExpiryStaysASeparateLot() throws {
        let container = try ModelContainer(
            for: StashItem.self, StorageLocation.self, StreakRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let firstDay = Date(timeIntervalSince1970: 1_700_000_000)
        let nextDay = Calendar.current.date(byAdding: .day, value: 10, to: firstDay)!
        let existing = StashItem(
            name: "Dairy Milk",
            category: "Pantry & Food",
            isPerishable: true,
            expiryDate: firstDay,
            barcodePayload: "8901058000290"
        )
        context.insert(existing)
        let snapshots = [InventorySnapshotItem(from: existing)]
        let different = ExistingItemMatcher.findMatch(
            barcodePayload: "8901058000290",
            recognizedText: [],
            candidateName: "Dairy Milk",
            candidateCategory: "Pantry & Food",
            candidateExpiry: nextDay,
            in: snapshots
        )
        let same = ExistingItemMatcher.findMatch(
            barcodePayload: "8901058000290",
            recognizedText: [],
            candidateName: "Dairy Milk",
            candidateCategory: "Pantry & Food",
            candidateExpiry: firstDay,
            in: snapshots
        )
        #expect(different == nil)
        #expect(same?.confidence == .exact)
        #expect(ExistingItemMatcher.isSameLot(existingExpiry: nil, candidateExpiry: nil))
        #expect(!ExistingItemMatcher.isSameLot(existingExpiry: firstDay, candidateExpiry: nil))
    }

    @Test @MainActor func groceryListIncludesParShortfallsAndAddedNeeds() throws {
        let container = try ModelContainer(
            for: StashItem.self, StorageLocation.self, StreakRecord.self, PurchaseNeed.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let milk = StashItem(name: "Milk", category: "Dairy", quantity: 1)
        milk.parQuantity = 3
        let rice = StashItem(name: "Rice", category: "Pantry & Food", quantity: 4)
        rice.parQuantity = 2
        context.insert(milk)
        context.insert(rice)
        let bread = PurchaseNeed(name: "Bread", quantity: 2)
        context.insert(bread)
        let bought = PurchaseNeed(name: "Eggs", quantity: 1)
        bought.isChecked = true
        context.insert(bought)
        let lines = GroceryList.lines(items: [milk, rice], needs: [bread, bought])
        #expect(lines.map(\.name) == ["Bread", "Milk"])
        #expect(lines.first { $0.name == "Milk" }?.quantity == 2)
        #expect(lines.first { $0.name == "Bread" }?.quantity == 2)
    }

    @Test func barcodeCandidatesKeepTheIndianGtin() {
        let link = BarcodeCodes.candidates(from: "https://id.gs1.org/01/08901058000290/10/LOT1")
        #expect(link.contains("8901058000290"))
        let element = BarcodeCodes.candidates(from: "(01)8901058000290")
        #expect(element.first == "8901058000290")
        let spaced = BarcodeCodes.candidates(from: "890 1058 000290")
        #expect(spaced == ["8901058000290"])
        let upc = BarcodeCodes.candidates(from: "012345678905")
        #expect(upc.contains("0012345678905"))
    }

    @Test func openFactsNameUsesBrandWhenTheTitleIsOnlyTheProduct() {
        let name = OpenFactsNaming.compose(
            productName: "maggi",
            productNameEn: "maggi",
            productNameHi: nil,
            genericName: nil,
            abbreviatedName: nil,
            brands: "Nestlé",
            quantity: "70 g"
        )
        #expect(name == "Nestlé Maggi 70 g")
    }

    @Test func packageReadNamesAChocolateWhenTheDatabaseMisses() {
        let lines = [
            OCRLine(text: "CADBURY", confidence: 0.92, boundingBox: CGRect(x: 0.1, y: 0.72, width: 0.6, height: 0.12)),
            OCRLine(text: "Dairy Milk", confidence: 0.9, boundingBox: CGRect(x: 0.1, y: 0.58, width: 0.7, height: 0.1)),
            OCRLine(text: "Silk", confidence: 0.88, boundingBox: CGRect(x: 0.12, y: 0.46, width: 0.3, height: 0.08)),
            OCRLine(text: "MRP Rs.80", confidence: 0.95, boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.04)),
            OCRLine(text: "8901234567890", confidence: 0.99, boundingBox: CGRect(x: 0.1, y: 0.08, width: 0.5, height: 0.03)),
            OCRLine(text: "Net Wt. 58g", confidence: 0.9, boundingBox: CGRect(x: 0.1, y: 0.14, width: 0.3, height: 0.03))
        ]
        let product = PackageLabelReader.product(from: lines, barcode: "8901234567890")
        #expect(product?.name == "Cadbury Dairy Milk Silk")
        #expect(product?.source == PackageLabelReader.packageSource)
        #expect(product?.category == "Pantry & Food")
        #expect(PackageLabelReader.originNote(for: "8901234567890") != nil)
        #expect(PackageLabelReader.product(from: [
            OCRLine(text: "MRP Rs.10", confidence: 0.9, boundingBox: CGRect(x: 0, y: 0, width: 0.2, height: 0.04))
        ], barcode: nil) == nil)
    }

    @Test func scanFractionAdvancesInsideOnePhoto() {
        let early = StashScanActivityController.scanFraction(photoIndex: 0, total: 1, stage: 0.2)
        let later = StashScanActivityController.scanFraction(photoIndex: 0, total: 1, stage: 0.8)
        #expect(early > 0.1)
        #expect(later > early)
        #expect(later < 1)
    }

    @Test func warningCopyUsesTheFireDate() {
        let expiry = Date(timeIntervalSince1970: 1_700_000_000)
        let fire = Calendar.current.date(byAdding: .day, value: -5, to: expiry)!
        #expect(ExpiryReminderCopy.days(from: fire, until: expiry) == 5)
        #expect(ExpiryReminderCopy.warningBody(name: "Milk", place: "Fridge", days: 5) == "Milk at Fridge expires in 5 days.")
        #expect(ExpiryReminderCopy.warningBody(name: "Milk", place: "Fridge", days: 1) == "Milk at Fridge expires tomorrow.")
        #expect(ExpiryReminderCopy.warningBody(name: "Milk", place: "Fridge", days: 0) == "Milk at Fridge expires today.")
    }

    @Test func reminderBudgetKeepsWholeItems() {
        #expect(ExpiryReminderBudget.keptCount(slotNeeds: Array(repeating: 2, count: 40)) == 31)
        #expect(ExpiryReminderBudget.keptCount(slotNeeds: [1, 1, 1], budget: 2) == 2)
        #expect(ExpiryReminderBudget.keptCount(slotNeeds: [2], budget: 1) == 0)
    }

    @Test func storeArchiveKeepsTheOriginalFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StashKeeperStoreRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("default.store")
        try Data("stash".utf8).write(to: original)
        let backup = StoreFileRecovery.archiveCopy(in: directory)
        #expect(FileManager.default.fileExists(atPath: original.path))
        let copied = try #require(backup).appendingPathComponent("default.store")
        #expect(try Data(contentsOf: copied) == Data("stash".utf8))
    }

    @Test func storeRelocateKeepsBytesInTheBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StashKeeperStoreRelocate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("default.store")
        try Data("stash".utf8).write(to: original)
        let backup = try #require(StoreFileRecovery.relocateAside(in: directory))
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(try Data(contentsOf: backup.appendingPathComponent("default.store")) == Data("stash".utf8))
    }

    @Test func chatHistoryDropsStreamingPlaceholders() throws {
        let streaming = StashChatMessage(role: .assistant, text: "", isStreaming: true)
        let kept = StashChatMessage(role: .user, text: "What's expiring?", isStreaming: false)
        let data = try JSONEncoder().encode([streaming, kept])
        let decoded = try JSONDecoder().decode([StashChatMessage].self, from: data)
        let durable = decoded.filter { !$0.isStreaming && !$0.text.isEmpty }
        #expect(durable.map(\.text) == ["What's expiring?"])
        #expect(durable.first?.role == .user)
    }

    @Test func photoAnalysisCompletesWithoutAborting() async throws {
        let width = 64
        let height = 64
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            Issue.record("Could not draw a test image")
            return
        }
        context.setFillColor(CGColor(red: 0.85, green: 0.2, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 8, y: 8, width: 40, height: 40))
        guard let filled = context.makeImage() else {
            Issue.record("Could not draw a test image")
            return
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else {
            Issue.record("Could not encode a test image")
            return
        }
        CGImageDestinationAddImage(destination, filled, nil)
        guard CGImageDestinationFinalize(destination) else {
            Issue.record("Could not encode a test image")
            return
        }

        let observations = try await VisionAnalyzer().analyze(imageData: encoded as Data)
        #expect(!observations.regions.isEmpty)
    }

    @Test func layoutFollowsWindowWidthAndRefreshRate() {
        let phone = DisplayMetrics(width: 390, height: 844, refreshRate: 60, reduceMotion: false)
        let desktop = DisplayMetrics(width: 1440, height: 900, refreshRate: 120, reduceMotion: false)
        #expect(phone.columnCount == 1)
        #expect(desktop.columnCount == 3)
        #expect(phone.horizontalPadding < desktop.horizontalPadding)
        #expect(desktop.readableWidth < desktop.width)
        #expect(desktop.attentionCardWidth > phone.attentionCardWidth)
        #expect(desktop.frameInterval < phone.frameInterval)
        #expect(DisplayMetrics(width: 800, height: 600, refreshRate: 60, reduceMotion: true).reduceMotion)
    }

    @Test func shoppingCheckFollowsTheExpiryDate() {
        let id = UUID()
        let expiry = Date(timeIntervalSince1970: 1_700_000_000)
        ShoppingListStore.setHandled(id: id, expiry: expiry, handled: true)
        #expect(ShoppingListStore.isHandled(id: id, expiry: expiry))
        #expect(!ShoppingListStore.isHandled(id: id, expiry: expiry.addingTimeInterval(86_400)))
        ShoppingListStore.setHandled(id: id, expiry: expiry, handled: false)
        #expect(!ShoppingListStore.isHandled(id: id, expiry: expiry))
    }

    @Test @MainActor func missingPhotoThumbnailStaysNil() {
        #expect(PhotoStore.thumbnailCGImage(filename: "not-a-real-photo.heic", maxPixelSize: 48) == nil)
    }
}
