//
//  ItemIntelligenceService.swift
//  StashKeeper
//
//  Wraps the Foundation Models framework (Apple's on-device Apple
//  Intelligence LLM — the only model tier third-party apps can access;
//  Apple's larger server-side model is reserved for first-party features
//  and has no public API). This service is the "best use of AFM" layer:
//
//  - A warm, persistent LanguageModelSession per task type instead of a
//    fresh session per call, so repeated instructions aren't re-parsed
//    every time and latency improves across a session of adding several
//    items in a row.
//  - Tuned GenerationOptions per task: low temperature for structured
//    extraction (we want consistent, literal answers), a touch more for
//    open-ended search interpretation.
//  - Tool calling: sessions are given an InventoryLookupTool so the model
//    can check the user's existing items mid-reasoning (duplicate
//    detection during analysis; grounding candidate matches during
//    search) rather than reasoning over a static snapshot alone.
//  - A narrower-prompt retry path if the first structured-generation
//    attempt fails, before falling back to manual entry.
//

import Foundation
import FoundationModels

enum ItemIntelligenceError: Error, LocalizedError {
    case modelUnavailable(SystemLanguageModel.Availability.UnavailableReason)
    case generationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This device doesn't support Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                return "Turn on Apple Intelligence in Settings to auto-recognize items."
            case .modelNotReady:
                return "The on-device model is still downloading. Try again shortly."
            @unknown default:
                return "Apple Intelligence is currently unavailable."
            }
        case .generationFailed:
            return "Couldn't analyze this item. You can fill in the details manually."
        }
    }
}

/// Which tier actually produced an analysis result — surfaced so the UI can
/// show an honest "estimated, not AI-identified" hint when the heuristic
/// tier was used, the same way Apple's own apps disclose degraded quality.
enum ModelTier: Sendable, Equatable {
    case onDevice
    case privateCloudCompute
    /// No language model involved at all — see `HeuristicItemNamer`. Used
    /// automatically on devices that can't run Apple Intelligence (older
    /// hardware, or PCC unavailable/ineligible too) so the app still adds
    /// items with a reasonable name/category instead of just failing.
    case heuristicOnly
}

/// A zero-AI fallback for devices that can't run Apple Intelligence at all
/// (older iPhones below the on-device model's hardware floor) and also
/// don't have Private Cloud Compute available (offline, app not
/// PCC-eligible, or the daily limit is hit). Rather than leaving these
/// users with a bare "add manually, we can't help" experience, this
/// produces a genuinely useful — if less precise — first guess purely from
/// Vision's classification labels, OCR text, and barcode lookups, all of
/// which already run independently of any language model.
///
/// This deliberately does NOT try to imitate what AFM does (no attempt at
/// fluent naming, ripeness notes, or nuanced categorization) — it applies
/// simple, explainable rules so its behavior is predictable and the
/// resulting `ItemAnalysis.categoryConfidence` honestly reflects how much
/// guessing happened, which callers can use to nudge the user to review
/// more carefully than they would for an AFM-produced result.
enum HeuristicItemNamer {
    /// Produces a best-effort ItemAnalysis with no language model
    /// involved, from whatever Vision/barcode/OCR signal is available.
    /// Always succeeds (never throws) since every field has a sane
    /// fallback — the whole point of this tier is to never leave the user
    /// with nothing.
    static func analyze(_ region: RegionAnalysisInput) -> ItemAnalysis {
        let (name, confidence) = deriveName(from: region)
        let category = deriveCategory(from: region.classificationLabels)
        let (priceAmount, priceCurrency) = derivePrice(from: region.priceHints)

        return ItemAnalysis(
            name: name,
            category: category,
            subcategory: "",
            isPerishable: Self.perishableCategories.contains(category),
            estimatedExpiryDateISO: "",
            expiryConfidence: 0,
            ripenessNote: "",
            tags: [],
            suggestedLocationHint: "",
            categoryConfidence: confidence,
            detectedPriceAmount: priceAmount,
            detectedPriceCurrency: priceCurrency,
            nutrition: NutritionFacts(servingSize: "", calories: -1, proteinGrams: -1, carbsGrams: -1, sugarGrams: -1, fatGrams: -1, fiberGrams: -1, sodiumMilligrams: -1),
            possibleDuplicateNote: ""
        )
    }

    /// Name priority mirrors the reasoning AFM's instructions already
    /// encode (see ItemIntelligenceService's analysis instructions): a
    /// resolved barcode product name is most trustworthy, then the
    /// largest/most-confident OCR line (packaging convention puts the
    /// product name in the biggest type), then the least-generic
    /// classification label, in that order.
    private static func deriveName(from region: RegionAnalysisInput) -> (name: String, confidence: Double) {
        if let product = region.lookedUpProduct {
            return (product.name, 0.85)
        }

        let sortedText = region.recognizedText
            .filter { $0.confidence > 0.5 }
            .sorted { $0.relativeHeight > $1.relativeHeight }
        if let bestLine = sortedText.first, bestLine.text.count >= 3 {
            return (bestLine.text.trimmingCharacters(in: .whitespacesAndNewlines), 0.5)
        }

        if let bestLabel = region.classificationLabels.first(where: { !VisionAnalyzer.genericLowInformationLabels.contains($0.lowercased()) }) {
            return (bestLabel.localizedCapitalized, 0.3)
        }

        return ("Unidentified Item", 0.1)
    }

