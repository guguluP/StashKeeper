//
//  ProductLookupService.swift
//  StashKeeper
//
//  When a barcode is detected but Apple Intelligence's on-device analysis
//  can't confidently identify the product from visual/OCR cues alone, this
//  service queries free, keyless product databases over the network as a
//  fallback. This is the app's only network dependency, and it's used only
//  for barcode resolution — never for general item photos.
//
//  Primary: Open Food Facts (food/grocery focused, strong Indian product
//  coverage from community contributions, fully free, no API key).
//  Fallback: UPCitemdb's free tier (broader non-food product coverage).
//

import Foundation

nonisolated struct LookedUpProduct: Sendable, Equatable {
    let name: String
    let brand: String?
    let category: String?
    /// Nutrition facts as reported by the database, if available — passed
    /// to Foundation Models afterward to normalize into our NutritionFacts
    /// shape rather than trusted verbatim, since field names/units vary a
    /// lot between contributors.
    let rawNutritionText: String?
    let imageURL: URL?
    let source: String
}

nonisolated enum ProductLookupError: Error {
    case notFound
    case networkUnavailable
}

actor ProductLookupService {

    private let session = URLSession(configuration: .ephemeral)

    /// Open Food Facts requires a contactable User-Agent; anonymous
    /// clients are throttled or blocked.
    private static func identifiedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        request.setValue(
            "StashKeeper/\(version) (https://github.com/piyushpatnaik/StashKeeper; inventory-barcode-lookup)",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    /// Looks up a product by barcode, trying Open Food Facts first (best
    /// for groceries, produce, dairy — including Indian regional products),
    /// then UPCitemdb for general merchandise, then a local Indian FMCG
    /// fallback cache (seed table + anything learned from past user
    /// confirmations on this device) for regional/local brands neither
    /// online database tends to carry. Records a local, on-device-only
    /// telemetry entry for every attempt so lookup gaps can be diagnosed
    /// from real usage instead of guesswork.
    func lookup(barcode: String) async -> LookedUpProduct? {
        if let product = try? await lookupOpenFoodFacts(barcode: barcode) {
            await BarcodeLookupTelemetry.shared.record(barcode: barcode, outcome: .hit(source: product.source))
            return product
        }
        if let product = try? await lookupUPCItemDB(barcode: barcode) {
            await BarcodeLookupTelemetry.shared.record(barcode: barcode, outcome: .hit(source: product.source))
            return product
        }
        if let product = await IndianFMCGBarcodeCache.shared.lookup(barcode: barcode) {
            await BarcodeLookupTelemetry.shared.record(barcode: barcode, outcome: .hit(source: product.source))
            return product
        }
        await BarcodeLookupTelemetry.shared.record(barcode: barcode, outcome: .miss)
        return nil
    }

    // MARK: - Open Food Facts

    private func lookupOpenFoodFacts(barcode: String) async throws -> LookedUpProduct {
        guard let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(barcode).json") else {
            throw ProductLookupError.notFound
        }

        let (data, response) = try await session.data(for: Self.identifiedRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProductLookupError.networkUnavailable
        }

        let decoded = try JSONDecoder().decode(OpenFoodFactsResponse.self, from: data)
        guard decoded.status == 1, let product = decoded.product else {
            throw ProductLookupError.notFound
        }

        let name = product.productNameEn ?? product.productName ?? product.genericName
        guard let name, !name.isEmpty else { throw ProductLookupError.notFound }

        var nutritionParts: [String] = []
        if let n = product.nutriments {
            if let cal = n.energyKcal100g { nutritionParts.append("Energy: \(cal) kcal/100g") }
            if let protein = n.proteins100g { nutritionParts.append("Protein: \(protein)g/100g") }
            if let carbs = n.carbohydrates100g { nutritionParts.append("Carbohydrates: \(carbs)g/100g") }
            if let sugar = n.sugars100g { nutritionParts.append("Sugars: \(sugar)g/100g") }
            if let fat = n.fat100g { nutritionParts.append("Fat: \(fat)g/100g") }
            if let satFat = n.saturatedFat100g { nutritionParts.append("Saturated Fat: \(satFat)g/100g") }
            if let fiber = n.fiber100g { nutritionParts.append("Fiber: \(fiber)g/100g") }
            // Open Food Facts `sodium_100g` is grams; StashKeeper / AFM prompts
            // expect milligrams for NutritionFacts.sodiumMilligrams.
            if let sodium = n.sodium100g {
                let milligrams = sodium * 1000
                nutritionParts.append("Sodium: \(milligrams) mg/100g")
            }
        }

        return LookedUpProduct(
            name: name,
            brand: product.brands,
            category: product.categoriesEn?.split(separator: ",").first.map(String.init),
            rawNutritionText: nutritionParts.isEmpty ? nil : nutritionParts.joined(separator: ", "),
            imageURL: product.imageUrl.flatMap(URL.init),
            source: "Open Food Facts"
        )
    }

    // MARK: - UPCitemdb (fallback for non-food products)

    private func lookupUPCItemDB(barcode: String) async throws -> LookedUpProduct {
        guard let url = URL(string: "https://api.upcitemdb.com/prod/trial/lookup?upc=\(barcode)") else {
            throw ProductLookupError.notFound
        }

        let (data, response) = try await session.data(for: Self.identifiedRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProductLookupError.networkUnavailable
        }

        let decoded = try JSONDecoder().decode(UPCItemDBResponse.self, from: data)
        guard let item = decoded.items?.first else {
            throw ProductLookupError.notFound
        }

        return LookedUpProduct(
            name: item.title ?? "Unknown Product",
            brand: item.brand,
            category: item.category,
            rawNutritionText: nil,
            imageURL: item.images?.first.flatMap(URL.init),
            source: "UPCitemdb"
        )
    }
}

