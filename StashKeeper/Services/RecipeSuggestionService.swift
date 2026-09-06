//
//  RecipeSuggestionService.swift
//  StashKeeper
//
//  Generates recipe suggestions when the Add Item flow detects multiple
//  fruit/vegetable items in one photo, optionally personalized with
//  today's HealthKit activity summary. Uses the same on-device-first,
//  Private-Cloud-Compute-fallback routing as ItemIntelligenceService
//  (see PreferredModelRouter) rather than duplicating that logic.
//

import Foundation
import FoundationModels

/// A deliberately small, rounded summary of today's activity, passed to
/// AFM as plain-language context for recipe suggestions. Defined here
/// (rather than reusing HealthKitService.TodayFitnessSummary directly) so
/// this file has no implicit dependency on HealthKit/iOS-only code — the
/// Add Item flow constructs one of these from HealthKitService's real
/// summary when available and passes it in as plain data.
struct FitnessContext: Sendable {
    let approximateSteps: Int
    let approximateActiveEnergyBurned: Int
    let approximateDietaryEnergyConsumed: Int?

    var activityLevelDescription: String {
        switch approximateSteps {
        case ..<3000: return "a fairly low-activity day so far"
        case 3000..<8000: return "a moderately active day so far"
        default: return "a high-activity day so far"
        }
    }
}

@MainActor
final class RecipeSuggestionService {
    static let shared = RecipeSuggestionService()

    private init() {}

    /// Produce-adjacent categories/keywords used to decide whether a batch
    /// of detected items is "enough fresh produce to suggest a recipe for"
    /// — deliberately simple keyword matching on the category/name AFM (or
    /// the heuristic tier) already assigned, rather than a second
    /// classification pass, since this is just a trigger condition, not a
    /// judgment that needs to be especially precise.
    private static let produceKeywords: Set<String> = [
        "banana", "apple", "tomato", "onion", "potato", "carrot", "spinach",
        "pepper", "cucumber", "broccoli", "cauliflower", "cabbage", "garlic",
        "ginger", "lemon", "lime", "orange", "mango", "grape", "berry",
        "berries", "avocado", "zucchini", "eggplant", "brinjal", "peas",
        "beans", "corn", "lettuce", "kale", "produce", "vegetable", "fruit"
    ]

    /// Returns true if at least 2 of the given analyses look like fresh
    /// produce — the trigger condition for offering a recipe suggestion at
    /// all. Checked against both `category` and `name` since the heuristic
    /// fallback tier (see HeuristicItemNamer) may only get category right,
    /// while AFM might put "Bananas" in a general "Groceries" category.
    static func hasEnoughProduceForSuggestion(_ analyses: [ItemAnalysis]) -> Bool {
        let produceCount = analyses.filter { analysis in
            let haystack = (analysis.category + " " + analysis.name).lowercased()
            return Self.produceKeywords.contains { haystack.contains($0) }
        }.count
        return produceCount >= 2
    }

