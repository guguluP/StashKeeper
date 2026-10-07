//
//  ShoppingListView.swift
//  StashKeeper
//
//  The items that need using or replacing, as a list you can check off.
//

import SwiftUI
import SwiftData

struct ShoppingListView: View {
    @Query private var items: [StashItem]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayMetrics) private var metrics
    @State private var revision = 0

    private var rows: [StashItem] {
        _ = revision
        return ExpiryEngine.shared.attentionNeeded(items: items)
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    "Nothing to use up",
                    systemImage: "checklist",
                    description: Text("Items that are expiring or expired show up here so you can use them or replace them.")
                )
            } else {
                List {
                    Section {
                        Text("Checked items stay off this list until their expiry date changes.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Section("Use or replace") {
                        ForEach(rows) { item in
                            row(item)
                        }
                    }
                }
            }
        }
        .navigationTitle("Shopping")
        .adaptivePage()
    }

    private func row(_ item: StashItem) -> some View {
        let handled = ShoppingListStore.isHandled(id: item.id, expiry: item.expiryDate)
        return HStack(spacing: 12) {
            Button {
                ShoppingListStore.setHandled(id: item.id, expiry: item.expiryDate, handled: !handled)
                revision += 1
            } label: {
                Image(systemName: handled ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(handled ? StashPalette.fresh : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(handled ? "Mark \(item.name) as still needed" : "Check off \(item.name)")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body)
                    .strikethrough(handled)
                Text(caption(for: item))
                    .font(.subheadline)
                    .foregroundStyle(item.expiryStatus.tint)
            }
            Spacer(minLength: 0)
            if item.quantity > 0 {
                Button("Used one") {
                    _ = item.consumeOneUnit(in: modelContext)
                    ShoppingListStore.setHandled(id: item.id, expiry: item.expiryDate, handled: true)
                    revision += 1
                }
                .font(.subheadline)
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
        .opacity(handled ? 0.55 : 1)
    }

    private func caption(for item: StashItem) -> String {
        let place = item.location?.name ?? "your stash"
        if let days = item.daysUntilExpiry {
            if days < 0 { return "Expired · \(place)" }
            if days == 0 { return "Today · \(place)" }
            return "\(days) days left · \(place)"
        }
        return place
    }
}
