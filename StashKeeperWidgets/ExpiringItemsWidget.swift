//
//  ExpiringItemsWidget.swift
//  StashKeeperWidgetsExtension
//
//  Home screen / Lock Screen widget surfacing items that are expiring soon,
//  so the user doesn't need to open the app to see what needs attention.
//  Registered in StashKeeperWidgetsBundle.swift, the extension's @main
//  entry point. Reads from the App Group-shared SwiftData store (see
//  SharedModelConfiguration.swift) so it reflects the same live inventory
//  data the main app sees.
//

import WidgetKit
import SwiftUI
import SwiftData

struct ExpiringItemsEntry: TimelineEntry {
    let date: Date
    let items: [ExpiringItemSummary]
}

struct ExpiringItemSummary: Identifiable {
    let id: UUID
    let name: String
    let locationName: String
    let daysUntilExpiry: Int
    let isExpired: Bool
}

struct ExpiringItemsProvider: TimelineProvider {

    func placeholder(in context: Context) -> ExpiringItemsEntry {
        ExpiringItemsEntry(date: .now, items: [
            ExpiringItemSummary(id: UUID(), name: "Milk", locationName: "Fridge", daysUntilExpiry: 2, isExpired: false)
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (ExpiringItemsEntry) -> Void) {
        // Use live inventory for Widget Gallery / previews when available;
        // fall back to the static placeholder only if the shared store is empty
        // or unavailable (e.g. App Group not yet configured).
        let summaries = fetchExpiringSummaries()
        if summaries.isEmpty && context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(ExpiringItemsEntry(date: .now, items: summaries))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ExpiringItemsEntry>) -> Void) {
        let summaries = fetchExpiringSummaries()
        let entry = ExpiringItemsEntry(date: .now, items: summaries)
        // Refresh every couple hours; also re-synced whenever the app writes data.
        let nextRefresh = Calendar.current.date(byAdding: .hour, value: 2, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func fetchExpiringSummaries() -> [ExpiringItemSummary] {
        let container = SharedModelConfiguration.makeContainer()

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<StashItem>()
        guard let items = try? context.fetch(descriptor) else { return [] }

        return ExpiryEngine.shared.attentionNeeded(items: items).prefix(5).map { item in
            ExpiringItemSummary(
                id: item.id,
                name: item.name,
                locationName: item.location?.name ?? "Unsorted",
                daysUntilExpiry: item.daysUntilExpiry ?? 0,
                isExpired: item.expiryStatus == .expired
            )
        }
    }
}

struct ExpiringItemsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ExpiringItemsEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
                Text("Expiring Soon")
                    .font(.headline)
            }

            if entry.items.isEmpty {
                Text("All clear")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleItems) { item in
                    HStack {
                        Text(item.name)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text(item.isExpired ? "Expired" : "\(item.daysUntilExpiry)d")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(item.isExpired ? .red : .orange)
                    }
                }
            }
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var visibleItems: [ExpiringItemSummary] {
        switch family {
        case .systemSmall: return Array(entry.items.prefix(2))
        case .systemMedium: return Array(entry.items.prefix(4))
        default: return entry.items
        }
    }
}

struct ExpiringItemsWidget: Widget {
    let kind = "ExpiringItemsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ExpiringItemsProvider()) { entry in
            ExpiringItemsWidgetView(entry: entry)
        }
        .configurationDisplayName("Expiring Items")
        .description("Shows items in your stash that are expiring soon.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