// MARK: - Open Food Facts response shape

/// Explicitly `nonisolated` because this project sets
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise make
/// this type (and its synthesized `Decodable` conformance) implicitly
/// main-actor-isolated — unusable from the nonisolated `ProductLookupService`
/// actor's background decoding.
nonisolated private struct OpenFoodFactsResponse: Decodable, Sendable {
    let status: Int
    let product: OFFProduct?
}

nonisolated private struct OFFProduct: Decodable, Sendable {
    let productName: String?
    let productNameEn: String?
    let genericName: String?
    let brands: String?
    let categoriesEn: String?
    let imageUrl: String?
    let nutriments: OFFNutriments?

    enum CodingKeys: String, CodingKey {
        case productName = "product_name"
        case productNameEn = "product_name_en"
        case genericName = "generic_name"
        case brands
        case categoriesEn = "categories_en"
        case imageUrl = "image_url"
        case nutriments
    }
}

nonisolated private struct OFFNutriments: Decodable, Sendable {
    let energyKcal100g: Double?
    let proteins100g: Double?
    let carbohydrates100g: Double?
    let sugars100g: Double?
    let fat100g: Double?
    let saturatedFat100g: Double?
    let fiber100g: Double?
    let sodium100g: Double?

    enum CodingKeys: String, CodingKey {
        case energyKcal100g = "energy-kcal_100g"
        case proteins100g = "proteins_100g"
        case carbohydrates100g = "carbohydrates_100g"
        case sugars100g = "sugars_100g"
        case fat100g = "fat_100g"
        case saturatedFat100g = "saturated-fat_100g"
        case fiber100g = "fiber_100g"
        case sodium100g = "sodium_100g"
    }
}

// MARK: - UPCitemdb response shape

nonisolated private struct UPCItemDBResponse: Decodable, Sendable {
    let items: [UPCItem]?
}

nonisolated private struct UPCItem: Decodable, Sendable {
    let title: String?
    let brand: String?
    let category: String?
    let images: [String]?
}
