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
