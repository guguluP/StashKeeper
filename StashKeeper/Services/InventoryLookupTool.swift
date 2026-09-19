//
//  InventoryLookupTool.swift
//  StashKeeper
//
//  A Foundation Models Tool that lets the model query the user's existing
//  StashItem inventory mid-reasoning — used during item analysis so the
//  model can notice "the user already has 2 of these at this location"
//  and factor that into naming/quantity suggestions, and during search so
//  the model can iteratively refine a query against real data instead of
//  guessing a single-shot filter.
//
//  This is the concrete "tool calling" upgrade: rather than one-shot
//  guided generation over static context, the model can call back into
//  app code to ground its answers in the actual current inventory.
//
//  Swift 6 strict concurrency note: a Foundation Models Tool must be
//  Sendable, but StashItem is a SwiftData @Model reference type and is
//  NOT Sendable (model objects are tied to a specific ModelContext/actor).
//  So this tool never stores live StashItem references — instead it
//  snapshots everything it needs into a plain Sendable struct
//  (InventorySnapshotItem) at tool-creation time, before crossing into
//  the tool's Sendable boundary.
//

import Foundation
import FoundationModels
import SwiftData

/// A plain, Sendable snapshot of the fields InventoryLookupTool needs from
/// a StashItem, captured before being handed to the tool. Never holds a
/// live model reference.
struct InventorySnapshotItem: Sendable {
    /// Stable identity for mapping a tool result or a deterministic match
    /// back to the real StashItem afterward (e.g. to bump its quantity
    /// instead of creating a duplicate row).
    let persistentID: PersistentIdentifier
    let name: String
    let category: String
    let locationName: String?
    let quantity: Int
    let isPerishable: Bool
    let daysUntilExpiry: Int?
    let searchableText: String
    /// Barcode payload recorded when this item was originally added, if
    /// any — the single strongest signal for "this is literally the same
    /// product," used both by the general lookup tool and by the
    /// dedicated re-scan matcher below.
    let barcodePayload: String?
    /// Raw OCR text captured when this item was originally added. Used to
    /// match serial numbers, model numbers, or lot codes against a fresh
    /// re-scan of what might be the exact same physical object.
    let recognizedText: String?
    /// Recorded price, if any — surfaced to tools so the chatbot and other
    /// tool-calling features can answer spend-related questions without a
    /// second query path.
    let priceAmount: Double?
    let priceCurrency: String?

    /// Explicitly `@MainActor` because `StashItem` is a SwiftData `@Model`
    /// class, which is main-actor-isolated by default. Snapshotting must
    /// happen while already on the main actor (e.g. from a SwiftUI view or
    /// `@MainActor` call site) — this initializer can't be called from a
    /// background/nonisolated context.
    @MainActor
    init(from item: StashItem) {
        self.persistentID = item.persistentModelID
        self.name = item.name
        self.category = item.category
        self.locationName = item.location?.name
        self.quantity = item.quantity
        self.isPerishable = item.isPerishable
        self.daysUntilExpiry = item.daysUntilExpiry
        self.searchableText = item.searchableText
        self.barcodePayload = item.barcodePayload
        self.recognizedText = item.recognizedText
        self.priceAmount = item.priceAmount
        self.priceCurrency = item.priceCurrency
    }
}

/// Deterministic (non-LLM) matcher for "have I already cataloged the exact
/// physical object I'm looking at right now?" — used when re-scanning an
/// item, e.g. photographing the same electronics box again to check on it,
/// or re-scanning a product to bump its quantity instead of accidentally
/// creating a second inventory entry for the same real-world item.
///
/// Deliberately implemented as plain Swift comparisons rather than another
/// language-model call: exact barcode and serial-number matching is a
/// mechanical string-matching problem with a clear right answer, and
/// getting it wrong (silently duplicating or silently merging two actually
/// different items) is exactly the failure mode this feature exists to
/// prevent — so it shouldn't inherit any model non-determinism.
enum ExistingItemMatcher {
    struct Match: Sendable {
        let item: InventorySnapshotItem
        let confidence: MatchConfidence
        let reason: String
    }

