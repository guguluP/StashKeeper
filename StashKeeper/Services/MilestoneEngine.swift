//
//  MilestoneEngine.swift
//  StashKeeper
//
//  Computes per-category milestone progress on the fly from the user's
//  current StashItem collection — no duplicated counters to keep in sync.
//  Also surfaces newly-unlocked milestones since the last check, so the UI
//  can show a celebratory animation exactly once per unlock.
//

import Foundation
import SwiftData

@MainActor
final class MilestoneEngine {

    static let shared = MilestoneEngine()

    /// Category names the user has previously been shown an "unlocked"
    /// celebration for, at a given tier — kept in memory for the session
    /// via UserDefaults so we don't re-celebrate the same milestone every
    /// time the dashboard appears.
    private let defaults = UserDefaults.standard
    private let celebratedKey = "StashKeeper.celebratedMilestoneIDs"

    /// Returns every category milestone (all tiers, all categories present
    /// in the user's data) with live progress computed from `items`.
    func allMilestones(items: [StashItem]) -> [CategoryMilestone] {
        let counts = Dictionary(grouping: items, by: \.category).mapValues(\.count)

        var results: [CategoryMilestone] = []
        for (category, count) in counts {
            for tier in MilestoneTier.allCases {
                let unlocked = count >= tier.threshold
                let progress = min(1.0, Double(count) / Double(tier.threshold))
                results.append(CategoryMilestone(
                    category: category,
                    tier: tier,
                    currentCount: count,
                    isUnlocked: unlocked,
                    progress: progress
                ))
            }
        }
        return results.sorted { lhs, rhs in
            if lhs.category != rhs.category { return lhs.category < rhs.category }
            return lhs.tier < rhs.tier
        }
    }

    /// The single next milestone closest to being unlocked for each
    /// category — what the dashboard shows as "almost there" progress.
    func nextMilestones(items: [StashItem]) -> [CategoryMilestone] {
        let all = allMilestones(items: items)
        let byCategory = Dictionary(grouping: all, by: \.category)
        return byCategory.compactMap { _, milestones in
            milestones.first { !$0.isUnlocked } ?? milestones.last
        }.sorted { $0.category < $1.category }
    }

    /// Milestones that just became unlocked and haven't been celebrated yet.
    /// Call this once when the dashboard appears; it marks returned
    /// milestones as celebrated so they won't be returned again.
    func newlyUnlockedMilestones(items: [StashItem]) -> [CategoryMilestone] {
        let unlocked = allMilestones(items: items).filter(\.isUnlocked)
        var celebrated = Set(defaults.stringArray(forKey: celebratedKey) ?? [])

        let fresh = unlocked.filter { !celebrated.contains($0.id) }
        for milestone in fresh {
            celebrated.insert(milestone.id)
        }
        if !fresh.isEmpty {
            defaults.set(Array(celebrated), forKey: celebratedKey)
        }
        return fresh
    }

    // MARK: - Streak

    /// Fetches or creates the single StreakRecord and records today's activity.
    @discardableResult
    func recordDailyActivity(context: ModelContext) -> StreakRecord {
        let descriptor = FetchDescriptor<StreakRecord>()
        let record = (try? context.fetch(descriptor))?.first ?? {
            let new = StreakRecord()
            context.insert(new)
            return new
        }()
        record.recordActivityToday()
        try? context.save()
        return record
    }
}
