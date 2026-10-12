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

nonisolated struct InventoryImportResult: Sendable {
    var inserted: Int
    var updated: Int
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
    var recognizedText: String?
    var priceAmount: Double?
    var priceCurrency: String?
    var priceDetectedAutomatically: Bool
    var barcodePayload: String?
    var barcodeLookupSource: String?
    var expiryUserConfirmed: Bool
    var locationID: UUID?
    var photoFilenames: [String]
    var nutritionServingSize: String?
    var nutritionCalories: Int?
    var nutritionProteinGrams: Double?
    var nutritionCarbsGrams: Double?
    var nutritionSugarGrams: Double?
    var nutritionFatGrams: Double?
    var nutritionFiberGrams: Double?
    var nutritionSodiumMilligrams: Double?
    var ingredients: String?

    enum CodingKeys: String, CodingKey {
        case id, name, category, subcategory, quantity, unit, isPerishable, expiryDate
        case notes, tags, recognizedText, priceAmount, priceCurrency, priceDetectedAutomatically
        case barcodePayload, barcodeLookupSource, expiryUserConfirmed, locationID, photoFilenames
        case nutritionServingSize, nutritionCalories, nutritionProteinGrams, nutritionCarbsGrams
        case nutritionSugarGrams, nutritionFatGrams, nutritionFiberGrams, nutritionSodiumMilligrams
        case ingredients
    }

    init(
        id: UUID,
        name: String,
        category: String,
        subcategory: String?,
        quantity: Int,
        unit: String?,
        isPerishable: Bool,
        expiryDate: Date?,
        notes: String?,
        tags: [String],
        recognizedText: String?,
        priceAmount: Double?,
        priceCurrency: String?,
        priceDetectedAutomatically: Bool,
        barcodePayload: String?,
        barcodeLookupSource: String?,
        expiryUserConfirmed: Bool,
        locationID: UUID?,
        photoFilenames: [String],
        nutritionServingSize: String?,
        nutritionCalories: Int?,
        nutritionProteinGrams: Double?,
        nutritionCarbsGrams: Double?,
        nutritionSugarGrams: Double?,
        nutritionFatGrams: Double?,
        nutritionFiberGrams: Double?,
        nutritionSodiumMilligrams: Double?,
        ingredients: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.subcategory = subcategory
        self.quantity = quantity
        self.unit = unit
        self.isPerishable = isPerishable
        self.expiryDate = expiryDate
        self.notes = notes
        self.tags = tags
        self.recognizedText = recognizedText
        self.priceAmount = priceAmount
        self.priceCurrency = priceCurrency
        self.priceDetectedAutomatically = priceDetectedAutomatically
        self.barcodePayload = barcodePayload
        self.barcodeLookupSource = barcodeLookupSource
        self.expiryUserConfirmed = expiryUserConfirmed
        self.locationID = locationID
        self.photoFilenames = photoFilenames
        self.nutritionServingSize = nutritionServingSize
        self.nutritionCalories = nutritionCalories
        self.nutritionProteinGrams = nutritionProteinGrams
        self.nutritionCarbsGrams = nutritionCarbsGrams
        self.nutritionSugarGrams = nutritionSugarGrams
        self.nutritionFatGrams = nutritionFatGrams
        self.nutritionFiberGrams = nutritionFiberGrams
        self.nutritionSodiumMilligrams = nutritionSodiumMilligrams
        self.ingredients = ingredients
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        category = try container.decode(String.self, forKey: .category)
        subcategory = try container.decodeIfPresent(String.self, forKey: .subcategory)
        quantity = try container.decode(Int.self, forKey: .quantity)
        unit = try container.decodeIfPresent(String.self, forKey: .unit)
        isPerishable = try container.decode(Bool.self, forKey: .isPerishable)
        expiryDate = try container.decodeIfPresent(Date.self, forKey: .expiryDate)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        recognizedText = try container.decodeIfPresent(String.self, forKey: .recognizedText)
        priceAmount = try container.decodeIfPresent(Double.self, forKey: .priceAmount)
        priceCurrency = try container.decodeIfPresent(String.self, forKey: .priceCurrency)
        priceDetectedAutomatically = try container.decodeIfPresent(Bool.self, forKey: .priceDetectedAutomatically) ?? false
        barcodePayload = try container.decodeIfPresent(String.self, forKey: .barcodePayload)
        barcodeLookupSource = try container.decodeIfPresent(String.self, forKey: .barcodeLookupSource)
        expiryUserConfirmed = try container.decodeIfPresent(Bool.self, forKey: .expiryUserConfirmed) ?? false
        locationID = try container.decodeIfPresent(UUID.self, forKey: .locationID)
        photoFilenames = try container.decodeIfPresent([String].self, forKey: .photoFilenames) ?? []
        nutritionServingSize = try container.decodeIfPresent(String.self, forKey: .nutritionServingSize)
        nutritionCalories = try container.decodeIfPresent(Int.self, forKey: .nutritionCalories)
        nutritionProteinGrams = try container.decodeIfPresent(Double.self, forKey: .nutritionProteinGrams)
        nutritionCarbsGrams = try container.decodeIfPresent(Double.self, forKey: .nutritionCarbsGrams)
        nutritionSugarGrams = try container.decodeIfPresent(Double.self, forKey: .nutritionSugarGrams)
        nutritionFatGrams = try container.decodeIfPresent(Double.self, forKey: .nutritionFatGrams)
        nutritionFiberGrams = try container.decodeIfPresent(Double.self, forKey: .nutritionFiberGrams)
        nutritionSodiumMilligrams = try container.decodeIfPresent(Double.self, forKey: .nutritionSodiumMilligrams)
        ingredients = try container.decodeIfPresent(String.self, forKey: .ingredients)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(category, forKey: .category)
        try container.encodeIfPresent(subcategory, forKey: .subcategory)
        try container.encode(quantity, forKey: .quantity)
        try container.encodeIfPresent(unit, forKey: .unit)
        try container.encode(isPerishable, forKey: .isPerishable)
        try container.encodeIfPresent(expiryDate, forKey: .expiryDate)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(recognizedText, forKey: .recognizedText)
        try container.encodeIfPresent(priceAmount, forKey: .priceAmount)
        try container.encodeIfPresent(priceCurrency, forKey: .priceCurrency)
        try container.encode(priceDetectedAutomatically, forKey: .priceDetectedAutomatically)
        try container.encodeIfPresent(barcodePayload, forKey: .barcodePayload)
        try container.encodeIfPresent(barcodeLookupSource, forKey: .barcodeLookupSource)
        try container.encode(expiryUserConfirmed, forKey: .expiryUserConfirmed)
        try container.encodeIfPresent(locationID, forKey: .locationID)
        try container.encode(photoFilenames, forKey: .photoFilenames)
        try container.encodeIfPresent(nutritionServingSize, forKey: .nutritionServingSize)
        try container.encodeIfPresent(nutritionCalories, forKey: .nutritionCalories)
        try container.encodeIfPresent(nutritionProteinGrams, forKey: .nutritionProteinGrams)
        try container.encodeIfPresent(nutritionCarbsGrams, forKey: .nutritionCarbsGrams)
        try container.encodeIfPresent(nutritionSugarGrams, forKey: .nutritionSugarGrams)
        try container.encodeIfPresent(nutritionFatGrams, forKey: .nutritionFatGrams)
        try container.encodeIfPresent(nutritionFiberGrams, forKey: .nutritionFiberGrams)
        try container.encodeIfPresent(nutritionSodiumMilligrams, forKey: .nutritionSodiumMilligrams)
        try container.encodeIfPresent(ingredients, forKey: .ingredients)
    }
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
                recognizedText: item.recognizedText,
                priceAmount: item.priceAmount,
                priceCurrency: item.priceCurrency,
                priceDetectedAutomatically: item.priceDetectedAutomatically,
                barcodePayload: item.barcodePayload,
                barcodeLookupSource: item.barcodeLookupSource,
                expiryUserConfirmed: item.expiryUserConfirmed,
                locationID: item.location?.id,
                photoFilenames: item.photoFilenames,
                nutritionServingSize: item.nutritionServingSize,
                nutritionCalories: item.nutritionCalories,
                nutritionProteinGrams: item.nutritionProteinGrams,
                nutritionCarbsGrams: item.nutritionCarbsGrams,
                nutritionSugarGrams: item.nutritionSugarGrams,
                nutritionFatGrams: item.nutritionFatGrams,
                nutritionFiberGrams: item.nutritionFiberGrams,
                nutritionSodiumMilligrams: item.nutritionSodiumMilligrams,
                ingredients: item.ingredients
            )
        }
        let backup = InventoryBackup(exportedAt: .now, items: itemRecords, locations: locationRecords)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    @MainActor
    static func importBackup(_ data: Data, into context: ModelContext) throws -> InventoryImportResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(InventoryBackup.self, from: data)

        let existingLocations = (try? context.fetch(FetchDescriptor<StorageLocation>())) ?? []
        var locationByID: [UUID: StorageLocation] = Dictionary(uniqueKeysWithValues: existingLocations.map { ($0.id, $0) })

        for record in backup.locations {
            if let existing = locationByID[record.id] {
                existing.name = record.name
                existing.iconSystemName = record.iconSystemName
            } else {
                let location = StorageLocation(name: record.name, iconSystemName: record.iconSystemName)
                location.id = record.id
                context.insert(location)
                locationByID[record.id] = location
            }
        }
        for record in backup.locations {
            locationByID[record.id]?.parent = record.parentID.flatMap { locationByID[$0] }
        }

        let existingItems = (try? context.fetch(FetchDescriptor<StashItem>())) ?? []
        var itemByID: [UUID: StashItem] = Dictionary(uniqueKeysWithValues: existingItems.map { ($0.id, $0) })
        var inserted = 0
        var updated = 0

        for record in backup.items {
            if let existing = itemByID[record.id] {
                apply(record, to: existing, locationByID: locationByID, keepLocalPhotos: true)
                updated += 1
            } else {
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
                    priceDetectedAutomatically: record.priceDetectedAutomatically,
                    barcodePayload: record.barcodePayload,
                    barcodeLookupSource: record.barcodeLookupSource
                )
                apply(record, to: item, locationByID: locationByID, keepLocalPhotos: false)
                item.id = record.id
                context.insert(item)
                itemByID[record.id] = item
                inserted += 1
            }
        }

        try context.save()
        return InventoryImportResult(inserted: inserted, updated: updated)
    }

    @MainActor
    private static func apply(
        _ record: ItemRecord,
        to item: StashItem,
        locationByID: [UUID: StorageLocation],
        keepLocalPhotos: Bool
    ) {
        item.name = record.name
        item.category = record.category
        item.subcategory = record.subcategory
        item.quantity = record.quantity
        item.unit = record.unit
        item.isPerishable = record.isPerishable
        item.expiryDate = record.expiryDate
        item.expiryUserConfirmed = record.expiryUserConfirmed
        item.notes = record.notes
        item.recognizedText = record.recognizedText
        item.tags = record.tags
        item.priceAmount = record.priceAmount
        item.priceCurrency = record.priceCurrency
        item.priceDetectedAutomatically = record.priceDetectedAutomatically
        item.barcodePayload = record.barcodePayload
        item.barcodeLookupSource = record.barcodeLookupSource
        item.location = record.locationID.flatMap { locationByID[$0] }
        if !keepLocalPhotos {
            item.photoFilenames = record.photoFilenames
        }
        item.nutritionServingSize = record.nutritionServingSize
        item.nutritionCalories = record.nutritionCalories
        item.nutritionProteinGrams = record.nutritionProteinGrams
        item.nutritionCarbsGrams = record.nutritionCarbsGrams
        item.nutritionSugarGrams = record.nutritionSugarGrams
        item.nutritionFatGrams = record.nutritionFatGrams
        item.nutritionFiberGrams = record.nutritionFiberGrams
        item.nutritionSodiumMilligrams = record.nutritionSodiumMilligrams
        item.ingredients = record.ingredients
        item.updatedAt = .now
    }
}
