//
//  HealthKitService.swift
//  StashKeeper
//
//  Writes nutrition data to Apple Health only when the user explicitly
//  taps "Log nutrition to Health" on an item's detail screen. Auto-write
//  on save was removed: HealthKit models consumption, not pantry stock,
//  and silent writes inflated calorie/macro totals. Metadata still notes
//  that the sample is app-originated so entries stay auditable in Health.
//
//  iOS only — HealthKit has no macOS app support (Mac Catalyst apps can
//  use it, but a native macOS SwiftUI target cannot), so every entry
//  point here is guarded and this whole file compiles out on macOS.
//

import Foundation
#if os(iOS)
import HealthKit

enum HealthKitError: Error, LocalizedError {
    case notAvailable
    case authorizationDenied

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Health data isn't available on this device."
        case .authorizationDenied:
            return "StashKeeper doesn't have permission to write to Health. You can enable this in Settings > Health > Data Access & Devices."
        }
    }
}

@MainActor
final class HealthKitService {

    static let shared = HealthKitService()

    private let store = HKHealthStore()

    /// The nutrition quantity types this app can write. Kept as a set so
    /// authorization requests and per-sample writes share one source of truth.
    private var writableTypes: Set<HKQuantityType> {
        var types: Set<HKQuantityType> = []
        for identifier in Self.nutrientIdentifiers.values {
            if let type = HKQuantityType.quantityType(forIdentifier: identifier) {
                types.insert(type)
            }
        }
        return types
    }