    enum MatchConfidence: Sendable, Comparable {
        case weak
        case strong
        case exact
    }

    /// Looks for the strongest possible match between a freshly-scanned
    /// candidate and the existing inventory, checked in order from most to
    /// least reliable signal. Returns nil if nothing meets even the "weak"
    /// bar, so a genuinely new item is never forced into a false match.
    static func findMatch(
        barcodePayload: String?,
        recognizedText: [String],
        candidateName: String,
        candidateCategory: String,
        in existingItems: [InventorySnapshotItem]
    ) -> Match? {
        // 1. Exact barcode match — the gold standard. Two items with the
        // identical scanned barcode are, for all practical purposes,
        // guaranteed to be the same product (though not necessarily the
        // same physical unit if it's a consumable the user buys often —
        // callers decide whether that means "same item, bump quantity" or
        // "new unit of a restocked product" based on context).
        if let barcodePayload, !barcodePayload.isEmpty {
            if let match = existingItems.first(where: { $0.barcodePayload == barcodePayload }) {
                return Match(item: match, confidence: .exact, reason: "Matches barcode \(barcodePayload)")
            }
        }

        // 2. Serial number / distinctive code match via OCR text overlap.
        // Only trusts tokens that look like an actual identifier (a mix of
        // letters and digits, reasonably long) rather than matching on any
        // shared word — matching on "500" or "Model" would produce false
        // positives constantly.
        let candidateSerialTokens = Set(extractSerialLikeTokens(from: recognizedText))
        if !candidateSerialTokens.isEmpty {
            for existing in existingItems {
                guard let existingText = existing.recognizedText, !existingText.isEmpty else { continue }
                let existingTokens = Set(extractSerialLikeTokens(from: existingText.components(separatedBy: "\n")))
                if !candidateSerialTokens.isDisjoint(with: existingTokens) {
                    let sharedToken = candidateSerialTokens.intersection(existingTokens).first ?? ""
                    return Match(item: existing, confidence: .strong, reason: "Matches serial/model code '\(sharedToken)' found on both")
                }
            }
        }

        // 3. Weak fallback: identical name AND category. Not strong enough
        // to auto-merge, but worth surfacing as "you might already have
        // this" for the user to decide — this mirrors what
        // possibleDuplicateNote already communicates from the LLM side,
        // kept here too since this matcher can run even when Apple
        // Intelligence itself is unavailable.
        if let nameMatch = existingItems.first(where: {
            $0.name.localizedCaseInsensitiveCompare(candidateName) == .orderedSame &&
            $0.category.localizedCaseInsensitiveCompare(candidateCategory) == .orderedSame
        }) {
            return Match(item: nameMatch, confidence: .weak, reason: "Same name and category as an existing item")
        }

        return nil
    }

    /// Pulls tokens that look like serial numbers, model numbers, or lot
    /// codes out of OCR text — a mix of letters and digits, at least 5
    /// characters, since that pattern is very rarely a coincidence between
    /// two unrelated products but common phrasing (dates, prices, generic
    /// words) is filtered out.
    private static func extractSerialLikeTokens(from lines: [String]) -> [String] {
        lines
            .flatMap { $0.components(separatedBy: CharacterSet.alphanumerics.inverted) }
            .filter { token in
                guard token.count >= 5 else { return false }
                let hasLetter = token.contains { $0.isLetter }
                let hasDigit = token.contains { $0.isNumber }
                return hasLetter && hasDigit
            }
            .map { $0.uppercased() }
    }
}

/// A single existing item summary returned to the model — deliberately
/// compact (not the full snapshot) since this goes back into the model's
/// context window.
private struct InventoryLookupResultItem: Codable, Sendable {
    let name: String
    let category: String
    let location: String
    let quantity: Int
    let isPerishable: Bool
    let daysUntilExpiry: Int?
    let barcode: String?
    let hasPrice: Bool
    let tagsPreview: String
}

