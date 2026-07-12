//
//  Milestone.swift
//  StashKeeper
//
//  Fitness-app-style achievements: per-category item-count milestones
//  (bronze/silver/gold/platinum tiers) plus a daily-use streak, similar to
//  Apple Fitness's activity rings and awards. MilestoneEngine (below)
//  computes progress live from existing StashItem data rather than storing
//  duplicated counts, so it can never drift out of sync; StreakRecord is
//  the one small piece of state that genuinely needs persisting (you can't
//  derive "did the user open the app yesterday" from item data alone).
//

import Foundation
import SwiftData
import SwiftUI

enum MilestoneTier: Int, CaseIterable, Comparable {
    case bronze = 1
    case silver = 2
    case gold = 3
    case platinum = 4

    static func < (lhs: MilestoneTier, rhs: MilestoneTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .bronze: return "Bronze"
        case .silver: return "Silver"
        case .gold: return "Gold"
        case .platinum: return "Platinum"
        }
    }

    var tint: Color {
        switch self {
        case .bronze: return Color(red: 0.80, green: 0.50, blue: 0.20)
        case .silver: return Color(red: 0.75, green: 0.76, blue: 0.78)
        case .gold: return Color(red: 1.0, green: 0.84, blue: 0.0)
        case .platinum: return Color(red: 0.60, green: 0.85, blue: 0.95)
        }
    }

    /// Item count threshold to reach this tier for a given category.
    var threshold: Int {
        switch self {
        case .bronze: return 5
        case .silver: return 15
        case .gold: return 40
        case .platinum: return 100
        }
    }
}

/// A single milestone achievement for one category at one tier — computed,
/// not persisted (see MilestoneEngine).
struct CategoryMilestone: Identifiable {
    var id: String { "\(category)-\(tier.rawValue)" }
    let category: String
    let tier: MilestoneTier
    let currentCount: Int
    let isUnlocked: Bool
    let progress: Double // 0...1 toward this tier's threshold

    var systemImage: String {
        switch category {
        case "Pantry & Food": return "cart.fill"
        case "Fresh Produce": return "carrot.fill"
        case "Dairy": return "drop.fill"
        case "Beverages": return "waterbottle.fill"
        case "Medicine & Health": return "cross.case.fill"
        case "Cosmetics & Toiletries": return "sparkles"
        case "Electronics": return "bolt.fill"
        case "Watches & Jewelry": return "clock.fill"
        case "Documents": return "doc.text.fill"
        case "Clothing": return "tshirt.fill"
        case "Tools & Hardware": return "wrench.and.screwdriver.fill"
        case "Kitchenware": return "fork.knife"
        case "Cleaning Supplies": return "bubbles.and.sparkles.fill"
        case "Stationery": return "pencil"
        case "Toys & Games": return "gamecontroller.fill"
        case "Sports & Outdoors": return "figure.hiking"
        case "Automotive": return "car.fill"
        default: return "shippingbox.fill"
        }
    }
}

/// Persisted daily-use streak state — the one piece of milestone data that
/// genuinely can't be derived from StashItem records after the fact.
@Model
final class StreakRecord {
    var id: UUID
    /// The most recent calendar day (start-of-day) the app was opened/used.
    var lastActiveDay: Date
    /// Consecutive days of use up to and including lastActiveDay.
    var currentStreak: Int
    /// Longest streak ever achieved, kept even if the current streak resets.
    var longestStreak: Int

    init() {
        self.id = UUID()
        self.lastActiveDay = Calendar.current.startOfDay(for: .now)
        self.currentStreak = 1
        self.longestStreak = 1
    }

    /// Call once per app session/launch. Advances, maintains, or resets the
    /// streak depending on how many days have passed since last use.
    func recordActivityToday() {
        let today = Calendar.current.startOfDay(for: .now)
        guard today != lastActiveDay else { return } // already counted today

        let daysSinceLastActive = Calendar.current.dateComponents(
            [.day], from: lastActiveDay, to: today
        ).day ?? 0

        if daysSinceLastActive == 1 {
            currentStreak += 1
        } else if daysSinceLastActive > 1 {
            currentStreak = 1
        }
        // daysSinceLastActive == 0 handled by the early guard above.

        longestStreak = max(longestStreak, currentStreak)
        lastActiveDay = today
    }
}
