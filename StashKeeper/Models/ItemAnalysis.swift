//
//  ItemAnalysis.swift
//  StashKeeper
//
//  Structured output shapes for the Foundation Models framework's guided
//  generation. Vision gives us raw labels/OCR text per detected region
//  (plus any barcode and price-tag OCR); we hand those to a
//  LanguageModelSession and ask it to fill in these @Generable structs.
//  Guided generation (@Generable / @Guide) constrains the model's output
//  to match the schema, so we get reliable structured data instead of
//  parsing freeform text.
//

import Foundation
import CoreGraphics
import FoundationModels

/// Category list shared by ItemAnalysis's @Guide constraint and by every
/// UI category picker. Declared as a free top-level constant (rather than
/// a static member on ItemAnalysis itself) so the @Guide macro on
/// ItemAnalysis.category doesn't reference a static property of the very
/// struct it's helping define — @Generable macro expansion happens during
/// type-checking of the struct, so a self-referential static can trip up
/// the compiler depending on declaration order and Swift version.
///
/// Explicitly `nonisolated`: @Generable's macro-expanded schema properties
/// are nonisolated by design (guided generation can run from any context,
/// including background actors), but plain top-level `let` constants can
/// get inferred as main-actor-isolated under Xcode's "Default Actor
/// Isolation = MainActor" build setting. Without this annotation, that
/// inferred isolation conflicts with the nonisolated context that
/// references it during macro expansion.
nonisolated let itemCategoryOptions = [
    "Pantry & Food",
    "Fresh Produce",
    "Dairy",
    "Beverages",
    "Medicine & Health",
    "Cosmetics & Toiletries",
    "Electronics",
    "Watches & Jewelry",
    "Documents",
    "Clothing",
    "Tools & Hardware",
    "Kitchenware",
    "Cleaning Supplies",
    "Stationery",
    "Toys & Games",
    "Sports & Outdoors",
    "Automotive",
    "Other"
]

/// Structured nutrition facts, normalized to a common shape regardless of
/// whether the source was on-device visual/OCR analysis or an online
/// product database lookup (which report facts in inconsistent formats).
@Generable
struct NutritionFacts: Equatable {
    @Guide(description: "Serving size this data refers to, e.g. '100g' or '1 cup (240ml)'. Empty string if unknown.")
    var servingSize: String

    @Guide(description: "Calories per serving as a whole number. -1 if unknown.")
    var calories: Int

    @Guide(description: "Grams of protein per serving. -1 if unknown.")
    var proteinGrams: Double

    @Guide(description: "Grams of carbohydrates per serving. -1 if unknown.")
    var carbsGrams: Double

    @Guide(description: "Grams of sugar per serving. -1 if unknown.")
    var sugarGrams: Double

    @Guide(description: "Grams of total fat per serving. -1 if unknown.")
    var fatGrams: Double

    @Guide(description: "Grams of fiber per serving. -1 if unknown.")
    var fiberGrams: Double

    @Guide(description: "Milligrams of sodium per serving. -1 if unknown.")
    var sodiumMilligrams: Double
}

/// Analysis for a single detected item/region within a photo or frame.
@Generable
struct ItemAnalysis: Equatable {

    @Guide(description: "A short, human-friendly name for the item, e.g. 'AA Batteries', 'Passport', 'Rolex Submariner', 'Bananas', 'Amul Gold Milk'. Title case, no punctuation. Base this primarily on the largest/most prominent OCR text on the item (that's almost always the brand/product name on real packaging), combined with the classification labels. If this is a specific branded product and the brand/model is legible from OCR text or a barcode lookup, include it. Ignore small print (ingredients, legal text, codes) when forming the name.")
    var name: String

    @Guide(description: "One broad category the item belongs to.", .anyOf(itemCategoryOptions))
    var category: String

    @Guide(description: "A more specific subcategory or type. For produce, use the specific fruit/vegetable name and, where identifiable, the common Indian regional name or variety alongside the standard name if relevant (e.g. 'Brinjal (Eggplant)', 'Lady Finger (Okra)', 'Alphonso Mango'). For dairy, note the type (e.g. 'Paneer', 'Curd/Dahi', 'Toned Milk', 'Ghee'). For watches, use the movement or style if apparent. For other items, keep it short. Empty string if nothing more specific applies.")
    var subcategory: String

    @Guide(description: "True if this item is perishable, expirable, or has a meaningful shelf life — includes food, fresh produce, dairy, drinks, medicine, cosmetics, batteries, and similar consumables. False for durable goods like tools, electronics hardware, documents, watches, furniture.")
    var isPerishable: Bool

