//
//  StorageLocation.swift
//  StashKeeper
//  ⚠️ SYNCED COPY: this file is duplicated from the main app target
//  (StashKeeper/Models or StashKeeper/Services) because Xcode's
//  file-system-synchronized-group feature ties a folder to a single
//  target's root, so it can't be natively shared between the app and
//  this widget extension without re-parenting the whole app source tree.
//  If you edit the original, copy your changes here too (or, cleaner:
//  move both into a shared Swift Package/framework target later so
//  there's only one copy for real).
//
//
//  A place where the user keeps things ("Garage Shelf B", "Kitchen Fridge",
//  "Bedroom Closet"). Locations can nest (e.g. "Garage" > "Top Shelf").
//

import Foundation
import SwiftData

@Model
final class StorageLocation {

    var id: UUID
    var name: String
    var iconSystemName: String
    var createdAt: Date

    /// Optional parent for nested locations, e.g. "Top Shelf" inside "Garage".
    var parent: StorageLocation?

    @Relationship(deleteRule: .nullify, inverse: \StorageLocation.parent)
    var children: [StorageLocation]

    @Relationship(deleteRule: .nullify, inverse: \StashItem.location)
    var items: [StashItem]

    init(
        name: String,
        iconSystemName: String = "archivebox",
        parent: StorageLocation? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.iconSystemName = iconSystemName
        self.createdAt = .now
        self.parent = parent
        self.children = []
        self.items = []
    }

    /// Full breadcrumb path, e.g. "Garage > Top Shelf".
    var fullPath: String {
        if let parent {
            return "\(parent.fullPath) > \(name)"
        }
        return name
    }
}
