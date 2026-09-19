//
//  StashKeeperControls.swift
//  StashKeeperWidgetsExtension
//
//  Control Center / Lock Screen / Action Button controls (iOS 18+ / 27).
//

#if os(iOS)
import WidgetKit
import SwiftUI
import AppIntents

struct AddItemControl: ControlWidget {
    static let kind = "com.piyushpatnaik.StashKeeper.addItem"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenAddItemIntent()) {
                Label("Add Item", systemImage: "plus.circle.fill")
            }
        }
        .displayName("Add to Stash")
        .description("Photograph and catalog a new item.")
    }
}

struct ExpiringControl: ControlWidget {
    static let kind = "com.piyushpatnaik.StashKeeper.expiring"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenExpiringListIntent()) {
                Label("Expiring", systemImage: "clock.badge.exclamationmark")
            }
        }
        .displayName("What's Expiring")
        .description("Jump to items that need attention.")
    }
}
#endif
