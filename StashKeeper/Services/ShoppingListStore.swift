//
//  ShoppingListStore.swift
//  StashKeeper
//
//  Remembers which expiring items the person has already checked off.
//  The mark is tied to the expiry date, so a new date puts the item back.
//

import Foundation

nonisolated enum ShoppingListStore {
    private static let key = "StashKeeper.shoppingHandled"

    static func isHandled(id: UUID, expiry: Date?) -> Bool {
        let stamp = expiry?.timeIntervalSince1970 ?? 0
        return load()[id.uuidString] == stamp
    }

    static func setHandled(id: UUID, expiry: Date?, handled: Bool) {
        var map = load()
        if handled {
            map[id.uuidString] = expiry?.timeIntervalSince1970 ?? 0
        } else {
            map.removeValue(forKey: id.uuidString)
        }
        defaults.set(map, forKey: key)
    }

    private static var defaults: UserDefaults {
        if SharedModelConfiguration.useAppGroupContainer,
           let suite = UserDefaults(suiteName: SharedModelConfiguration.appGroupIdentifier) {
            return suite
        }
        return .standard
    }

    private static func load() -> [String: Double] {
        if let map = defaults.dictionary(forKey: key) as? [String: Double] {
            return map
        }
        let legacy = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        if !legacy.isEmpty, defaults !== UserDefaults.standard {
            defaults.set(legacy, forKey: key)
        }
        return legacy
    }
}
