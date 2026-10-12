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

nonisolated struct ConfirmedPackage: Sendable {
    var barcode: String?
    var name: String
    var category: String
    var nutrition: NutritionFacts?
    var ingredients: String?
    var wrapperTokens: [String]
}

actor IndianFMCGBarcodeCache {

    static let shared = IndianFMCGBarcodeCache()

    private let defaults: UserDefaults
    private let learnedKey = "StashKeeper.learnedIndianBarcodes"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// A cache that does not share the household's UserDefaults. Tests use
    /// this so a confirmation never lands in the real stash.
    nonisolated static func makeForTests(suite: String) -> IndianFMCGBarcodeCache {
        IndianFMCGBarcodeCache(defaults: UserDefaults(suiteName: suite) ?? .standard)
    }

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

    /// A name, panel, and wrapper this household confirmed. Wins over the
    /// seed table and over a catalog the next time that barcode is scanned.
    func learned(barcode: String) -> LookedUpProduct? {
        learnedEntries()[barcode]
    }

    /// The small bundled list. Used only when no catalog and no
    /// confirmation knows the barcode.
    nonisolated static func seeded(barcode: String) -> LookedUpProduct? {
        seedTable[barcode]
    }

    /// Checks a confirmed barcode first, then the seed table.
    func lookup(barcode: String) -> LookedUpProduct? {
        if let confirmed = learned(barcode: barcode) {
            return confirmed
        }
        return Self.seeded(barcode: barcode)
    }

    /// Recognizes a pack from the large words on the wrapper when the
    /// barcode was missed. Requires most of the stored words to be present.
    func match(lines: [OCRLine]) -> LookedUpProduct? {
        let observed = Set(PackageLabelReader.signature(from: lines))
        guard observed.count >= 2 else { return nil }
        var best: (product: LookedUpProduct, shared: Int)?
        for product in learnedEntries().values {
            let stored = Set(product.wrapperTokens)
            guard stored.count >= 2 else { continue }
            let shared = stored.intersection(observed).count
            guard shared >= 2, shared * 4 >= stored.count * 3 else { continue }
            if best == nil || shared > (best?.shared ?? 0) {
                best = (product, shared)
            }
        }
        return best?.product
    }

    func learn(_ package: ConfirmedPackage) {
        let trimmed = package.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var entries = learnedEntries()
        let product = LookedUpProduct(
            name: trimmed,
            brand: nil,
            category: package.category,
            rawNutritionText: nil,
            imageURL: nil,
            source: "Learned on this device",
            nutrition: package.nutrition,
            ingredients: package.ingredients,
            wrapperTokens: package.wrapperTokens
        )
        if let barcode = package.barcode?.filter(\.isNumber), !barcode.isEmpty {
            entries[barcode] = product
        }
        if package.wrapperTokens.count >= 2 {
            let key = "wrap:" + package.wrapperTokens.sorted().joined(separator: "|")
            entries[key] = product
        }
        saveLearnedEntries(entries)
    }

    /// Called when the user confirms a name for a barcode. Keeps the
    /// earlier three-argument call sites working.
    func learn(barcode: String, name: String, category: String) {
        learn(ConfirmedPackage(
            barcode: barcode,
            name: name,
            category: category,
            nutrition: nil,
            ingredients: nil,
            wrapperTokens: []
        ))
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
    let ingredients: String?
    let wrapperTokens: [String]
    let servingSize: String?
    let calories: Int?
    let proteinGrams: Double?
    let carbsGrams: Double?
    let sugarGrams: Double?
    let fatGrams: Double?
    let fiberGrams: Double?
    let sodiumMilligrams: Double?

    init(from product: LookedUpProduct) {
        self.name = product.name
        self.brand = product.brand
        self.category = product.category
        self.source = product.source
        self.ingredients = product.ingredients
        self.wrapperTokens = product.wrapperTokens
        self.servingSize = product.nutrition?.servingSize
        self.calories = product.nutrition?.calories
        self.proteinGrams = product.nutrition?.proteinGrams
        self.carbsGrams = product.nutrition?.carbsGrams
        self.sugarGrams = product.nutrition?.sugarGrams
        self.fatGrams = product.nutrition?.fatGrams
        self.fiberGrams = product.nutrition?.fiberGrams
        self.sodiumMilligrams = product.nutrition?.sodiumMilligrams
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        brand = try container.decodeIfPresent(String.self, forKey: .brand)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "Learned on this device"
        ingredients = try container.decodeIfPresent(String.self, forKey: .ingredients)
        wrapperTokens = try container.decodeIfPresent([String].self, forKey: .wrapperTokens) ?? []
        servingSize = try container.decodeIfPresent(String.self, forKey: .servingSize)
        calories = try container.decodeIfPresent(Int.self, forKey: .calories)
        proteinGrams = try container.decodeIfPresent(Double.self, forKey: .proteinGrams)
        carbsGrams = try container.decodeIfPresent(Double.self, forKey: .carbsGrams)
        sugarGrams = try container.decodeIfPresent(Double.self, forKey: .sugarGrams)
        fatGrams = try container.decodeIfPresent(Double.self, forKey: .fatGrams)
        fiberGrams = try container.decodeIfPresent(Double.self, forKey: .fiberGrams)
        sodiumMilligrams = try container.decodeIfPresent(Double.self, forKey: .sodiumMilligrams)
    }

    var asLookedUpProduct: LookedUpProduct {
        let nutrition: NutritionFacts?
        if calories != nil || proteinGrams != nil || carbsGrams != nil {
            nutrition = NutritionFacts(
                servingSize: servingSize ?? "",
                calories: calories ?? -1,
                proteinGrams: proteinGrams ?? -1,
                carbsGrams: carbsGrams ?? -1,
                sugarGrams: sugarGrams ?? -1,
                fatGrams: fatGrams ?? -1,
                fiberGrams: fiberGrams ?? -1,
                sodiumMilligrams: sodiumMilligrams ?? -1
            )
        } else {
            nutrition = nil
        }
        return LookedUpProduct(
            name: name,
            brand: brand,
            category: category,
            rawNutritionText: nil,
            imageURL: nil,
            source: source,
            nutrition: nutrition,
            ingredients: ingredients,
            wrapperTokens: wrapperTokens
        )
    }
}
