//
//  IndianFMCGBarcodeCache.swift
//  StashKeeper
//
//  A third-tier barcode fallback specifically for Indian FMCG/grocery
//  products that Open Food Facts and UPCitemdb frequently miss — both
//  databases lean on community contributions and skew toward US/EU
//  packaged goods, so many Indian regional/local brands (and even some
//  national ones under region-specific EAN prefixes) come back empty.
//
//  This is intentionally NOT meant to be exhaustive. It's a small seed set
//  of common household staples plus a growing on-device cache: whenever
//  the user manually corrects/confirms a product name for a barcode that
//  came back unmatched from both online sources, we remember that mapping
//  locally so the same product resolves instantly next time — the barcode
//  scanning gets better with real use instead of staying static.
//
//  This entire file has zero network dependency; the seed table is
//  bundled, and learned mappings are persisted to UserDefaults (a JSON
//  blob small enough that UserDefaults is a fine store for it — this is
//  not meant to scale to thousands of entries, just the products one
//  household actually keeps buying).
//

import Foundation

actor IndianFMCGBarcodeCache {

    static let shared = IndianFMCGBarcodeCache()

    private let defaults = UserDefaults.standard
    private let learnedKey = "StashKeeper.learnedIndianBarcodes"

    /// Small seed set of common Indian packaged-goods barcodes, keyed by
    /// EAN/UPC payload. Intentionally minimal — the goal is to demonstrate
    /// and bootstrap the fallback tier, not replace a real product
    /// database. Expand this list as real gaps are logged via
    /// `BarcodeLookupTelemetry`.
    private static let seedTable: [String: LookedUpProduct] = [
        // Amul (dairy) — widely sold, patchy OFF coverage for regional SKUs
        "8901262010518": LookedUpProduct(
            name: "Amul Gold Full Cream Milk", brand: "Amul", category: "Dairy",
            rawNutritionText: nil, imageURL: nil, source: "Local Indian FMCG Cache"
        ),
        "8901262011041": LookedUpProduct(
            name: "Amul Butter", brand: "Amul", category: "Dairy",
            rawNutritionText: nil, imageURL: nil, source: "Local Indian FMCG Cache"
        ),
        // Tata (staples)
        "8901030002461": LookedUpProduct(
            name: "Tata Salt", brand: "Tata", category: "Pantry & Food",
            rawNutritionText: nil, imageURL: nil, source: "Local Indian FMCG Cache"
        ),
        // Britannia (bakery/snacks)
        "8901063017806": LookedUpProduct(
            name: "Britannia Good Day Cookies", brand: "Britannia", category: "Pantry & Food",
            rawNutritionText: nil, imageURL: nil, source: "Local Indian FMCG Cache"
        ),
        // Parle (snacks)
        "8901719110016": LookedUpProduct(
            name: "Parle-G Biscuits", brand: "Parle", category: "Pantry & Food",
            rawNutritionText: nil, imageURL: nil, source: "Local Indian FMCG Cache"
        ),
    ]

    /// Checks the seed table first, then the on-device learned cache.
    func lookup(barcode: String) -> LookedUpProduct? {
        if let seeded = Self.seedTable[barcode] {
            return seeded
        }
        return learnedEntries()[barcode]
    }

    /// Called when the user confirms/edits a name for an item whose
    /// barcode had no match from any lookup tier — persists the mapping
    /// so re-scanning the same product next time resolves immediately,
    /// without needing a network round trip or AI re-analysis.
    func learn(barcode: String, name: String, category: String) {
        var entries = learnedEntries()
        entries[barcode] = LookedUpProduct(
            name: name,
            brand: nil,
            category: category,
            rawNutritionText: nil,
            imageURL: nil,
            source: "Learned on this device"
        )
        saveLearnedEntries(entries)
    }

    private func learnedEntries() -> [String: LookedUpProduct] {
        guard let data = defaults.data(forKey: learnedKey),
              let decoded = try? JSONDecoder().decode([String: PersistedProduct].self, from: data) else {
            return [:]
        }
        return decoded.mapValues(\.asLookedUpProduct)
    }

    private func saveLearnedEntries(_ entries: [String: LookedUpProduct]) {
        let persisted = entries.mapValues(PersistedProduct.init)
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        defaults.set(data, forKey: learnedKey)
    }
}

/// `LookedUpProduct` isn't `Codable` (it's a lookup-tier value type shared
/// with the network services), so this is a small Codable mirror used only
/// for UserDefaults persistence of learned entries.
private nonisolated struct PersistedProduct: Codable {
    let name: String
    let brand: String?
    let category: String?
    let source: String

    init(from product: LookedUpProduct) {
        self.name = product.name
        self.brand = product.brand
        self.category = product.category
        self.source = product.source
    }

    var asLookedUpProduct: LookedUpProduct {
        LookedUpProduct(
            name: name, brand: brand, category: category,
            rawNutritionText: nil, imageURL: nil, source: source
        )
    }
}