    /// Keyword map into `itemCategoryOptions` only — never invent alternate
    /// category names (e.g. "Groceries") that don't appear in pickers,
    /// milestones, or search filters. Conservative: falls through to "Other".
    private static let categoryKeywords: [(keywords: [String], category: String)] = [
        (["banana", "apple", "fruit", "vegetable", "produce", "tomato", "onion", "potato", "carrot", "mango", "berry"], "Fresh Produce"),
        (["milk", "cheese", "yogurt", "yoghurt", "dairy", "paneer", "curd", "dahi", "ghee", "butter", "egg"], "Dairy"),
        (["bottle", "can", "beverage", "drink", "soda", "juice", "water", "coffee", "tea"], "Beverages"),
        (["bread", "rice", "pasta", "cereal", "snack", "cookie", "biscuit", "flour", "spice", "oil", "sauce", "food", "grocery", "pantry"], "Pantry & Food"),
        (["medicine", "pill", "tablet", "capsule", "pharmaceutical", "vitamin", "syrup", "bandage"], "Medicine & Health"),
        (["cosmetic", "shampoo", "soap", "lotion", "toothpaste", "toiletry", "perfume"], "Cosmetics & Toiletries"),
        (["electronics", "cable", "charger", "phone", "battery", "device", "laptop", "headphones"], "Electronics"),
        (["watch", "jewelry", "jewellery", "ring", "necklace"], "Watches & Jewelry"),
        (["clothing", "shirt", "shoe", "jacket", "fabric", "apparel", "pants", "dress"], "Clothing"),
        (["book", "notebook", "paper", "document", "passport", "id card"], "Documents"),
        (["pen", "pencil", "stationery", "eraser", "stapler"], "Stationery"),
        (["tool", "hardware", "screwdriver", "wrench", "hammer", "drill"], "Tools & Hardware"),
        (["pan", "pot", "plate", "utensil", "kitchen", "fork", "knife", "spoon"], "Kitchenware"),
        (["cleaner", "detergent", "bleach", "sponge", "mop"], "Cleaning Supplies"),
        (["toy", "game", "lego", "puzzle"], "Toys & Games"),
        (["sport", "ball", "bike", "outdoor", "camping", "fitness"], "Sports & Outdoors"),
        (["car", "automotive", "tire", "motor", "vehicle"], "Automotive")
    ]

    /// Must stay a subset of `itemCategoryOptions` so offline heuristic
    /// results remain filterable and milestone-compatible.
    private static let perishableCategories: Set<String> = [
        "Pantry & Food",
        "Fresh Produce",
        "Dairy",
        "Beverages",
        "Medicine & Health",
        "Cosmetics & Toiletries"
    ]

    private static func deriveCategory(from labels: [String]) -> String {
        let lowercasedLabels = labels.map { $0.lowercased() }
        for entry in categoryKeywords {
            if lowercasedLabels.contains(where: { label in entry.keywords.contains { label.contains($0) } }) {
                return entry.category
            }
        }
        return "Other"
    }

    private static func derivePrice(from hints: [PriceOCRHint]) -> (amount: String, currency: String) {
        // Prefer a currency-marked hint over a bare number, same priority
        // AFM's own instructions use — but without any judgment calls
        // about whether a bare number is "plausible," since that requires
        // the kind of contextual reasoning this tier deliberately skips.
        guard let marked = hints.first(where: { $0.detectedCurrencyHint != nil }) else {
            return ("", "")
        }
        let digits = marked.rawText.filter { $0.isNumber || $0 == "." }
        let currency: String
        switch marked.detectedCurrencyHint?.lowercased() {
        case "$", "usd": currency = "USD"
        case "€", "eur": currency = "EUR"
        case "£", "gbp": currency = "GBP"
        default: currency = "INR"
        }
        return (digits, digits.isEmpty ? "" : currency)
    }
}

/// Routes each request to the on-device model first (free, private,
/// offline, no per-request limit) and only escalates to
/// `PrivateCloudComputeLanguageModel` — Apple's free-for-small-developers
/// server model introduced alongside the unified `LanguageModel` protocol —
/// when the on-device model is unavailable (Apple Intelligence off, model
/// still downloading, device ineligible) or when a task is explicitly
/// marked as needing PCC's larger context/reasoning (batch analysis of
/// many regions at once, which can exceed the on-device model's smaller
/// context window).
///
/// This indirection exists so the rest of the service can build a session
/// with `PreferredModelRouter.resolve(preferCloud:)` without scattering
/// availability checks and PCC-specific fallback logic across every call
/// site. PCC eligibility (App Store Small Business Program, under the
/// download threshold, entitlement present) and runtime conditions
/// (network reachable, under the user's daily limit) are all reflected in
/// `PrivateCloudComputeLanguageModel.isAvailable`; when it's false for any
/// reason, this quietly falls back to the on-device model rather than
/// erroring — PCC is a bonus tier, never a hard requirement, so a missing
/// entitlement or an offline device should never be a user-facing failure
/// on its own.
@MainActor
enum PreferredModelRouter {
    /// Resolves which model + tier to actually use for a request.
    /// `preferCloud` is a hint (not a guarantee) from the call site that
    /// this particular task benefits from PCC's larger context/reasoning;
    /// it's still gated by on-device-first logic and real availability.
    static func resolve(preferCloud: Bool) -> (model: any LanguageModel, tier: ModelTier) {
        let onDevice = SystemLanguageModel.default

        // On-device is always tried first when it's actually ready — it's
        // free, private, offline, and has no daily request limit, so there's
        // no reason to spend the user's PCC quota on a task the small model
        // already handles well.
        if case .available = onDevice.availability, !preferCloud {
            return (onDevice, .onDevice)
        }

        let cloudModel = PrivateCloudComputeLanguageModel()
        if cloudModel.isAvailable {
            return (cloudModel, .privateCloudCompute)
        }

        // Cloud unavailable (ineligible app, no entitlement, offline, over
        // the daily per-user limit) — fall back to on-device even if it's
        // the less-preferred choice for this task, since a degraded answer
        // beats no answer. Callers still check `onDevice.availability`
        // themselves for the "nothing works at all" case and show the
        // appropriate manual-entry fallback.
        return (onDevice, .onDevice)
    }
}

