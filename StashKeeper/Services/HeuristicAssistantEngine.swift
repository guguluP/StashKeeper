//
//  HeuristicAssistantEngine.swift
//  StashKeeper
//
//  A zero-AI fallback for the Stash Assistant chat, used automatically on
//  devices that can't run Apple Intelligence at all (below the on-device
//  model's hardware floor) and also have no Private Cloud Compute
//  available. Mirrors the philosophy of HeuristicItemNamer in
//  ItemIntelligenceService: rather than a bare "AI unavailable" dead end,
//  this answers the handful of concrete, high-value question types a
//  user is most likely to ask — using plain keyword matching and the
//  same InventorySnapshotItem/HealthKit data the AFM-backed path would
//  otherwise hand to a tool call — with simple, explainable rules instead
//  of language understanding.
//
//  This deliberately does NOT try to imitate free-form conversation. It
//  recognizes a small set of intents (expiry check, category/location
//  lookup, quantity check, health summary, simple recipe suggestion) and
//  falls back to an honest "I can't answer that without Apple
//  Intelligence" for anything else, rather than guessing at open-ended
//  questions with no language model behind it.
//

import Foundation

enum HeuristicAssistantEngine {

    /// Attempts to answer a message using rule-based logic only. Returns
    /// nil if the message doesn't match any recognized intent — callers
    /// should show a plain "can't help with that offline" message rather
    /// than treating nil as a hidden failure.
    @MainActor
    static func respond(to message: String, items: [InventorySnapshotItem], fitnessSummary: FitnessContext?) -> String {
        let lowered = message.lowercased()

        if isExpiryQuestion(lowered) {
            return expiryAnswer(items: items)
        }
        if isHealthQuestion(lowered) {
            return healthAnswer(fitnessSummary: fitnessSummary)
        }
        if isRecipeQuestion(lowered) {
            return recipeAnswer(items: items)
        }
        if let locationOrCategory = matchedLocationOrCategoryQuery(lowered, items: items) {
            return locationOrCategory
        }
        if let itemMatch = matchedItemNameQuery(lowered, items: items) {
            return itemMatch
        }

        return """
            I can't have a full conversation without Apple Intelligence, but I can still answer a few things directly — try asking "what's expiring soon", "what's in the [location]", "how many [item] do I have", or "what can I cook".
            """
    }

    // MARK: - Intent matching

    private static func isExpiryQuestion(_ text: String) -> Bool {
        ["expir", "going bad", "spoil", "use soon", "use up"].contains { text.contains($0) }
    }

    private static func isHealthQuestion(_ text: String) -> Bool {
        ["steps", "calories", "workout", "activity", "burned", "how active"].contains { text.contains($0) }
    }

    private static func isRecipeQuestion(_ text: String) -> Bool {
        ["cook", "recipe", "make with", "eat", "meal", "snack"].contains { text.contains($0) }
    }

    // MARK: - Answers

    private static func expiryAnswer(items: [InventorySnapshotItem]) -> String {
        let expiring = items
            .filter { $0.isPerishable && ($0.daysUntilExpiry ?? Int.max) <= 5 }
            .sorted { ($0.daysUntilExpiry ?? Int.max) < ($1.daysUntilExpiry ?? Int.max) }

        guard !expiring.isEmpty else {
            return "Nothing in your stash is expiring in the next 5 days, based on what's recorded."
        }

        let lines = expiring.prefix(8).map { item -> String in
            let days = item.daysUntilExpiry ?? 0
            let when = days <= 0 ? "today or already past" : "in \(days) day\(days == 1 ? "" : "s")"
            return "• \(item.name) — \(when)"
        }
        let more = expiring.count > 8 ? "\n…and \(expiring.count - 8) more." : ""
        return "Here's what's expiring soon:\n" + lines.joined(separator: "\n") + more
    }

    private static func healthAnswer(fitnessSummary: FitnessContext?) -> String {
        guard let fitnessSummary else {
            return "I don't have today's Health data — either access hasn't been granted, or nothing's been recorded yet today."
        }
        var parts: [String] = []
        parts.append("about \(fitnessSummary.approximateSteps) steps")
        parts.append("roughly \(fitnessSummary.approximateActiveEnergyBurned) kcal of active energy burned")
        if let consumed = fitnessSummary.approximateDietaryEnergyConsumed {
            parts.append("about \(consumed) kcal logged as eaten")
        }
        return "So far today: " + parts.joined(separator: ", ") + "."
    }

    /// Deliberately simple: surfaces perishable items on hand rather than
    /// generating an actual recipe, since composing a coherent recipe from
    /// arbitrary ingredients is exactly the kind of open-ended reasoning
    /// this offline tier is not meant to attempt.
    private static func recipeAnswer(items: [InventorySnapshotItem]) -> String {
        let candidates = items
            .filter { ["Fresh Produce", "Dairy", "Pantry & Food"].contains($0.category) && $0.quantity > 0 }
            .sorted { ($0.daysUntilExpiry ?? Int.max) < ($1.daysUntilExpiry ?? Int.max) }

        guard !candidates.isEmpty else {
            return "I don't see any food items in your stash to suggest something with right now."
        }

        let names = candidates.prefix(6).map(\.name).joined(separator: ", ")
        return """
            I can't generate a full recipe without Apple Intelligence, but here's what food you have on hand to work with: \(names). Anything expiring soonest is listed first, so that's a good place to start.
            """
    }

    /// Matches "what's in the pantry", "what's in the kitchen", or a
    /// direct category name like "dairy" against actual location/category
    /// values in the inventory — no fuzzy NLP, just substring containment
    /// against known values, so it only ever answers when there's a real
    /// match to point to.
    private static func matchedLocationOrCategoryQuery(_ text: String, items: [InventorySnapshotItem]) -> String? {
        guard text.contains("in the") || text.contains("in my") || text.contains("what's in") else { return nil }

        let knownLocations = Set(items.compactMap(\.locationName)).sorted()
        let knownCategories = Set(items.map(\.category)).sorted()

        if let location = knownLocations.first(where: { text.contains($0.lowercased()) }) {
            let matches = items.filter { $0.locationName == location }
            return summarize(matches, headline: "In \(location):")
        }
        if let category = knownCategories.first(where: { text.contains($0.lowercased()) }) {
            let matches = items.filter { $0.category == category }
            return summarize(matches, headline: "In \(category):")
        }
        return nil
    }

    /// Matches "how many X do I have" / "do I have X" against item names,
    /// via simple substring matching on the significant words in the
    /// question.
    private static func matchedItemNameQuery(_ text: String, items: [InventorySnapshotItem]) -> String? {
        guard text.contains("how many") || text.contains("do i have") else { return nil }

        let stopWords: Set<String> = ["how", "many", "do", "i", "have", "of", "a", "an", "the", "in", "my", "stash", "left", "any"]
        let words = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) }

        guard !words.isEmpty else { return nil }

        let matches = items.filter { item in
            let lowered = item.name.lowercased()
            return words.contains { lowered.contains($0) }
        }

        guard !matches.isEmpty else {
            return "I couldn't find anything matching that in your stash."
        }
        return summarize(matches, headline: "Found:")
    }

    private static func summarize(_ items: [InventorySnapshotItem], headline: String) -> String {
        guard !items.isEmpty else {
            return "Nothing matches that right now."
        }
        let lines = items.prefix(10).map { "• \($0.name) — qty \($0.quantity)" }
        let more = items.count > 10 ? "\n…and \(items.count - 10) more." : ""
        return headline + "\n" + lines.joined(separator: "\n") + more
    }
}
