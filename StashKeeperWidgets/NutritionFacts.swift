//
//  NutritionFacts.swift
//  StashKeeperWidgets
//
//  Lightweight stand-in so StashItem.swift compiles in the widget
//  without pulling Foundation Models / Vision types from the app target.
//

import Foundation

nonisolated struct NutritionFacts: Equatable, Sendable {
    var servingSize: String
    var calories: Int
    var proteinGrams: Double
    var carbsGrams: Double
    var sugarGrams: Double
    var fatGrams: Double
    var fiberGrams: Double
    var sodiumMilligrams: Double
}