@MainActor
final class ItemIntelligenceService {

    static let shared = ItemIntelligenceService()

    private let model = SystemLanguageModel.default

    /// Warm sessions kept alive across calls within an app session, keyed by
    /// task type, so instructions aren't rebuilt/reparsed on every single
    /// photo analyzed or search performed. Recreated only if the model's
    /// availability changes (e.g. Apple Intelligence toggled mid-session)
    /// or if a session enters an errored state.
    private var analysisSession: LanguageModelSession?
    private var searchSession: LanguageModelSession?

    /// Item count the currently-cached sessions' inventory tool was built
    /// with. A warm session's Tool captures a snapshot at construction
    /// time, so if the inventory has changed since (new items saved,
    /// items deleted) since we last built a session, the cached session's
    /// tool would silently serve stale data. Tracking the count lets us
    /// detect drift without requiring every call site to remember to call
    /// invalidateSessions() — a cheap, good-enough staleness check since
    /// exact content changes (edits without count changes) are rarer and
    /// lower-stakes for this tool's purpose (duplicate/grounding checks).
    private var analysisSessionItemCount: Int = -1
    private var searchSessionItemCount: Int = -1
    private var analysisSessionFingerprint: Int = 0
    private var searchSessionFingerprint: Int = 0
    /// Tier the currently-cached session was built against — tracked
    /// alongside item count so a session built for one tier isn't silently
    /// reused when a later call prefers (or requires, due to availability
    /// changing mid-session) a different tier.
    private var analysisSessionTier: ModelTier?
    private var searchSessionTier: ModelTier?

    var availability: SystemLanguageModel.Availability { model.availability }

    /// Whether Apple Intelligence is ready to use right now.
    var isAvailable: Bool {
        if case .available = model.availability { return true }
        return false
    }

    /// Whether ANY tier — on-device or Private Cloud Compute — can serve a
    /// request right now. Used to decide whether to attempt AI analysis at
    /// all before falling back to fully manual entry; `isAvailable` alone
    /// would incorrectly report unavailable when only PCC is reachable
    /// (e.g. Apple Intelligence is enabled but the on-device model hasn't
    /// finished downloading yet, while PCC is already usable).
    var isAvailableViaAnyTier: Bool {
        if isAvailable { return true }
        return PrivateCloudComputeLanguageModel().isAvailable
    }

    /// Which tier actually served the most recently completed request, so
    /// the UI can show a small "via Private Cloud Compute" disclosure when
    /// a request left the device — matching the transparency users expect
    /// from Apple's own on-device/PCC-backed features.
    private(set) var lastUsedTier: ModelTier = .onDevice

    // MARK: - Structuring detected regions from a photo/frame

    /// Analyzes every detected region from a single photo/frame together in
    /// one Foundation Models call, so the model can use cross-region context
    /// (e.g. distinguishing near-identical bottles, or noticing several
    /// pieces of produce at different ripeness stages) rather than judging
    /// each region in total isolation. Given tool access to the existing
    /// inventory so it can flag likely duplicates/restocks.
    /// - Parameter expectedItemHint: When the user arrived at this capture
    ///   via the receipt scan flow, a short description of what the
    ///   receipt line said this item should be (name + price). Passed as
    ///   a soft nudge, not a hard override — the photo is still the
    ///   source of truth, so AFM is told to prefer what it actually sees,
    ///   and only lean on this hint to disambiguate or fill gaps (e.g.
    ///   confirming a price that's hard to read on packaging, or
    ///   resolving a generic-looking item using the receipt's more
    ///   specific name). Nil for the normal (non-receipt) capture flow.
    func analyzeRegions(
        _ regions: [RegionAnalysisInput],
        globalRecognizedText: [OCRLine],
        existingLocationNames: [String],
        existingItems: [StashItem],
        expectedItemHint: String? = nil
    ) async throws -> [ItemAnalysis] {
        guard !regions.isEmpty else { return [] }

        // Devices that can't run Apple Intelligence at all (below the
        // on-device model's hardware floor) and also have no Private Cloud
        // Compute available (offline, app not PCC-eligible, daily limit
        // hit) fall through to the zero-AI heuristic tier rather than
        // failing outright — see HeuristicItemNamer for why this is a
        // deliberately conservative, explainable fallback rather than an
        // attempt to imitate AFM's output quality.
        guard isAvailableViaAnyTier else {
            lastUsedTier = .heuristicOnly
            return regions.map(HeuristicItemNamer.analyze)
        }

        // Large batches (many items detected in one photo, e.g. a full
        // shelf) benefit from PCC's bigger context window and reasoning —
        // the on-device model can start dropping cross-region grounding
        // quality once the prompt gets long. Everything else stays
        // on-device first since it's free, private, and has no daily cap.
        let preferCloud = regions.count > 6
        let session = analysisSessionInstance(existingItems: existingItems, preferCloud: preferCloud)

        let locationHint = existingLocationNames.isEmpty
            ? "none yet"
            : existingLocationNames.joined(separator: ", ")

        let regionsDescription = Self.describeRegions(regions)

        let hintLine = expectedItemHint.map {
            "\nThe user is confirming an item from a shopping receipt that read: \($0). Prefer what you actually see/read in the photo below over this hint — only use it to fill in gaps or resolve ambiguity, e.g. if the photo alone doesn't make the product name or price fully clear.\n"
        } ?? ""

        let prompt = Prompt {
            """
            A single photo contains \(regions.count) distinct item region(s)
            detected by on-device object detection. Analyze each region as a
            separate item, in order. You may call lookupExistingInventory if
            you want to check whether the user likely already has a similar
            item, to help decide on quantity or flag a probable restock.
            \(hintLine)
            \(regionsDescription)

            Additional text found elsewhere in the full image (may be
            packaging visible near an item, or empty), roughly ordered by
            how prominent/large the text is:
            \(Self.describeOCRLines(globalRecognizedText))

            Existing storage locations the user already has: \(locationHint)

            Return one analysis entry per region, in the same order.
            """
        }

        // Structured extraction wants low temperature: consistent, literal,
        // minimally "creative" answers since we need reliably parseable facts.
        let options = GenerationOptions(temperature: 0.2)

        do {
            let response = try await session.respond(
                to: prompt,
                generating: BatchItemAnalysis.self,
                options: options
            )
            return Self.finalizeAnalyses(
                response.content.items,
                expectedCount: regions.count,
                existingLocationNames: existingLocationNames
            )
        } catch {
            // Retry once, escalating to Private Cloud Compute if the first
            // attempt ran on-device and PCC is available — a larger,
            // reasoning-capable model recovers from guided-generation
            // hiccups on complex multi-region batches more often than
            // simply retrying the same small model again would. If we were
            // already on PCC (or it's unavailable), retry on-device with a
            // narrower, simpler prompt instead.
            analysisSession = nil // discard possibly-wedged session
            let retrySession = analysisSessionInstance(existingItems: existingItems, preferCloud: !preferCloud)
            let retryPrompt = Prompt {
                """
                Analyze these \(regions.count) item region(s) from a photo.
                \(regionsDescription)
                Return one analysis entry per region, in order.
                Prefer exact category names from the allowed list. Leave price
                empty when unsure. Do not invent brand names without OCR/barcode evidence.
                """
            }
            do {
                let response = try await retrySession.respond(
                    to: retryPrompt,
                    generating: BatchItemAnalysis.self,
                    options: GenerationOptions(temperature: 0.1)
                )
                return Self.finalizeAnalyses(
                    response.content.items,
                    expectedCount: regions.count,
                    existingLocationNames: existingLocationNames
                )
            } catch {
                // Last resort: heuristic per region so the Add flow still works.
                lastUsedTier = .heuristicOnly
                return Self.finalizeAnalyses(
                    regions.map(HeuristicItemNamer.analyze),
                    expectedCount: regions.count,
                    existingLocationNames: existingLocationNames
                )
            }
        }
    }

