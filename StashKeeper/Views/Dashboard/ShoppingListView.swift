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
    @Query(sort: \PurchaseNeed.createdAt, order: .reverse) private var needs: [PurchaseNeed]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayMetrics) private var metrics
    @State private var revision = 0
    @State private var showChecked = false
    @State private var newBuyName = ""

    private var attention: [StashItem] {
        _ = revision
        return ExpiryEngine.shared.attentionNeeded(items: items)
    }

    private var rows: [StashItem] {
        if showChecked { return attention }
        return attention.filter {
            !ShoppingListStore.isHandled(id: $0.id, expiry: $0.expiryDate)
        }
    }

    private var shortfalls: [StashItem] {
        items
            .filter { $0.parQuantity > $0.quantity }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var openNeeds: [PurchaseNeed] {
        needs.filter { !$0.isChecked }
    }

    var body: some View {
        Group {
            List {
                Section {
                    Text("Use soon is what is expiring. To buy is what you are below the amount you keep, plus anything you add here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section("To buy") {
                    if shortfalls.isEmpty && openNeeds.isEmpty {
                        Text("Nothing to buy.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(shortfalls) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                            Text("Have \(item.quantity), keep \(item.parQuantity). Buy \(item.parQuantity - item.quantity).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(openNeeds) { need in
                        HStack {
                            Text(need.name)
                            Spacer()
                            Text("×\(need.quantity)")
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Bought", role: .destructive) {
                                need.isChecked = true
                                try? modelContext.save()
                                Task { await GroceryList.publish() }
                            }
                        }
                    }
                    TextField("Add something to buy", text: $newBuyName)
                    Button("Add to buy list") {
                        let trimmed = newBuyName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        modelContext.insert(PurchaseNeed(name: trimmed))
                        try? modelContext.save()
                        newBuyName = ""
                        Task { await GroceryList.publish() }
                    }
                    .disabled(newBuyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if rows.isEmpty {
                    Section("Use or replace") {
                        Text(attention.isEmpty
                             ? "Nothing is expiring."
                             : "Checked items stay off this list until their expiry date changes.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Use or replace") {
                        ForEach(rows) { item in
                            row(item)
                        }
                    }
                }
            }
        }
        .navigationTitle("Shopping")
        .toolbar {
            if attention.contains(where: { ShoppingListStore.isHandled(id: $0.id, expiry: $0.expiryDate) }) {
                ToolbarItem(placement: .automatic) {
                    Button(showChecked ? "Hide checked" : "Show checked") {
                        showChecked.toggle()
                    }
                }
            }
        }
        .adaptivePage()
    }

    private func row(_ item: StashItem) -> some View {
        let handled = ShoppingListStore.isHandled(id: item.id, expiry: item.expiryDate)
        return ViewThatFits(in: .horizontal) {
            shoppingRow(item, handled: handled, stacked: false)
            shoppingRow(item, handled: handled, stacked: true)
        }
        .padding(.vertical, 4)
        .opacity(handled ? 0.55 : 1)
    }

    private func shoppingRow(_ item: StashItem, handled: Bool, stacked: Bool) -> some View {
        let check = Button {
            ShoppingListStore.setHandled(id: item.id, expiry: item.expiryDate, handled: !handled)
            revision += 1
        } label: {
            Image(systemName: handled ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(handled ? StashPalette.fresh : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(handled ? "Mark \(item.name) as still needed" : "Check off \(item.name)")

        let labels = VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
                .font(.body)
                .strikethrough(handled)
                .fixedSize(horizontal: false, vertical: true)
            Text(caption(for: item))
                .font(.subheadline)
                .foregroundStyle(item.expiryStatus.tint)
                .fixedSize(horizontal: false, vertical: true)
        }

        let used = Button("Used one") {
            let remaining = item.consumeOneUnit(in: modelContext)
            if remaining == 0 {
                ShoppingListStore.setHandled(id: item.id, expiry: item.expiryDate, handled: false)
            }
            Task { await StashItemLifecycle.afterEdit(item, in: modelContext) }
            revision += 1
        }
        .font(.subheadline)
        .buttonStyle(.bordered)

        return Group {
            if stacked {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        check
                        labels
                    }
                    if item.quantity > 0 { used }
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    check
                    labels
                    Spacer(minLength: 8)
                    if item.quantity > 0 { used }
                }
            }
        }
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
