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
