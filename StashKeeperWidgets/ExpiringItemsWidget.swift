//
//  ExpiringItemsWidget.swift
//  StashKeeperWidgetsExtension
//

import WidgetKit
import SwiftUI
import SwiftData
import AppIntents

struct ExpiringItemsEntry: TimelineEntry {
    let date: Date
    let items: [ExpiringItemSummary]
    let insight: String
}

struct ExpiringItemSummary: Identifiable {
    let id: UUID
    let name: String
    let locationName: String
    let daysUntilExpiry: Int
    let isExpired: Bool
    let quantity: Int
}

enum ExpiringItemsLoader {
    static func fetch() -> (items: [ExpiringItemSummary], insight: String) {
        let container = SharedModelConfiguration.makeContainer()
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<StashItem>()
        guard let items = try? context.fetch(descriptor) else {
            return ([], "Add items in StashKeeper to see expiry here.")
        }
        let attention = StashItem.needingAttention(in: items)
        let summaries = attention.prefix(5).map { item in
            ExpiringItemSummary(
                id: item.id,
                name: item.name,
                locationName: item.location?.name ?? "Unsorted",
                daysUntilExpiry: item.daysUntilExpiry ?? 0,
                isExpired: item.expiryStatus == .expired,
                quantity: item.quantity
            )
        }
        let expired = attention.filter { $0.expiryStatus == .expired }.count
        let insight: String
        if attention.isEmpty {
            insight = items.isEmpty ? "Your stash is empty — photograph something to start." : "All clear. Nothing expiring in the warning window."
        } else if expired > 0 {
            insight = "\(expired) expired · \(attention.count) need attention"
        } else {
            insight = "\(attention.count) item\(attention.count == 1 ? "" : "s") expiring soon"
        }
        return (Array(summaries), insight)
    }
}

struct ExpiringItemsProvider: TimelineProvider {
    func placeholder(in context: Context) -> ExpiringItemsEntry {
        ExpiringItemsEntry(
            date: .now,
            items: [ExpiringItemSummary(id: UUID(), name: "Milk", locationName: "Fridge", daysUntilExpiry: 2, isExpired: false, quantity: 1)],
            insight: "2 items expiring soon"
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ExpiringItemsEntry) -> Void) {
        let loaded = ExpiringItemsLoader.fetch()
        if loaded.items.isEmpty && context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(ExpiringItemsEntry(date: .now, items: loaded.items, insight: loaded.insight))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ExpiringItemsEntry>) -> Void) {
        let loaded = ExpiringItemsLoader.fetch()
        let entry = ExpiringItemsEntry(date: .now, items: loaded.items, insight: loaded.insight)
        let nextRefresh = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct ExpiringItemsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ExpiringItemsEntry

    var body: some View {
        switch family {
        case .systemSmall:
            smallLayout
        #if os(iOS)
        case .accessoryCircular:
            Gauge(value: Double(min(entry.items.count, 5)), in: 0...5) {
                Image(systemName: "clock.badge.exclamationmark")
            } currentValueLabel: {
                Text("\(entry.items.count)")
            }
            .gaugeStyle(.accessoryCircular)
            .tint(.orange)
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("Expiring")
                    .font(.headline)
                    .widgetAccentable()
                Text(entry.insight)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .accessoryInline:
            Text(entry.insight)
        #endif
        default:
            mediumLargeLayout
        }
    }

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Expiring", systemImage: "clock.badge.exclamationmark")
                .font(.headline)
                .foregroundStyle(.orange)
                .widgetAccentable()
            if let first = entry.items.first {
                Text(first.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(first.isExpired ? "Expired" : first.daysUntilExpiry == 0 ? "Today" : "\(first.daysUntilExpiry)d · \(first.locationName)")
                    .font(.caption)
                    .foregroundStyle(first.isExpired ? .red : .secondary)
                Spacer()
                Button(intent: ConsumeStashItemIntent(itemID: first.id)) {
                    Label("Used 1", systemImage: "minus.circle.fill")
                        .font(.caption.weight(.semibold))
                }
                .tint(.orange)
            } else {
                Spacer()
                Text(entry.insight)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var mediumLargeLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Needs attention", systemImage: "clock.badge.exclamationmark")
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .widgetAccentable()
                Spacer()
                Text("\(entry.items.count)")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.2), in: Capsule())
            }

            Text(entry.insight)
                .font(.caption)
                .foregroundStyle(.secondary)

            if entry.items.isEmpty {
                Spacer()
                Text("All clear")
                    .font(.title3.weight(.semibold))
            } else {
                ForEach(visibleItems) { item in
                    HStack(spacing: 8) {
                        Link(destination: URL(string: "stashkeeper://item/\(item.id.uuidString)")!) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                Text(item.locationName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(item.isExpired ? "Expired" : item.daysUntilExpiry == 0 ? "Today" : "\(item.daysUntilExpiry)d")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(item.isExpired ? .red : .orange)
                            .frame(width: 52, alignment: .trailing)
                        Button(intent: ConsumeStashItemIntent(itemID: item.id)) {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .tint(.orange)
                        Button(intent: SnoozeStashItemIntent(itemID: item.id)) {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .buttonStyle(.plain)
                        .tint(.blue)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var visibleItems: [ExpiringItemSummary] {
        switch family {
        case .systemSmall: return Array(entry.items.prefix(1))
        case .systemMedium: return Array(entry.items.prefix(3))
        case .systemLarge: return Array(entry.items.prefix(5))
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
        .description("See what's expiring and mark something used without opening the app.")
        #if os(iOS)
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline
        ])
        #else
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        #endif
    }
}
