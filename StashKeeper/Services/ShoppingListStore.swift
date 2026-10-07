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
        UserDefaults.standard.set(map, forKey: key)
    }

    private static func load() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    }
}