    // MARK: - Cross-photo duplicate/angle detection

    /// After every source photo has been analyzed independently, this takes
    /// the flattened list of all detected candidates across ALL photos and
    /// asks the model which ones are actually the same physical item shot
    /// from a different angle or in a separate photo (e.g. front and back
    /// of the same bottle, or the same shoe photographed twice) rather than
    /// genuinely distinct items. This runs as a separate, lightweight pass
    /// — using summaries, not full images — since Foundation Models'
    /// on-device text model has no vision input; the grouping is inferred
    /// from name/category/tags/OCR/barcode overlap, which is what a human
    /// skimming the review screen would also use to notice a duplicate.
    ///
    /// Uses its own short-lived session rather than the warm analysis
    /// session, since this is a one-off call per Add Item flow rather than
    /// something reused across many calls in a session's lifetime.
    func detectDuplicateAngles(_ candidates: [CrossPhotoCandidateSummary]) async -> [[Int]] {
        guard candidates.count > 1, isAvailableViaAnyTier else { return [] }

        let (resolvedModel, _) = PreferredModelRouter.resolve(preferCloud: false)

        let instructions = Instructions {
            """
            You are given a flat list of items detected across one or more
            photos the user just took while cataloging their belongings.
            Some of these "different" detections may actually be the SAME
            physical object, photographed more than once — e.g. the front
            and back of the same bottle, a shoe shot from two angles, or the
            same box photographed before and after rotating it. Your job is
            to find which indices refer to the same physical object, being
            conservative: only group items you're genuinely confident are
            the same specific object, not just the same product type.
            A matching barcode is the strongest possible signal. Matching
            distinctive OCR text (e.g. the same serial number, model name,
            or lot code) is also strong. Matching name/brand/category alone
            is weaker evidence — two identical bananas from the same bunch,
            or two different AA batteries, are NOT the same item even
            though their descriptions match, unless other evidence (like
            matching OCR text) suggests they are literally the same one.
            When genuinely unsure, do not group — it's much better to leave
            two photos of the same item as separate entries than to
            wrongly merge two distinct items into one.
            """
        }

        let itemsDescription = candidates.map { candidate -> String in
            var lines = [
                "Index \(candidate.index):",
                "- Name: \(candidate.name)",
                "- Category: \(candidate.category)" + (candidate.subcategory.isEmpty ? "" : " / \(candidate.subcategory)"),
                "- Tags: \(candidate.tags.joined(separator: ", "))"
            ]
            if let barcode = candidate.barcodePayload {
                lines.append("- Barcode: \(barcode)")
            }
            if !candidate.recognizedText.isEmpty {
                lines.append("- OCR text: \(candidate.recognizedText.joined(separator: " | "))")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")

        let prompt = Prompt {
            """
            Here are \(candidates.count) detected items from this catalog
            session:

            \(itemsDescription)

            Return groups of indices that are the same physical item shot
            from different angles or photos. Omit any index that has no
            match — it doesn't need its own group.
            """
        }

        do {
            let session = LanguageModelSession(model: resolvedModel, instructions: instructions)
            let response = try await session.respond(
                to: prompt,
                generating: DuplicateAngleGrouping.self,
                options: GenerationOptions(temperature: 0.1)
            )
            let validIndices = Set(candidates.map(\.index))
            // Defensive: drop any group referencing an out-of-range index,
            // and any group the model returned with fewer than 2 members.
            return response.content.groups
                .map { $0.filter(validIndices.contains) }
                .filter { $0.count > 1 }
        } catch {
            // Non-critical enhancement — if this fails for any reason, just
            // skip merging rather than blocking the whole Add Item flow.
            return []
        }
    }

    private static func describeRegions(_ regions: [RegionAnalysisInput]) -> String {
        regions.enumerated().map { index, region -> String in
            var lines = [
                "Region \(index + 1):",
                "- Classification labels: \(region.classificationLabels.joined(separator: ", "))",
                "- OCR text on this region, most prominent (largest/highest-confidence) first: \(describeOCRLines(region.recognizedText))"
            ]
            if !region.priceHints.isEmpty {
                // Surfaced as its own explicit line rather than making the
                // model dig the price out of the general OCR text above —
                // this is the single biggest lever for price-reading
                // accuracy: turning "find a price somewhere in this text"
                // into "here are the pre-identified numeric/currency
                // candidates, pick the right one."
                let hintDescriptions = region.priceHints.map { hint in
                    hint.detectedCurrencyHint.map { "\(hint.rawText) (currency marker: \($0))" } ?? hint.rawText
                }
                lines.append("- Price-shaped text found near this item (candidates, not confirmed — verify against context; may include unrelated numbers like weights or codes): \(hintDescriptions.joined(separator: ", "))")
            }
            if let barcode = region.barcodePayload {
                lines.append("- Barcode detected: \(barcode)")
            }
            if let product = region.lookedUpProduct {
                lines.append("- Online product database match (\(product.source)): name '\(product.name)'" +
                    (product.brand.map { ", brand '\($0)'" } ?? "") +
                    (product.category.map { ", category '\($0)'" } ?? "") +
                    (product.rawNutritionText.map { ", nutrition data: \($0)" } ?? "") +
                    ". Treat this as strong grounding evidence for identifying the product, but still use your judgment and the other cues.")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// Formats OCR lines for a prompt, sorted so the largest/most prominent
    /// text (the strongest visual cue for a printed product name) appears
    /// first, and annotates each line with a rough size/confidence tag so
    /// the model can weigh a large, confident line as a probable headline
    /// name and a tiny line as probable fine print rather than treating
    /// every recognized string as equally significant.
    private static func describeOCRLines(_ lines: [OCRLine]) -> String {
        guard !lines.isEmpty else { return "(none found)" }

        let sorted = lines.sorted { $0.relativeHeight > $1.relativeHeight }
        return sorted.map { line -> String in
            let sizeTag: String
            switch line.relativeHeight {
            case 0.08...: sizeTag = "large text"
            case 0.04..<0.08: sizeTag = "medium text"
            default: sizeTag = "small text"
            }
            let confidenceTag = line.confidence < 0.5 ? ", low confidence — may be misread" : ""
            return "\"\(line.text)\" (\(sizeTag)\(confidenceTag))"
        }.joined(separator: " | ")
    }

    /// Pad/truncate to region count, then sanitize each analysis so AFM
    /// quirks never leak invalid categories, out-of-range confidences, or
    /// invented location names into the review UI / SwiftData store.
    private static func finalizeAnalyses(
        _ items: [ItemAnalysis],
        expectedCount: Int,
        existingLocationNames: [String]
    ) -> [ItemAnalysis] {
        reconcileCount(items, expectedCount: expectedCount).map {
            sanitize($0, existingLocationNames: existingLocationNames)
        }
    }

    /// Defensive: guided generation should return exactly one entry per
    /// region, but pad/truncate if the model returns a mismatched count so
    /// the UI never indexes out of bounds.
    private static func reconcileCount(_ items: [ItemAnalysis], expectedCount: Int) -> [ItemAnalysis] {
        var items = items
        if items.count < expectedCount {
            items += Array(
                repeating: ItemAnalysis(
                    name: "Unidentified Item",
                    category: "Other",
                    subcategory: "",
                    isPerishable: false,
                    estimatedExpiryDateISO: "",
                    expiryConfidence: 0,
                    ripenessNote: "",
                    tags: [],
                    suggestedLocationHint: "",
                    categoryConfidence: 0,
                    detectedPriceAmount: "",
                    detectedPriceCurrency: "",
                    nutrition: NutritionFacts(servingSize: "", calories: -1, proteinGrams: -1, carbsGrams: -1, sugarGrams: -1, fatGrams: -1, fiberGrams: -1, sodiumMilligrams: -1),
                    possibleDuplicateNote: ""
                ),
                count: expectedCount - items.count
            )
        } else if items.count > expectedCount {
            items = Array(items.prefix(expectedCount))
        }
        return items
    }

    /// Post-generation guardrails for AFM output quality.
    private static func sanitize(
        _ analysis: ItemAnalysis,
        existingLocationNames: [String]
    ) -> ItemAnalysis {
        var result = analysis

        // Snap category to the canonical list (case-insensitive; fuzzy contains).
        let normalizedCategory = itemCategoryOptions.first {
            $0.localizedCaseInsensitiveCompare(result.category) == .orderedSame
        } ?? itemCategoryOptions.first {
            result.category.localizedCaseInsensitiveContains($0)
                || $0.localizedCaseInsensitiveContains(result.category)
        } ?? "Other"
        if normalizedCategory != result.category {
            result.category = normalizedCategory
            result.categoryConfidence = min(result.categoryConfidence, 0.55)
        }

        result.categoryConfidence = min(max(result.categoryConfidence, 0), 1)
        result.expiryConfidence = min(max(result.expiryConfidence, 0), 1)

        // Clean name / tags.
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.name.isEmpty { result.name = "Unidentified Item" }
        result.tags = Array(
            result.tags
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty && $0.count <= 32 }
                .prefix(6)
        )

        // Prefer an existing location when the model hint is a near match.
        let hint = result.suggestedLocationHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hint.isEmpty, !existingLocationNames.isEmpty {
            if let exact = existingLocationNames.first(where: {
                $0.localizedCaseInsensitiveCompare(hint) == .orderedSame
            }) {
                result.suggestedLocationHint = exact
            } else if let partial = existingLocationNames.first(where: {
                $0.localizedCaseInsensitiveContains(hint) || hint.localizedCaseInsensitiveContains($0)
            }) {
                result.suggestedLocationHint = partial
            }
        }

        // Drop nonsense prices (negative / absurd multi-million values).
        if let amount = Double(result.detectedPriceAmount), amount < 0 || amount > 1_000_000 {
            result.detectedPriceAmount = ""
            result.detectedPriceCurrency = ""
        }

        // If not perishable, clear expiry noise that models sometimes invent.
        if !result.isPerishable {
            result.estimatedExpiryDateISO = ""
            result.expiryConfidence = 0
            result.ripenessNote = ""
        }

        return result
    }

    private func analysisSessionInstance(existingItems: [StashItem], preferCloud: Bool = false) -> LanguageModelSession {
        let (model, tier) = PreferredModelRouter.resolve(preferCloud: preferCloud)
        let fingerprint = Self.inventoryFingerprint(existingItems)

        if let analysisSession,
           analysisSessionItemCount == existingItems.count,
           analysisSessionTier == tier,
           analysisSessionFingerprint == fingerprint {
            return analysisSession
        }

        let instructions = Instructions {
            """
            You catalog household and personal storage items from photo
            analysis results. You are precise, concise, and never invent
            specific facts that aren't supported by the given labels or
            text. When uncertain about an expiry date or category, prefer a
            lower confidence score rather than a confident wrong guess.

            Special expertise you apply:
            - Fresh produce (fruit/vegetables): identify the specific type
              and variety where possible, and read visible ripeness cues
              (color, spotting, browning, firmness implied by the image
              labels) to write a short ripeness note and estimate a
              realistic remaining-freshness window — not a generic shelf
              life number pulled from nowhere.
            - Watches and jewelry: pay close attention to any OCR'd text
              (brand names, model names, dial text like 'Automatic' or
              'Chronometer') to identify make and model as specifically as
              the evidence supports. Do not guess a specific luxury brand
              from appearance alone without supporting text evidence —
              if uncertain, use a generic descriptive name instead and
              lower your category confidence.
            - Barcode/product database matches: if a region includes an
              online product database match, treat its name/brand/category
              as strong grounding evidence — prefer it over a generic
              visual guess, but still sanity-check it against the visible
              labels (a stale or mismatched barcode lookup should be
              treated with lower confidence).
            - Indian grocery products: recognize common Indian packaged
              food/dairy brands and product naming conventions (e.g. Amul,
              Mother Dairy, Britannia, Haldiram's, Patanjali), regional
              produce names, and typical Indian pack sizes/units. Dairy
              products like milk, curd/dahi, paneer, and ghee are common
              and perishable with short shelf lives unless UHT/ghee.
            - Reading product names from OCR text: prefer the largest,
              highest-confidence line of text as the product's name/brand,
              since packaging design puts the brand and product name in the
              biggest type. Combine adjacent large-text lines if they read
              as one name split across lines (e.g. "COCA" / "COLA"). Ignore
              small print like ingredients lists, barcodes, legal text, and
              regulatory codes when forming the name — those add noise, not
              signal. If OCR text is marked low-confidence, treat it as a
              hint to sanity-check rather than a literal transcription; a
              plausible real product name that's close to a garbled OCR
              read is more likely correct than the garbled text itself.
            - Never name an item after a generic classification label like
              "Document", "Material", "Object", "Texture", "Pattern",
              "Packaging", or "Product" — these are Vision's fallback
              categories for something it couldn't confidently identify,
              not real product names, and using them verbatim is actively
              unhelpful in an inventory. If classification labels are only
              generic like this and OCR/barcode data gives nothing better
              either, write a plain, honest description of what's visible
              instead (e.g. "Small Cardboard Box", "Unlabeled Bottle",
              "Folded Paper Item") and set categoryConfidence low — a
              believable, low-confidence descriptive name the user can
              correct in one tap is far more useful than a bare taxonomy
              word that gives them no information to act on.
            - Reading prices: when a region includes "Price-shaped text"
              candidates, that list has already been filtered to text that
              looks numeric or currency-marked — your job is to pick which
              (if any) is the actual selling price, not to search the rest
              of the OCR text for one. Prefer a candidate with a clear
              currency marker (₹, Rs, $, MRP, etc.) over a bare number.
              Be skeptical of numbers that are more likely a weight/volume
              (e.g. "500", "1kg"), a product code, a phone number, or a
              date rather than a price — a real price is usually the most
              visually prominent number near the product name and, for
              Indian retail, often follows "MRP" or "Rs." A single bare
              1-3 digit number with no other numeric candidates nearby and
              no unit/code context is more likely a price than not. If no
              candidate is plausible, leave the price fields empty rather
              than guessing — an absent price is far better than a wrong
              one that misleads the user's spending records.
            - When multiple regions are provided from the same photo, treat
              them as physically distinct items the user is cataloging
              together (e.g. several products on a shelf, or the same fruit
              bowl containing different items) and analyze each on its own
              merits, but use the others as context to avoid duplicate or
              contradictory guesses.
            - You have access to a lookupExistingInventory tool. Its ONLY
              purpose is to populate `possibleDuplicateNote` as an
              informational aside — it must NEVER influence what you decide
              this item actually IS. Always identify, name, and categorize
              the item currently in front of you strictly from its own
              photo evidence (labels, OCR text, barcode) first; only after
              you've reached that independent conclusion, optionally check
              the tool to see if something similar already exists, and if
              so, mention it in `possibleDuplicateNote` without changing any
              other field. A real restock (e.g. the user buying the same
              brand of milk again) legitimately has a near-identical name
              to an existing item — that's expected and fine. But never
              copy an existing item's name onto a DIFFERENT product just
              because it's in a similar category (e.g. seeing bread should
              never get named after an existing "Milk" entry just because
              both are groceries) — the tool result is context, not a
              template to fill in. Call it sparingly, only when a region's
              own evidence already suggests a plausible match worth
              flagging, not reflexively for every region.
            \(tier == .privateCloudCompute ? "- You are running on Apple's Private Cloud Compute with a larger context window and reasoning capability — use that headroom to reason carefully through ambiguous or large multi-item batches rather than rushing to an answer." : "")

            Today's date is \(Self.todayISO()).
            """
        }

        let session = LanguageModelSession(
            model: model,
            tools: [InventoryLookupTool(items: existingItems)],
            instructions: instructions
        )
        analysisSession = session
        analysisSessionItemCount = existingItems.count
        analysisSessionFingerprint = fingerprint
        analysisSessionTier = tier
        lastUsedTier = tier
        return session
    }

    // MARK: - Natural language search

    /// Translates a free-text query into structured search intent that the
    /// UI layer can apply as a SwiftData predicate / filter. Given tool
    /// access to the live inventory so it can verify candidate matches
    /// exist rather than guessing blind. Falls back to a deterministic
    /// keyword intent when AFM is unavailable so search never hard-fails.
    func interpretSearchQuery(
        _ query: String,
        knownCategories: [String],
        knownLocations: [String],
        existingItems: [StashItem]
    ) async throws -> SearchIntent {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SearchIntent.keywordFallback(for: trimmed, knownCategories: knownCategories, knownLocations: knownLocations)
        }

        guard isAvailableViaAnyTier else {
            lastUsedTier = .heuristicOnly
            return SearchIntent.keywordFallback(for: trimmed, knownCategories: knownCategories, knownLocations: knownLocations)
        }

        let session = searchSessionInstance(existingItems: existingItems)

        let prompt = Prompt {
            """
            Known categories (prefer exact match when relevant): \(knownCategories.joined(separator: ", "))
            Known locations (prefer exact match when relevant): \(knownLocations.joined(separator: ", "))
            Allowed category vocabulary: \(itemCategoryOptions.joined(separator: ", "))

            User query: "\(trimmed)"

            You may call lookupExistingInventory to check whether likely
            matches actually exist before finalizing your answer. Extract
            the search intent. Prefer structured filters over dumping the
            whole query into keywords when category/location/expiry is clear.
            """
        }

        // Slightly higher temperature than structured extraction — search
        // intent interpretation benefits a little from flexibility in
        // reading varied phrasing, but still needs to stay grounded.
        let options = GenerationOptions(temperature: 0.3)

        do {
            let response = try await session.respond(to: prompt, generating: SearchIntent.self, options: options)
            return response.content.sanitized(knownCategories: knownCategories, knownLocations: knownLocations)
        } catch {
            // One narrow retry, then deterministic keyword fallback.
            searchSession = nil
            let retrySession = searchSessionInstance(existingItems: existingItems)
            let retryPrompt = Prompt {
                """
                Convert this inventory search into structured filters only.
                Query: "\(trimmed)"
                Categories: \(knownCategories.joined(separator: ", "))
                Locations: \(knownLocations.joined(separator: ", "))
                """
            }
            do {
                let response = try await retrySession.respond(
                    to: retryPrompt,
                    generating: SearchIntent.self,
                    options: GenerationOptions(temperature: 0.15)
                )
                return response.content.sanitized(knownCategories: knownCategories, knownLocations: knownLocations)
            } catch {
                lastUsedTier = .heuristicOnly
                return SearchIntent.keywordFallback(
                    for: trimmed,
                    knownCategories: knownCategories,
                    knownLocations: knownLocations
                )
            }
        }
    }

    private func searchSessionInstance(existingItems: [StashItem]) -> LanguageModelSession {
        // Search doesn't need PCC's extra headroom for a normal-sized
        // inventory, so preferCloud stays false here — but if on-device
        // itself isn't ready (Apple Intelligence still enabling, model
        // downloading), resolve() transparently falls through to PCC when
        // available rather than leaving search broken.
        let (model, tier) = PreferredModelRouter.resolve(preferCloud: false)

        // Fingerprint includes a cheap content signature so renames/edits
        // without count changes still refresh tool snapshots.
        let fingerprint = Self.inventoryFingerprint(existingItems)
        if let searchSession,
           searchSessionItemCount == existingItems.count,
           searchSessionTier == tier,
           searchSessionFingerprint == fingerprint {
            return searchSession
        }

        let instructions = Instructions {
            """
            You translate a user's natural-language search over their personal
            storage inventory into structured filters. Only use category or
            location names from the provided lists if they clearly match;
            otherwise leave those fields empty and rely on keywords.
            Recognise common phrasings: "expiring", "expired", "about to go bad"
            → expiryFocused / perishabilityFilter; "in the fridge", "garage"
            → location; "dairy", "electronics" → category; "cheap"/"priced"
            → priceFocused. Use the lookupExistingInventory tool to verify a
            candidate interpretation actually matches something in the inventory
            when you're unsure. Prefer empty structured fields over wrong ones.
            Today's date is \(Self.todayISO()).
            """
        }

        let session = LanguageModelSession(
            model: model,
            tools: [InventoryLookupTool(items: existingItems)],
            instructions: instructions
        )
        searchSession = session
        searchSessionTier = tier
        lastUsedTier = tier
        searchSessionItemCount = existingItems.count
        searchSessionFingerprint = fingerprint
        return session
    }

    /// Cheap content signature for warm-session invalidation (count alone
    /// misses renames and location moves).
    private static func inventoryFingerprint(_ items: [StashItem]) -> Int {
        var hasher = Hasher()
        hasher.combine(items.count)
        for item in items.prefix(64) {
            hasher.combine(item.name)
            hasher.combine(item.category)
            hasher.combine(item.location?.name)
            hasher.combine(item.updatedAt.timeIntervalSinceReferenceDate)
        }
        return hasher.finalize()
    }

    /// Call when the underlying item set changes significantly (e.g. after
    /// saving new items) so the next tool-enabled session sees fresh data
    /// rather than a stale snapshot captured at session-creation time.
    /// (Kept alongside the automatic count-based staleness check above as
    /// an explicit, immediate invalidation path for call sites that want
    /// to force a refresh regardless of count, e.g. after an edit that
    /// doesn't change the total item count.)
    func invalidateSessions() {
        analysisSession = nil
        searchSession = nil
        analysisSessionItemCount = -1
        searchSessionItemCount = -1
        analysisSessionFingerprint = 0
        searchSessionFingerprint = 0
        analysisSessionTier = nil
        searchSessionTier = nil
    }

    private var unavailableReason: SystemLanguageModel.Availability.UnavailableReason {
        if case .unavailable(let reason) = model.availability {
            return reason
        }
        // Shouldn't happen given call sites guard on availability first.
        return .appleIntelligenceNotEnabled
    }

    private static func todayISO() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: .now)
    }
}

@Generable
struct SearchIntent: Equatable {
    @Guide(description: "Keywords extracted from the query for text matching against item names, tags, and notes. Empty array if the query is purely about category/location/expiry.")
    var keywords: [String]

