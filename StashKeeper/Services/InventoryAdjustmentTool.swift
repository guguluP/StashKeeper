//
//  InventoryAdjustmentTool.swift
//  StashKeeper
//
//  A write-capable Foundation Models Tool: unlike InventoryLookupTool and
//  HealthContextTool (both read-only), this one lets the assistant chat
//  actually change the user's inventory mid-conversation — e.g. "I just
//  used the last 2 eggs" or "I finished the shampoo" decrements or removes
//  the matching item directly, rather than the user having to leave the
//  chat and edit it by hand. This is a genuinely new capability class for
//  the app: the model goes from "answers questions about your data" to
//  "acts on your data," with real safety rails since this crosses from
//  read to write.
//
//  Safety design:
//  - Only ever adjusts an EXISTING item found by a confident name match —
//    never creates new items (that stays the Add Item flow's job, which
//    has its own deliberate multi-step review UI) and never deletes a
//    whole item's history silently; reaching quantity 0 zeroes the count
//    but leaves the row in place so nothing vanishes without a trace.
//  - Requires the caller (the assistant) to have already confirmed intent
//    in natural language — the tool itself applies one more guard: it
//    refuses ambiguous matches (multiple similarly-named items) rather
//    than guessing which one the user meant, surfacing the ambiguity back
//    to the model so it can ask the user to clarify instead.
//  - Every successful adjustment is echoed back in the tool result with
//    the resulting quantity, so the model's follow-up chat message always
//    reflects the true post-adjustment state rather than assuming success.
//
//  Swift 6 concurrency note: mirrors InventoryLookupTool's approach —
//  StashItem is a main-actor-isolated SwiftData @Model type, not Sendable,
//  so this tool holds a reference to the @MainActor ModelContext (itself
//  fine to capture since the whole type is @MainActor) rather than trying
//  to carry live model objects across an actor boundary.
//

import Foundation
import FoundationModels
import SwiftData

nonisolated private struct InventoryAdjustmentResult: Codable, Sendable {
    let success: Bool
    let matchedItemName: String?
    let previousQuantity: Int?
    let newQuantity: Int?
    let message: String
}

/// Foundation Models Tool conformance — the model decides when to call
/// this, e.g. when the user says they used, finished, consumed, or threw
/// away some amount of an item they have stored.
///
/// Not marked `@MainActor` at the type level (unlike its `init`) to match
/// `HealthContextTool`'s pattern: `Tool.call` is async but not guaranteed
/// to run on the main actor, and `Tool` conformance requires `Sendable`.
/// `ModelContext` itself is bound to the actor it was created on (the main
/// actor, since it's created from a SwiftUI `@Environment` value here) —
/// capturing it is safe because every actual access happens by hopping
/// back via `MainActor.run` inside `call`, never touching it from a
/// background context directly.
struct InventoryAdjustmentTool: Tool, @unchecked Sendable {
    let name = "adjustItemQuantity"
    let description = """
        Adjusts the stored quantity of an EXISTING item the user already
        has cataloged — use this when the user says they used, consumed,
        finished, threw away, or otherwise reduced the amount of
        something they have (e.g. "I used 2 eggs", "I finished the milk",
        "threw away the expired bread"). Also supports increasing
        quantity for a quick restock without going through the photo Add
        Item flow (e.g. "add 3 more to my paper towels"). Matches by
        name — if the name is ambiguous (matches multiple different
        items) or matches nothing, this returns an explanation instead of
        guessing; ask the user to clarify which item they mean rather
        than calling this again with a guess. This tool can only change
        an existing item's quantity — it cannot create brand new items
        (tell the user to use the in-app Add Item camera flow for that)
        or delete an item entirely.
        """

    /// The live model context adjustments are applied through. Captured
    /// at tool-construction time (main actor, same as the call site that
    /// builds the assistant's session) rather than per-call, since a
    /// LanguageModelSession's tools are fixed for the session's lifetime
    /// anyway. Every access to it happens via `MainActor.run` in `call`.
    private let modelContext: ModelContext

