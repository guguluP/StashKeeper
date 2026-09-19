//
//  InventoryExport.swift
//  StashKeeper
//
//  JSON backup / restore of catalog rows (not photo binaries). Photos stay
//  in PhotoStore; export is the portable item list for reinstall or sharing.
//

import Foundation
import SwiftData
import UniformTypeIdentifiers

nonisolated struct InventoryBackup: Codable, Sendable {
    var exportedAt: Date
    var items: [ItemRecord]
    var locations: [LocationRecord]
}

nonisolated struct LocationRecord: Codable, Sendable {
    var id: UUID
    var name: String
    var iconSystemName: String
    var parentID: UUID?
}

nonisolated struct ItemRecord: Codable, Sendable {
    var id: UUID
    var name: String
    var category: String
    var subcategory: String?
    var quantity: Int
    var unit: String?
    var isPerishable: Bool
    var expiryDate: Date?
    var notes: String?
    var tags: [String]
    var priceAmount: Double?
    var priceCurrency: String?
    var barcodePayload: String?
    var locationID: UUID?
    var photoFilenames: [String]
}

enum InventoryExport {
    static let utType = UTType.json

    @MainActor
    static func makeBackup(items: [StashItem], locations: [StorageLocation]) throws -> Data {
        let locationRecords = locations.map {
            LocationRecord(id: $0.id, name: $0.name, iconSystemName: $0.iconSystemName, parentID: $0.parent?.id)
        }
        let itemRecords = items.map { item in
            ItemRecord(
                id: item.id,
                name: item.name,
                category: item.category,
                subcategory: item.subcategory,
                quantity: item.quantity,
                unit: item.unit,
                isPerishable: item.isPerishable,
                expiryDate: item.expiryDate,
                notes: item.notes,
                tags: item.tags,
                priceAmount: item.priceAmount,
                priceCurrency: item.priceCurrency,
                barcodePayload: item.barcodePayload,
                locationID: item.location?.id,
                photoFilenames: item.photoFilenames
            )
        }
        let backup = InventoryBackup(exportedAt: .now, items: itemRecords, locations: locationRecords)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    @MainActor
    static func importBackup(_ data: Data, into context: ModelContext) throws -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(InventoryBackup.self, from: data)

        let existingLocations = (try? context.fetch(FetchDescriptor<StorageLocation>())) ?? []
        var locationByID: [UUID: StorageLocation] = Dictionary(uniqueKeysWithValues: existingLocations.map { ($0.id, $0) })

        for record in backup.locations {
            if locationByID[record.id] == nil {
                let location = StorageLocation(name: record.name, iconSystemName: record.iconSystemName)
                location.id = record.id
                context.insert(location)
                locationByID[record.id] = location
            }
        }
        for record in backup.locations {
            if let parentID = record.parentID {
                locationByID[record.id]?.parent = locationByID[parentID]
            }
        }

        let existingItems = (try? context.fetch(FetchDescriptor<StashItem>())) ?? []
        let existingIDs = Set(existingItems.map(\.id))
        var imported = 0

        for record in backup.items where !existingIDs.contains(record.id) {
            let item = StashItem(
                name: record.name,
                category: record.category,
                subcategory: record.subcategory,
                quantity: record.quantity,
                unit: record.unit,
                isPerishable: record.isPerishable,
                expiryDate: record.expiryDate,
                notes: record.notes,
                tags: record.tags,
                location: record.locationID.flatMap { locationByID[$0] },
                photoFilenames: record.photoFilenames,
                priceAmount: record.priceAmount,
                priceCurrency: record.priceCurrency,
                barcodePayload: record.barcodePayload
            )
            item.id = record.id
            context.insert(item)
            imported += 1
        }

        try context.save()
        return imported
    }
}