    /// Generates 1-3 recipe suggestions for the given produce items.
    /// Returns an empty array (never throws) on any failure — this is a
    /// delightful-but-optional feature, never something that should block
    /// or degrade the core Add Item flow if generation fails or no AI tier
    /// is available at all (there's no meaningful heuristic fallback for
    /// "invent a recipe," unlike item naming).
    func suggestRecipes(for analyses: [ItemAnalysis], fitnessContext: FitnessContext?) async -> [RecipeSuggestion] {
        let (model, _) = PreferredModelRouter.resolve(
            preferCloud: false,
            useCase: .general
        )
        guard PreferredModelRouter.onDeviceModel(for: .general).isAvailable
                || PreferredModelRouter.isPrivateCloudComputeAvailable else {
            return []
        }

        let produceNames = analyses
            .filter { analysis in
                let haystack = (analysis.category + " " + analysis.name).lowercased()
                return Self.produceKeywords.contains { haystack.contains($0) }
            }
            .map(\.name)

        guard produceNames.count >= 2 else { return [] }

        let instructions = Instructions {
            """
            You suggest simple, practical home-cooked recipes based on
            fresh produce someone just brought home. Prioritize the
            specific produce given — don't suggest a recipe that ignores
            most of it. Keep ingredient lists realistic for a typical
            home kitchen (a few common pantry staples like oil, salt, and
            basic spices are fine to assume; specialty ingredients are
            not). Keep steps short and practical, written for a home cook,
            not a professional chef.
            """
        }

        var fitnessLine = ""
        if let fitnessContext {
            fitnessLine = "\nFor context, it's been \(fitnessContext.activityLevelDescription)"
            if let consumed = fitnessContext.approximateDietaryEnergyConsumed {
                fitnessLine += ", and roughly \(consumed) kcal has already been logged as eaten today"
            }
            fitnessLine += " — you can let this inform whether a lighter or heartier suggestion fits better, but don't force a mention of it if it doesn't add anything useful."
        }

        let prompt = Prompt {
            """
            Detected produce: \(produceNames.joined(separator: ", ")).
            \(fitnessLine)

            Suggest 1-3 recipes using this produce.
            """
        }

        do {
            let session = LanguageModelSession(model: model, instructions: instructions)
            session.prewarm()
            let response = try await session.respond(
                to: prompt,
                generating: RecipeSuggestionBatch.self,
                options: GenerationOptions(temperature: 0.7, maximumResponseTokens: 1536)
            )
            return response.content.suggestions
        } catch {
            return []
        }
    }

    /// On-demand variant for "what can I make right now" — unlike
    /// `suggestRecipes`, which only fires opportunistically off freshly
    /// scanned produce, this works from the full current inventory (via
    /// InventoryLookupTool) so it can be triggered any time, e.g. from the
    /// Stash Assistant chat or a dedicated "Recipe Ideas" entry point. Also
    /// prioritizes items expiring soon, since that's the single most useful
    /// thing an on-demand recipe suggestion can help with — using up food
    /// before it goes to waste — rather than just an arbitrary set of
    /// produce.
    func suggestRecipesFromInventory(
        items: [StashItem],
        fitnessContext: FitnessContext?
    ) async -> [RecipeSuggestion] {
        let (model, _) = PreferredModelRouter.resolve(
            preferCloud: false,
            useCase: .general
        )

        guard !items.isEmpty else { return [] }
        guard PreferredModelRouter.onDeviceModel(for: .general).isAvailable
                || PreferredModelRouter.isPrivateCloudComputeAvailable else {
            return []
        }

        let instructions = Instructions {
            """
            You suggest simple, practical home-cooked recipes based on a
            household's current inventory. Use the lookupExistingInventory
            tool to check what food items are actually on hand — don't
            guess. Prioritize perishable items that are expiring soon
            (check daysUntilExpiry) since using those up before they spoil
            is the most useful thing a suggestion can do. Keep ingredient
            lists realistic for a typical home kitchen (a few common
            pantry staples like oil, salt, and basic spices are fine to
            assume even if not itemized; specialty ingredients are not).
            Keep steps short and practical, written for a home cook.
            If the inventory has no usable food items at all, return an
            empty suggestion list rather than inventing recipes for
            ingredients that aren't actually there.
            """
        }

        var fitnessLine = ""
        if let fitnessContext {
            fitnessLine = "\nFor context, it's been \(fitnessContext.activityLevelDescription)"
            if let consumed = fitnessContext.approximateDietaryEnergyConsumed {
                fitnessLine += ", and roughly \(consumed) kcal has already been logged as eaten today"
            }
            fitnessLine += " — let this inform whether a lighter or heartier suggestion fits better, but don't force a mention of it if it doesn't add anything useful."
        }

        let prompt = Prompt {
            """
            Check the current inventory for usable food items, especially
            anything expiring soon, and suggest 1-3 recipes using what's
            actually on hand.
            \(fitnessLine)
            """
        }

        do {
            let session = LanguageModelSession(
                model: model,
                tools: [InventoryLookupTool(items: items)],
                instructions: instructions
            )
            session.prewarm()
            let response = try await session.respond(
                to: prompt,
                generating: RecipeSuggestionBatch.self,
                options: GenerationOptions(
                    temperature: 0.7,
                    maximumResponseTokens: 1536,
                    toolCallingMode: .allowed
                )
            )
            return response.content.suggestions
        } catch {
            return []
        }
    }
}