/// Foundation Models Tool conformance — the model decides when to call
/// this during a session with tool access, based on the tool's name and
/// description below.
struct InventoryLookupTool: Tool {
    let name = "lookupExistingInventory"
    let description = """
        Searches the user's existing stored items to check what they
        already have. Use this before finalizing an item analysis to
        notice likely duplicates (e.g. 'they already have 3 of these at
        this location, this might be a restock not a new distinct item'),
        or during search/chat to verify a candidate match actually exists.
        Results include quantity, location, perishability, daysUntilExpiry,
        optional barcode, and price. When the user asks what to cook or
        what needs attention, ALWAYS surface items with the soonest
        (or already-passed) expiry first.
        """

    /// Sendable snapshot of items to search against, captured at
    /// tool-creation time from live StashItem objects on the main actor.
    let items: [InventorySnapshotItem]

    /// Must be constructed on the main actor since it reads live
    /// `StashItem` objects (main-actor-isolated by default as a SwiftData
    /// model) into a `Sendable` snapshot before the tool itself crosses
    /// into Foundation Models' concurrent tool-calling context.
    @MainActor
    init(items: [StashItem]) {
        self.items = items.map(InventorySnapshotItem.init)
    }

    @Generable
    struct Arguments {
        @Guide(description: "Search text to match against item names, tags, barcodes, and categories, e.g. 'milk' or 'AA battery'. Leave empty to just browse by category/location instead.")
        var query: String

        @Guide(description: "Restrict results to this category if known, otherwise empty string.")
        var category: String

        @Guide(description: "Restrict results to this storage location name if known, otherwise empty string.")
        var location: String

        @Guide(description: "If true, only return perishable items (food, medicine, etc.). False means no perishability filter.")
        var perishableOnly: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        var matches = items

        if !arguments.category.isEmpty {
            matches = matches.filter {
                $0.category.localizedCaseInsensitiveCompare(arguments.category) == .orderedSame
                    || $0.category.localizedCaseInsensitiveContains(arguments.category)
            }
        }
        if !arguments.location.isEmpty {
            matches = matches.filter { item in
                guard let locationName = item.locationName else { return false }
                return locationName.localizedCaseInsensitiveCompare(arguments.location) == .orderedSame
                    || locationName.localizedCaseInsensitiveContains(arguments.location)
            }
        }
        if arguments.perishableOnly {
            matches = matches.filter(\.isPerishable)
        }
        if !arguments.query.isEmpty {
            let q = arguments.query
            matches = matches.filter {
                $0.searchableText.localizedCaseInsensitiveContains(q)
                    || ($0.barcodePayload?.localizedCaseInsensitiveContains(q) ?? false)
            }
            // Prefer closer name matches first so the model sees the best hits.
            matches.sort { lhs, rhs in
                let l = lhs.name.localizedCaseInsensitiveContains(q) ? 0 : 1
                let r = rhs.name.localizedCaseInsensitiveContains(q) ? 0 : 1
                if l != r { return l < r }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }

        let richResults = matches.prefix(12).map { item -> InventoryLookupResultItem in
            InventoryLookupResultItem(
                name: item.name,
                category: item.category,
                location: item.locationName ?? "Unspecified",
                quantity: item.quantity,
                isPerishable: item.isPerishable,
                daysUntilExpiry: item.daysUntilExpiry,
                barcode: item.barcodePayload.flatMap { $0.isEmpty ? nil : $0 },
                hasPrice: item.priceAmount != nil,
                tagsPreview: String(item.searchableText.prefix(80))
            )
        }

        guard !richResults.isEmpty else {
            return "No matching items found in the existing inventory."
        }

        let encoder = JSONEncoder()
        let data = (try? encoder.encode(Array(richResults))) ?? Data()
        return String(data: data, encoding: .utf8) ?? "No matching items found."
    }
}