    @Guide(description: "A matching known category name if the query clearly references one, otherwise empty string. Prefer an exact name from the provided category list.")
    var category: String

    @Guide(description: "A matching known location name if the query clearly references one, otherwise empty string.")
    var location: String

    @Guide(description: "True if the user is specifically asking about items that are expiring soon or expired.")
    var expiryFocused: Bool

    @Guide(
        description: "Optional finer perishability filter when expiry is relevant.",
        .anyOf(["any", "expired", "expiring_soon", "fresh"])
    )
    var perishabilityFilter: String

    @Guide(description: "True if the user is asking about priced items, cost, value, expensive, or cheap products.")
    var priceFocused: Bool
}

extension SearchIntent {
    /// Clamp / snap model output so UI filters never receive invented
    /// category or location strings that match nothing in inventory.
    func sanitized(knownCategories: [String], knownLocations: [String]) -> SearchIntent {
        var intent = self

        if !intent.category.isEmpty {
            intent.category = knownCategories.first {
                $0.localizedCaseInsensitiveCompare(intent.category) == .orderedSame
            } ?? knownCategories.first {
                $0.localizedCaseInsensitiveContains(intent.category)
                    || intent.category.localizedCaseInsensitiveContains($0)
            } ?? itemCategoryOptions.first {
                $0.localizedCaseInsensitiveCompare(intent.category) == .orderedSame
            } ?? ""
        }

        if !intent.location.isEmpty {
            intent.location = knownLocations.first {
                $0.localizedCaseInsensitiveCompare(intent.location) == .orderedSame
            } ?? knownLocations.first {
                $0.localizedCaseInsensitiveContains(intent.location)
                    || intent.location.localizedCaseInsensitiveContains($0)
            } ?? ""
        }

        let allowedFilters: Set<String> = ["any", "expired", "expiring_soon", "fresh"]
        if !allowedFilters.contains(intent.perishabilityFilter.lowercased()) {
            intent.perishabilityFilter = intent.expiryFocused ? "expiring_soon" : "any"
        } else {
            intent.perishabilityFilter = intent.perishabilityFilter.lowercased()
        }

        if intent.perishabilityFilter == "expired" || intent.perishabilityFilter == "expiring_soon" {
            intent.expiryFocused = true
        }

        intent.keywords = intent.keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return intent
    }

