//
//  RecipeSuggestion.swift
//  StashKeeper
//
//  Structured Foundation Models output for the "multiple produce items
//  detected → suggest a recipe" feature. Triggered from the Add Item flow
//  when a photo's regions include 2+ fruit/vegetable items, optionally
//  informed by today's HealthKit activity summary (see
//  HealthKitService.TodayFitnessSummary) so the suggestion can lean
//  lighter/heavier depending on how active the day has been so far.
//

import Foundation
import FoundationModels

@Generable
struct RecipeSuggestion: Equatable, Sendable {
    @Guide(description: "A short, appetizing recipe name, e.g. 'Roasted Vegetable Medley' or 'Banana Oat Smoothie'.")
    var title: String

    @Guide(description: "One or two sentences describing the dish and why it fits — mention the detected produce by name. If a fitness context was provided, you can reference it naturally, e.g. 'a lighter option since it's been a low-activity day' — but don't force this if it doesn't fit naturally.")
    var description: String

    @Guide(description: "3 to 8 short ingredient lines, prioritizing the detected produce first, then a few common pantry staples (oil, salt, spices) that most kitchens already have. Do not invent exotic or hard-to-find ingredients.")
    var ingredients: [String]

    @Guide(description: "4 to 8 short, sequential cooking steps in plain language. Assume basic home cooking equipment only.")
    var steps: [String]

    @Guide(description: "Estimated total calories per serving as a plain integer string, e.g. '320'. Empty string if you can't reasonably estimate this.")
    var estimatedCaloriesPerServing: String

    @Guide(description: "Roughly how long this takes to prepare and cook, e.g. '20 minutes', '35 minutes'.")
    var estimatedTime: String
}

/// Wrapper so Foundation Models can return several suggestions in one
/// structured response rather than requiring one call per idea.
@Generable
struct RecipeSuggestionBatch: Equatable, Sendable {
    @Guide(description: "1 to 3 distinct recipe suggestions using the detected produce. Prefer fewer, well-fitted suggestions over padding to 3 with a weak option.")
    var suggestions: [RecipeSuggestion]
}