    /// Read-only types used for recipe suggestions (see
    /// `RecipeSuggestionService`) — kept intentionally small: just enough
    /// signal to make a suggestion feel personalized (today's activity
    /// level, whether the user is already close to a calorie goal) without
    /// requesting broad Health access the feature doesn't need.
    private var readableTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        let identifiers: [HKQuantityTypeIdentifier] = [
            .activeEnergyBurned, .stepCount, .dietaryEnergyConsumed
        ]
        for identifier in identifiers {
            if let type = HKQuantityType.quantityType(forIdentifier: identifier) {
                types.insert(type)
            }
        }
        return types
    }

    private static let nutrientIdentifiers: [WritableNutrient: HKQuantityTypeIdentifier] = [
        .energy: .dietaryEnergyConsumed,
        .protein: .dietaryProtein,
        .carbs: .dietaryCarbohydrates,
        .sugar: .dietarySugar,
        .fat: .dietaryFatTotal,
        .fiber: .dietaryFiber,
        .sodium: .dietarySodium
    ]

    private enum WritableNutrient {
        case energy, protein, carbs, sugar, fat, fiber, sodium
    }

    var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// Requests write permission for nutrition logging AND read permission
    /// for the small set of fitness/dietary signals recipe suggestions use.
    /// Call once, e.g. from Settings or the first time a food item is saved.
    func requestAuthorizationIfNeeded() async throws {
        guard isHealthDataAvailable else { throw HealthKitError.notAvailable }
        try await store.requestAuthorization(toShare: writableTypes, read: readableTypes)
    }

    /// Whether the app currently has write authorization for at least the
    /// core nutrient types. HealthKit doesn't expose granular per-type
    /// "denied" status for privacy reasons — `sharingAuthorized` reflects
    /// whether the user has responded to the prompt and granted access.
    func hasWriteAuthorization() -> Bool {
        guard let energyType = HKQuantityType.quantityType(forIdentifier: .dietaryEnergyConsumed) else {
            return false
        }
        return store.authorizationStatus(for: energyType) == .sharingAuthorized
    }

    /// Logs an item's nutrition facts to Apple Health as of now. Returns
    /// true only if samples were actually written, so callers can
    /// accurately record sync status rather than assuming success.
    ///
    /// Design note: this logs the moment the item is *added to the stash*,
    /// not a claim that the user has eaten it — HealthKit has no "food I
    /// own" concept, only "food I consumed," so this is a reasonable but
    /// imperfect mapping. The sample's metadata is tagged with the source
    /// item name and "StashKeeper (logged at storage time, not consumption)"
    /// so it's clear in the Health app what generated the entry, and a user
    /// who wants stricter consumption tracking can delete/adjust entries
    /// there directly — Health is the source of truth for their health data,
    /// not this app.
    @discardableResult
    func logNutrition(for item: StashItem) async -> Bool {
        guard isHealthDataAvailable, hasWriteAuthorization() else { return false }
        guard item.hasNutrition else { return false }

        var samples: [HKQuantitySample] = []
        let now = Date.now
        let metadata: [String: Any] = [
            HKMetadataKeyFoodType: item.name,
            "StashKeeperSourceItemID": item.id.uuidString,
            "StashKeeperNote": "Logged at storage time, not confirmed consumption"
        ]

        func makeSample(_ nutrient: WritableNutrient, value: Double?, unit: HKUnit) -> HKQuantitySample? {
            guard let value, value >= 0,
                  let identifier = Self.nutrientIdentifiers[nutrient],
                  let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
            let quantity = HKQuantity(unit: unit, doubleValue: value)
            return HKQuantitySample(type: type, quantity: quantity, start: now, end: now, metadata: metadata)
        }

        if let calories = item.nutritionCalories {
            if let sample = makeSample(.energy, value: Double(calories), unit: .kilocalorie()) {
                samples.append(sample)
            }
        }
        if let sample = makeSample(.protein, value: item.nutritionProteinGrams, unit: .gram()) {
            samples.append(sample)
        }
        if let sample = makeSample(.carbs, value: item.nutritionCarbsGrams, unit: .gram()) {
            samples.append(sample)
        }
        if let sample = makeSample(.sugar, value: item.nutritionSugarGrams, unit: .gram()) {
            samples.append(sample)
        }
        if let sample = makeSample(.fat, value: item.nutritionFatGrams, unit: .gram()) {
            samples.append(sample)
        }
        if let sample = makeSample(.fiber, value: item.nutritionFiberGrams, unit: .gram()) {
            samples.append(sample)
        }
        if let sample = makeSample(.sodium, value: item.nutritionSodiumMilligrams, unit: .gramUnit(with: .milli)) {
            samples.append(sample)
        }

        guard !samples.isEmpty else { return false }
        do {
            try await store.save(samples)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Reading fitness/dietary context for recipe suggestions

    /// A deliberately small, rounded summary of today's activity, fetched
    /// from HealthKit. Callers (see AddItemFlowView) convert this into
    /// `RecipeSuggestionService.FitnessContext` before passing it to AFM —
    /// kept as a separate type from that one so this file has no reverse
    /// dependency on the recipe-suggestion feature, and rounding here
    /// reduces how much precise personal health data exists in memory at
    /// all, independent of how it's eventually used.
    struct TodayFitnessSummary: Sendable {
        /// Rounded to the nearest 500 steps.
        let approximateSteps: Int
        /// Rounded to the nearest 50 kcal.
        let approximateActiveEnergyBurned: Int
        /// Rounded to the nearest 50 kcal. Nil if nothing logged yet today
        /// (either genuinely zero, or the user doesn't log food in Health).
        let approximateDietaryEnergyConsumed: Int?
    }

    /// Fetches today's step count, active energy, and dietary energy from
    /// Health. Returns nil (never throws) if unavailable, unauthorized, or
    /// nothing has been recorded yet today — recipe suggestions work fine
    /// without this, just without the personalization it adds, so callers
    /// treat nil as "proceed without fitness context" rather than an error.
    func fetchTodayFitnessSummary() async -> TodayFitnessSummary? {
        guard isHealthDataAvailable else { return nil }

        async let steps = sumQuantityToday(.stepCount, unit: .count())
        async let activeEnergy = sumQuantityToday(.activeEnergyBurned, unit: .kilocalorie())
        async let dietaryEnergy = sumQuantityToday(.dietaryEnergyConsumed, unit: .kilocalorie())

        let (stepsValue, activeEnergyValue, dietaryEnergyValue) = await (steps, activeEnergy, dietaryEnergy)
        guard stepsValue != nil || activeEnergyValue != nil else { return nil }

        return TodayFitnessSummary(
            approximateSteps: roundToNearest(Int(stepsValue ?? 0), 500),
            approximateActiveEnergyBurned: roundToNearest(Int(activeEnergyValue ?? 0), 50),
            approximateDietaryEnergyConsumed: dietaryEnergyValue.map { roundToNearest(Int($0), 50) }
        )
    }

    private func sumQuantityToday(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        guard store.authorizationStatus(for: type) == .sharingAuthorized else { return nil }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: .now)
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: .now, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, statistics, _ in
                continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    private func roundToNearest(_ value: Int, _ multiple: Int) -> Int {
        guard multiple > 0 else { return value }
        return Int((Double(value) / Double(multiple)).rounded()) * multiple
    }
}
#endif
