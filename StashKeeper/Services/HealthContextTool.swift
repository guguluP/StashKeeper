//
//  HealthContextTool.swift
//  StashKeeper
//
//  A Foundation Models Tool that lets the model pull today's HealthKit
//  activity/dietary summary mid-reasoning — the missing link between
//  RecipeSuggestionService (which already accepts a FitnessContext, but
//  only ever gets one passed in opportunistically at scan time) and a
//  general-purpose assistant that should be able to answer "what should I
//  eat after this workout" on demand, in either direction, without the
//  call site having to pre-fetch HealthKit data itself.
//
//  iOS only, same as HealthKitService. On macOS this tool still exists
//  (so shared code referencing it compiles) but always reports health data
//  as unavailable, since HealthKit has no native macOS SwiftUI support.
//
//  Swift 6 note: unlike InventoryLookupTool, this tool doesn't need to
//  snapshot anything at construction time — HealthKitService.shared is
//  already `@MainActor` and this tool's `call` runs on the main actor too
//  (Foundation Models Tool.call is async but not required to leave the
//  calling actor), so it can query HealthKit fresh on every invocation
//  rather than working from a stale snapshot. Fresh data matters more here
//  than for inventory, since "today's steps" changes throughout the day.
//

import Foundation
import FoundationModels

nonisolated private struct HealthContextResult: Codable, Sendable {
    let available: Bool
    let approximateSteps: Int?
    let approximateActiveEnergyBurnedKcal: Int?
    let approximateDietaryEnergyConsumedKcal: Int?
    let note: String
}

/// Foundation Models Tool conformance — the model decides when to call
/// this based on the description below (e.g. the user mentions a workout,
/// asks for a recipe, or asks something activity-related).
struct HealthContextTool: Tool {
    let name = "getTodayHealthContext"
    let description = """
        Fetches a rounded summary of the user's activity today from Apple
        Health: approximate step count, active energy burned, and dietary
        energy already logged as eaten (if the user tracks food in
        Health). Use this when a recipe, snack, or food recommendation
        would benefit from knowing how active the user has been today, or
        when the user directly asks something like 'what should I eat
        after my workout' or 'how many calories have I eaten today'.
        Values are intentionally rounded for privacy and may be
        unavailable if the user hasn't granted Health access — always
        handle an unavailable result gracefully rather than assuming data
        exists.
        """

    @Generable
    struct Arguments {
        @Guide(description: "Always pass true. Present for schema compatibility only — this tool takes no real parameters.")
        var confirm: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        #if os(iOS)
        guard let summary = await HealthKitService.shared.fetchTodayFitnessSummary() else {
            let result = HealthContextResult(
                available: false,
                approximateSteps: nil,
                approximateActiveEnergyBurnedKcal: nil,
                approximateDietaryEnergyConsumedKcal: nil,
                note: "Health data isn't available — either the user hasn't granted access, or nothing has been recorded yet today. Don't assume a specific activity level; ask the user directly if it matters for your answer."
            )
            return Self.encode(result)
        }

        let result = HealthContextResult(
            available: true,
            approximateSteps: summary.approximateSteps,
            approximateActiveEnergyBurnedKcal: summary.approximateActiveEnergyBurned,
            approximateDietaryEnergyConsumedKcal: summary.approximateDietaryEnergyConsumed,
            note: "Figures are rounded and reflect today only, from midnight to now."
        )
        return Self.encode(result)
        #else
        let result = HealthContextResult(
            available: false,
            approximateSteps: nil,
            approximateActiveEnergyBurnedKcal: nil,
            approximateDietaryEnergyConsumedKcal: nil,
            note: "Health data isn't available on this platform."
        )
        return Self.encode(result)
        #endif
    }

    private static func encode(_ result: HealthContextResult) -> String {
        let encoder = JSONEncoder()
        let data = (try? encoder.encode(result)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "Health data unavailable."
    }
}
