//
//  StorageLocation.swift
//  StashKeeper
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
    /// Manual list order for drag-to-reorder on iOS 27 lists. Default 0 so
    /// existing stores lightweight-migrate without a crash.
    var sortIndex: Int = 0

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
        self.sortIndex = Int(Date.now.timeIntervalSince1970)
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