    @MainActor
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    @Generable
    struct Arguments {
        @Guide(description: "The item's name (or a close partial match) as the user referred to it, e.g. 'eggs' or 'milk'.")
        var itemName: String

        @Guide(description: "How much to change the quantity by. Positive to increase (restock), negative to decrease (used/consumed/thrown away). E.g. -2 for 'used 2 eggs', -1 for 'finished the milk' (if you don't know the exact remaining count, -1 is a reasonable default for 'finished'/'used up' language covering the last one). Never 0.")
        var quantityDelta: Int

    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            Self.performAdjustment(arguments: arguments, modelContext: modelContext)
        }
    }

    @MainActor
    private static func performAdjustment(arguments: Arguments, modelContext: ModelContext) -> String {
        guard arguments.quantityDelta != 0 else {
            return Self.encode(InventoryAdjustmentResult(
                success: false, matchedItemName: nil, previousQuantity: nil, newQuantity: nil,
                message: "quantityDelta must not be zero — no adjustment was made."
            ))
        }

        let trimmedQuery = arguments.itemName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return Self.encode(InventoryAdjustmentResult(
                success: false, matchedItemName: nil, previousQuantity: nil, newQuantity: nil,
                message: "No item name was provided."
            ))
        }

        let descriptor = FetchDescriptor<StashItem>()
        guard let allItems = try? modelContext.fetch(descriptor) else {
            return Self.encode(InventoryAdjustmentResult(
                success: false, matchedItemName: nil, previousQuantity: nil, newQuantity: nil,
                message: "Couldn't read the inventory right now."
            ))
        }

        // Prefer an exact (case-insensitive) name match; only fall back to
        // partial/contains matching if there's no exact hit, and require
        // that fallback to be unambiguous — this is the guard against
        // silently adjusting the wrong item when several plausible
        // candidates exist (e.g. "milk" matching both "Amul Toned Milk"
        // and "Coconut Milk").
        let exactMatches = allItems.filter {
            $0.name.localizedCaseInsensitiveCompare(trimmedQuery) == .orderedSame
        }
        let candidates: [StashItem]
        if exactMatches.count == 1 {
            candidates = exactMatches
        } else if exactMatches.count > 1 {
            candidates = exactMatches // ambiguous even among exact matches (rare, e.g. two locations)
        } else {
            candidates = allItems.filter {
                $0.name.localizedCaseInsensitiveContains(trimmedQuery)
                    || trimmedQuery.localizedCaseInsensitiveContains($0.name)
            }
        }

        guard !candidates.isEmpty else {
            return Self.encode(InventoryAdjustmentResult(
                success: false, matchedItemName: nil, previousQuantity: nil, newQuantity: nil,
                message: "No item matching '\(trimmedQuery)' was found in the inventory. Don't guess — ask the user for the exact name, or suggest they add it via the Add Item flow if it's new."
            ))
        }

        guard candidates.count == 1 else {
            let names = candidates.prefix(5).map(\.name).joined(separator: "', '")
            return Self.encode(InventoryAdjustmentResult(
                success: false, matchedItemName: nil, previousQuantity: nil, newQuantity: nil,
                message: "Multiple items match '\(trimmedQuery)': '\(names)'. Ask the user which one they mean before adjusting anything."
            ))
        }

        let item = candidates[0]
        let previousQuantity = item.quantity
        let newQuantity = max(0, previousQuantity + arguments.quantityDelta)
        item.quantity = newQuantity
        item.updatedAt = .now
        try? modelContext.save()

        let clampNote = (previousQuantity + arguments.quantityDelta) < 0
            ? " (requested decrease exceeded what was on hand, so it was clamped to 0 rather than going negative)"
            : ""

        return Self.encode(InventoryAdjustmentResult(
            success: true,
            matchedItemName: item.name,
            previousQuantity: previousQuantity,
            newQuantity: newQuantity,
            message: "Updated '\(item.name)' from \(previousQuantity) to \(newQuantity)\(clampNote)."
        ))
    }

    private static func encode(_ result: InventoryAdjustmentResult) -> String {
        let encoder = JSONEncoder()
        let data = (try? encoder.encode(result)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "Adjustment unavailable."
    }
}