    @Guide(description: "If perishable and an expiry or best-before date is visible in the provided OCR text, return it as an ISO-8601 date string (YYYY-MM-DD). If this is fresh produce with no printed date, estimate a realistic remaining-freshness date based on visible ripeness cues, accounting for typical shelf life of that specific produce type at room temperature vs refrigeration (e.g. leafy greens and coriander/dhania spoil in 2-4 days, root vegetables like potatoes/onions last weeks). For dairy (milk, curd/dahi, paneer) rely on typical short shelf life if no date is visible. If no explicit date is visible and the item type has a typical shelf life, estimate a plausible expiry date from today. Empty string if not perishable or impossible to estimate.")
    var estimatedExpiryDateISO: String

    @Guide(description: "Confidence from 0.0 to 1.0 in the expiry estimate. Use 0.9+ only when an explicit printed date was found in the OCR text. Use 0.5-0.75 for produce/dairy freshness estimates based on clearly visible cues or well-known typical shelf life. Use lower confidence (0.3-0.5) for generic guesses with no direct visual evidence.")
    var expiryConfidence: Double

    @Guide(description: "For fresh produce or dairy only: a short freshness note based on visible color, firmness cues, spotting, browning, curdling, or packaging condition, e.g. 'Slightly overripe, some browning' or 'Firm and fresh, no blemishes' or 'Sealed, unopened'. Empty string for other items.")
    var ripenessNote: String

    @Guide(description: "3 to 6 short lowercase keyword tags useful for search, e.g. ['battery', 'aa', 'duracell', 'electronics'] or ['dairy', 'milk', 'amul', 'toned']. Do not repeat the category name verbatim.", .count(3...6))
    var tags: [String]

    @Guide(description: "A best-guess suggested storage location name based on the item type, e.g. 'Fridge', 'Bathroom Cabinet', 'Garage', 'Jewelry Box', 'Pantry'. This is only a suggestion the user can override.")
    var suggestedLocationHint: String

    @Guide(description: "Confidence from 0.0 to 1.0 in the overall category classification. Use lower confidence (below 0.5) when the item is ambiguous, partially obscured, or the visual/text cues are weak or conflicting, so the app knows to flag it for the user to double check.")
    var categoryConfidence: Double

    @Guide(description: "Price of the item, chosen from the region's 'Price-shaped text' candidates if any are provided — do not invent a price from elsewhere in the OCR text. Return just the numeric amount as a string with up to 2 decimal places, e.g. '120.00'. Empty string if no price-shaped candidate is a plausible price (e.g. they all look like weights, codes, or dates instead).")
    var detectedPriceAmount: String

    @Guide(description: "Currency code matching detectedPriceAmount, e.g. 'INR', 'USD', 'EUR'. Infer from the candidate's currency marker if present (₹/Rs/MRP = INR, $ = USD, € = EUR, £ = GBP), otherwise from surrounding context. Empty string if no price was detected.")
    var detectedPriceCurrency: String

    @Guide(description: "Nutrition facts for this item, ONLY if it is food, a beverage, or a dietary supplement. Derive this from any visible nutrition label OCR text if present, or from provided online product lookup data, or — for common unpackaged foods and produce (e.g. 'Bananas', 'Toned Milk', 'Brown Rice') — from well-established typical nutrition values per standard serving. Leave all numeric fields at -1 and servingSize empty if this item is not food/beverage/supplement, or if there truly isn't enough information to estimate reasonably.")
    var nutrition: NutritionFacts

    @Guide(description: "If lookupExistingInventory revealed the user likely already owns a very similar or identical item (matching name/brand AND category), briefly note that here, e.g. 'You may already have 2 of these in the Pantry — this could be a restock.' Leave this EMPTY in every other case, including when items are merely similar in category or type but not a clear match (e.g. two different fruits, two different brands of the same product type). This is purely an informational note for the user to review — it must NEVER change what you put in `name`, `category`, or `tags`: always identify and name THIS item based on what's actually visible/read in front of you, never by copying an existing inventory item's name just because it seems related.")
    var possibleDuplicateNote: String
}

