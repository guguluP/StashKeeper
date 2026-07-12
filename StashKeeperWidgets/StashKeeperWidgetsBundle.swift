//
//  StashKeeperWidgetsBundle.swift
//  StashKeeperWidgetsExtension
//
//  The extension's single entry point — WidgetKit requires exactly one
//  `@main WidgetBundle` per extension, listing every Widget (including
//  ActivityConfiguration-based Live Activities) the extension provides.
//

import WidgetKit
import SwiftUI

@main
struct StashKeeperWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ExpiringItemsWidget()
        StashScanLiveActivity()
    }
}

/// Registers the scan-progress Live Activity content with WidgetKit. Kept
/// as its own `Widget` conformer (rather than folding this directly into
/// the bundle) so it reads the same way Xcode's own Live Activity template
/// scaffolds it, which is the shape most StashKeeper contributors will
/// have seen before if they've built a Live Activity previously.
struct StashScanLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StashScanActivityAttributes.self) { context in
            StashScanActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isComplete ? "checkmark.circle.fill" : "shippingbox.fill")
                        .foregroundStyle(.blue)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int(context.state.fractionComplete * 100))%")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.progressMessage)
                            .font(.subheadline.weight(.medium))
                        ProgressView(value: context.state.fractionComplete)
                            .tint(.blue)
                    }
                }
            } compactLeading: {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.blue)
            } compactTrailing: {
                Text("\(Int(context.state.fractionComplete * 100))%")
                    .font(.caption2.weight(.semibold))
            } minimal: {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.blue)
            }
        }
    }
}
