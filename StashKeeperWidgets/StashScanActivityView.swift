//
//  StashScanActivityView.swift
//  StashKeeper
//
//  The actual Live Activity UI — Lock Screen banner + all three Dynamic
//  Island presentations (compact, minimal, expanded). NOTE: per the setup
//  comment in StashScanActivityAttributes.swift, this file's real home is
//  the Widget Extension target's widget bundle (registered via a
//  `Widget` conforming to `ActivityConfiguration`); it lives here for now
//  since that target doesn't exist yet in this project. Once the target
//  is created, move this file's target membership (or copy it) there and
//  wrap it in an ActivityConfiguration, e.g.:
//
//    struct StashScanLiveActivity: Widget {
//        var body: some WidgetConfiguration {
//            ActivityConfiguration(for: StashScanActivityAttributes.self) { context in
//                StashScanActivityView(context: context)
//            } dynamicIsland: { context in
//                DynamicIsland {
//                    DynamicIslandExpandedRegion(.center) {
//                        StashScanActivityView(context: context)
//                    }
//                } compactLeading: {
//                    Image(systemName: "shippingbox.fill")
//                } compactTrailing: {
//                    Text("\(Int(context.state.fractionComplete * 100))%")
//                } minimal: {
//                    Image(systemName: "shippingbox.fill")
//                }
//            }
//        }
//    }
//

#if os(iOS)
import SwiftUI
import ActivityKit
import WidgetKit

struct StashScanActivityView: View {
    let context: ActivityViewContext<StashScanActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(.blue.opacity(0.2), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: context.state.fractionComplete)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: context.state.isComplete ? "checkmark" : "shippingbox.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text("StashKeeper")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(context.state.progressMessage)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if context.state.itemsFoundSoFar > 0 {
                    Text("\(context.state.itemsFoundSoFar) item\(context.state.itemsFoundSoFar == 1 ? "" : "s") found so far")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(16)
        .activityBackgroundTint(Color(white: 0.1))
        .activitySystemActionForegroundColor(.white)
    }
}
#endif
