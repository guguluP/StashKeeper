//
//  PurchaseNeed.swift
//  StashKeeper
//
//  Something to buy that is not already a shortfall of a stocked item.
//

import Foundation
import SwiftData

@Model
final class PurchaseNeed {
    var id: UUID = UUID()
    var name: String = ""
    var quantity: Int = 1
    var createdAt: Date = Date.now
    var isChecked: Bool = false

    init(name: String, quantity: Int = 1) {
        self.id = UUID()
        self.name = name
        self.quantity = max(1, quantity)
        self.createdAt = .now
        self.isChecked = false
    }
}