    /// Offline / model-unavailable path: light keyword rules that still
    /// produce useful structured filters without AFM.
    static func keywordFallback(
        for query: String,
        knownCategories: [String],
        knownLocations: [String]
    ) -> SearchIntent {
        let lower = query.lowercased()
        var category = ""
        var location = ""
        var expiryFocused = false
        var perishabilityFilter = "any"
        var priceFocused = false

        for known in knownCategories {
            if lower.contains(known.lowercased()) {
                category = known
                break
            }
        }
        if category.isEmpty {
            for option in itemCategoryOptions {
                let token = option.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
                if !token.isEmpty, lower.contains(token) {
                    category = option
                    break
                }
            }
        }

        for known in knownLocations {
            if lower.contains(known.lowercased()) {
                location = known
                break
            }
        }

        if lower.contains("expired") {
            expiryFocused = true
            perishabilityFilter = "expired"
        } else if lower.contains("expir") || lower.contains("soon") || lower.contains("spoil") {
            expiryFocused = true
            perishabilityFilter = "expiring_soon"
        } else if lower.contains("fresh") {
            perishabilityFilter = "fresh"
        }

        if lower.contains("price") || lower.contains("cost") || lower.contains("cheap")
            || lower.contains("expensive") || lower.contains("₹") || lower.contains("rs") {
            priceFocused = true
        }

        // Keywords: drop stop-words and structural tokens already mapped.
        let stop: Set<String> = [
            "the", "a", "an", "my", "in", "on", "at", "of", "for", "to", "and",
            "or", "where", "what", "which", "is", "are", "me", "show", "find",
            "items", "item", "stash", "expired", "expiring", "soon", "fresh"
        ]
        var keywords = query
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map { String($0).lowercased() }
            .filter { $0.count > 1 && !stop.contains($0) }
        if !category.isEmpty {
            keywords.removeAll { category.lowercased().contains($0) }
        }
        if !location.isEmpty {
            keywords.removeAll { location.lowercased().contains($0) }
        }

        return SearchIntent(
            keywords: keywords,
            category: category,
            location: location,
            expiryFocused: expiryFocused,
            perishabilityFilter: perishabilityFilter,
            priceFocused: priceFocused
        )
    }
}
