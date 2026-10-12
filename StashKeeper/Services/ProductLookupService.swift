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
//  Food, beauty, household, and pet catalogs are all queried. Indian
//  barcodes (890…) are often missing from any one of them, so a miss in
//  Open Food Facts is not the end of the lookup. The scanned value is
//  reduced to a GTIN first, including GS1 Digital Link QR codes.
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
            "StashKeeper/\(version) (https://github.com/guguluP/StashKeeper; inventory-barcode-lookup)",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    private static let openFactsCatalogs: [(source: String, host: String)] = [
        ("Open Food Facts", "world.openfoodfacts.org"),
        ("Open Beauty Facts", "world.openbeautyfacts.org"),
        ("Open Products Facts", "world.openproductsfacts.org"),
        ("Open Pet Food Facts", "world.openpetfoodfacts.org"),
    ]

    /// Looks the barcode up as a GTIN. A 404 from one catalog is "not in
    /// that catalog", so the next catalog still runs. A transport or server
    /// error is recorded separately and does not hide a later hit.
    func lookup(barcode: String) async -> LookedUpProduct? {
        let codes = BarcodeCodes.candidates(from: barcode)
        guard !codes.isEmpty else { return nil }

        var sawNetworkFailure = false
        for code in codes {
            switch await firstOpenFactsHit(code: code) {
            case .found(let product):
                await BarcodeLookupTelemetry.shared.record(barcode: code, outcome: .hit(source: product.source))
                return product
            case .missing:
                break
            case .failed:
                sawNetworkFailure = true
            }

            if let product = await IndianFMCGBarcodeCache.shared.lookup(barcode: code) {
                await BarcodeLookupTelemetry.shared.record(barcode: code, outcome: .hit(source: product.source))
                return product
            }
        }

        switch await attempt({ try await self.lookupUPCItemDB(barcode: codes[0]) }) {
        case .found(let product):
            await BarcodeLookupTelemetry.shared.record(barcode: codes[0], outcome: .hit(source: product.source))
            return product
        case .failed:
            sawNetworkFailure = true
        case .missing:
            break
        }

        await BarcodeLookupTelemetry.shared.record(
            barcode: codes[0],
            outcome: sawNetworkFailure ? .networkFailure : .miss
        )
        return nil
    }

    private func firstOpenFactsHit(code: String) async -> LookupAttempt {
        var sawFailure = false
        for catalog in Self.openFactsCatalogs {
            switch await fetchOpenFacts(code: code, host: catalog.host, source: catalog.source) {
            case .found(let product):
                return .found(product)
            case .failed:
                sawFailure = true
            case .missing:
                break
            }
        }
        return sawFailure ? .failed : .missing
    }

    private enum LookupAttempt: Equatable {
        case found(LookedUpProduct)
        case missing
        case failed
    }

    private func attempt(_ body: () async throws -> LookedUpProduct) async -> LookupAttempt {
        do {
            return .found(try await body())
        } catch ProductLookupError.notFound {
            return .missing
        } catch {
            return .failed
        }
    }

    // MARK: - Open * Facts family

    /// 404 means this catalog has no row. Only a transport or 5xx error is a failure.
    private func fetchOpenFacts(code: String, host: String, source: String) async -> LookupAttempt {
        guard let url = URL(string: "https://\(host)/api/v2/product/\(code).json") else {
            return .missing
        }
        do {
            let (data, response) = try await session.data(for: Self.identifiedRequest(url: url))
            guard let http = response as? HTTPURLResponse else {
                return .failed
            }
            if http.statusCode == 404 { return .missing }
            guard http.statusCode == 200 else { return .failed }
            let decoded = try JSONDecoder().decode(OpenFoodFactsResponse.self, from: data)
            guard decoded.status == 1, let product = decoded.product else {
                return .missing
            }
            guard let name = OpenFactsNaming.compose(
                productName: product.productName,
                productNameEn: product.productNameEn,
                productNameHi: product.productNameHi,
                genericName: product.genericName,
                abbreviatedName: product.abbreviatedProductName,
                brands: product.brands,
                quantity: product.quantity
            ) else {
                return .missing
            }
            let category = (product.categoriesEn ?? product.categories)?
                .split(separator: ",")
                .first
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            return .found(LookedUpProduct(
                name: name,
                brand: product.brands,
                category: category,
                rawNutritionText: product.nutriments?.summary,
                imageURL: product.imageUrl.flatMap(URL.init),
                source: source
            ))
        } catch {
            return .failed
        }
    }

    // MARK: - UPCitemdb (fallback for non-food products)

    private func lookupUPCItemDB(barcode: String) async throws -> LookedUpProduct {
        guard let url = URL(string: "https://api.upcitemdb.com/prod/trial/lookup?upc=\(barcode)") else {
            throw ProductLookupError.notFound
        }

        let (data, response) = try await session.data(for: Self.identifiedRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProductLookupError.networkUnavailable
        }
        if httpResponse.statusCode == 404 {
            throw ProductLookupError.notFound
        }
        guard httpResponse.statusCode == 200 else {
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
    let productNameHi: String?
    let genericName: String?
    let abbreviatedProductName: String?
    let brands: String?
    let categories: String?
    let categoriesEn: String?
    let quantity: String?
    let imageUrl: String?
    let nutriments: OFFNutriments?

    enum CodingKeys: String, CodingKey {
        case productName = "product_name"
        case productNameEn = "product_name_en"
        case productNameHi = "product_name_hi"
        case genericName = "generic_name"
        case abbreviatedProductName = "abbreviated_product_name"
        case brands
        case categories
        case categoriesEn = "categories_en"
        case quantity
        case imageUrl = "image_url"
        case nutriments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        productName = try container.decodeIfPresent(String.self, forKey: .productName)
        productNameEn = try container.decodeIfPresent(String.self, forKey: .productNameEn)
        productNameHi = try container.decodeIfPresent(String.self, forKey: .productNameHi)
        genericName = try container.decodeIfPresent(String.self, forKey: .genericName)
        abbreviatedProductName = try container.decodeIfPresent(String.self, forKey: .abbreviatedProductName)
        brands = try container.decodeIfPresent(String.self, forKey: .brands)
        categories = try container.decodeIfPresent(String.self, forKey: .categories)
        categoriesEn = try container.decodeIfPresent(String.self, forKey: .categoriesEn)
        quantity = Self.flexibleString(container, .quantity)
        imageUrl = try container.decodeIfPresent(String.self, forKey: .imageUrl)
        // A messy nutrition blob must not throw away a product we already named.
        nutriments = try? container.decodeIfPresent(OFFNutriments.self, forKey: .nutriments)
    }

    private static func flexibleString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        return nil
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

    var summary: String? {
        var parts: [String] = []
        if let energyKcal100g { parts.append("Energy: \(energyKcal100g) kcal/100g") }
        if let proteins100g { parts.append("Protein: \(proteins100g)g/100g") }
        if let carbohydrates100g { parts.append("Carbohydrates: \(carbohydrates100g)g/100g") }
        if let sugars100g { parts.append("Sugars: \(sugars100g)g/100g") }
        if let fat100g { parts.append("Fat: \(fat100g)g/100g") }
        if let saturatedFat100g { parts.append("Saturated Fat: \(saturatedFat100g)g/100g") }
        if let fiber100g { parts.append("Fiber: \(fiber100g)g/100g") }
        // Open Food Facts `sodium_100g` is grams.
        if let sodium100g { parts.append("Sodium: \(sodium100g * 1000) mg/100g") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        energyKcal100g = Self.flexibleDouble(container, .energyKcal100g)
        proteins100g = Self.flexibleDouble(container, .proteins100g)
        carbohydrates100g = Self.flexibleDouble(container, .carbohydrates100g)
        sugars100g = Self.flexibleDouble(container, .sugars100g)
        fat100g = Self.flexibleDouble(container, .fat100g)
        saturatedFat100g = Self.flexibleDouble(container, .saturatedFat100g)
        fiber100g = Self.flexibleDouble(container, .fiber100g)
        sodium100g = Self.flexibleDouble(container, .sodium100g)
    }

    private static func flexibleDouble(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(text)
        }
        return nil
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