extension ItemAnalysis {
    /// Parses `estimatedExpiryDateISO` into a Date, if present and valid.
    var estimatedExpiryDate: Date? {
        guard !estimatedExpiryDateISO.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: estimatedExpiryDateISO)
    }

    var detectedPrice: Double? {
        guard !detectedPriceAmount.isEmpty else { return nil }
        return Double(detectedPriceAmount)
    }

    var hasUsableNutrition: Bool {
        nutrition.calories >= 0 || nutrition.proteinGrams >= 0 || nutrition.carbsGrams >= 0
    }

    /// Convenience alias so existing UI call sites (`ItemAnalysis.categoryOptions`)
    /// keep working; the actual list lives in the top-level `itemCategoryOptions`
    /// constant for @Guide macro-expansion safety (see comment above).
    static let categoryOptions = itemCategoryOptions
}

/// A line of OCR text that looks like it could be a price, pre-filtered in
/// Swift using a cheap regex/heuristic before the region ever reaches the
/// language model. Passing these out explicitly (rather than making the
/// model hunt for a price inside a wall of undifferentiated OCR text)
/// measurably improves price-reading accuracy, since it turns "find the
/// price somewhere in this text" into "confirm/pick which of these
/// pre-identified candidates is the actual price."
///
/// Explicitly `nonisolated` (see `itemCategoryOptions` above for why this
/// project needs the annotation on plain structs used across actor
/// boundaries under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`).
nonisolated struct PriceOCRHint: Sendable, Equatable {
    let rawText: String
    /// Currency symbol/code detected in the text, if any (e.g. "₹", "$",
    /// "INR"). Nil if the text is numeric but has no currency marker.
    let detectedCurrencyHint: String?
}

/// One item candidate as detected by Vision, before Foundation Models
/// analysis — carries the region's bounding box so the review UI can draw
/// it, plus the raw signals used to produce the eventual ItemAnalysis.
nonisolated struct RegionAnalysisInput: Identifiable, Sendable {
    let id: UUID
    let normalizedBoundingBox: CGRect
    let classificationLabels: [String]
    /// Structured OCR lines (text + confidence + position) rather than
    /// flat strings, so the prompt built from this can distinguish likely
    /// product names (large, high-confidence, upper portion of the label)
    /// from likely prices (short, numeric, often smaller print) instead of
    /// treating every recognized line as equally significant.
    let recognizedText: [OCRLine]
    /// Price-looking OCR lines, pre-filtered in Swift so the model doesn't
    /// have to find the needle in the OCR haystack itself. Empty if no
    /// numeric/currency-shaped text was found in this region.
    var priceHints: [PriceOCRHint] = []
    /// Barcode payload associated with this region, if one was detected
    /// nearby in the photo.
    var barcodePayload: String?
    /// Product info resolved from an online lookup for `barcodePayload`,
    /// if the barcode was found in a product database. Passed to
    /// Foundation Models as additional grounding context.
    var lookedUpProduct: LookedUpProduct?
}

/// Batch analysis result: Foundation Models is given all detected regions'
/// signals together in one prompt (rather than one call per region) so it
/// can use cross-region context to disambiguate — e.g. telling apart two
/// similar-looking bottles, or noticing "these three are all bananas at
/// different ripeness stages" rather than analyzing them in isolation.
@Generable
struct BatchItemAnalysis: Equatable {
    @Guide(description: "One analysis entry per detected region, in the same order the regions were provided.")
    var items: [ItemAnalysis]
}

/// One candidate item as seen across possibly-multiple source photos, fed
/// into the cross-photo duplicate/angle detection pass. Deliberately a thin
/// summary (not the full ItemAnalysis) since only enough signal to compare
/// items against each other is needed here.
nonisolated struct CrossPhotoCandidateSummary: Sendable {
    /// Index into the flat list handed to the model — used purely to map
    /// the model's grouping answer back to real candidates afterward.
    let index: Int
    let name: String
    let category: String
    let subcategory: String
    let tags: [String]
    let barcodePayload: String?
    let recognizedText: [String]
}

/// The model's answer to "which of these detected items are actually the
/// same physical object, just photographed from a different angle or in a
/// different photo?" Each inner array is one group of indices (into the
/// flat candidate list) believed to be the same item. Any index not
/// mentioned in any group is implicitly its own singleton item.
@Generable
struct DuplicateAngleGrouping: Equatable {
    @Guide(description: "Groups of candidate indices that are the SAME physical item photographed from different angles or in different photos. Only include a group if there are 2 or more indices in it — do not include groups of size 1. Items should only be grouped if you're confident they're the same physical object: matching name/brand, matching barcode, or unmistakably the same specific item (not just the same product type — e.g. two different bananas are NOT the same item even if both are 'Bananas').")
    var groups: [[Int]]
}
