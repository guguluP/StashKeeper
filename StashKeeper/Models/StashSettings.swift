//
//  StashSettings.swift
//  StashKeeper
//

import Foundation

enum StashSettings {
    nonisolated static let warningWindowDaysKey = "stashkeeper.warningWindowDays"
    nonisolated static let defaultWarningWindowDays = 5
    nonisolated static let allowedWarningWindowDays = [3, 5, 7, 14]

    nonisolated static var warningWindowDays: Int {
        get {
            let stored = defaults.integer(forKey: warningWindowDaysKey)
            return clamp(stored == 0 ? defaultWarningWindowDays : stored)
        }
        set {
            defaults.set(clamp(newValue), forKey: warningWindowDaysKey)
        }
    }

    nonisolated static var currentWarningWindowDays: Int { warningWindowDays }

    nonisolated static let householdNameKey = "stashkeeper.householdName"
    nonisolated static let shareGroceriesKey = "stashkeeper.shareGroceriesWithReminders"

    /// When true, the buy list is copied into a Reminders list named StashKeeper Groceries.
    nonisolated static var shareGroceriesWithReminders: Bool {
        get { defaults.bool(forKey: shareGroceriesKey) }
        set { defaults.set(newValue, forKey: shareGroceriesKey) }
    }

    /// Name recorded on quantity changes so another device can see who used an item.
    nonisolated static var householdName: String {
        get {
            let stored = defaults.string(forKey: householdNameKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? "Me" : stored
        }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: householdNameKey)
        }
    }

    nonisolated static func clamp(_ value: Int) -> Int {
        allowedWarningWindowDays.contains(value) ? value : defaultWarningWindowDays
    }

    nonisolated private static var defaults: UserDefaults {
        if SharedModelConfiguration.useAppGroupContainer,
           let suite = UserDefaults(suiteName: SharedModelConfiguration.appGroupIdentifier) {
            return suite
        }
        return .standard
    }
}
