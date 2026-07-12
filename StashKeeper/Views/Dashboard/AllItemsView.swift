//
//  AllItemsView.swift
//  StashKeeper
//
//  Flat list of every item, with sort and category filter — the "browse
//  everything" catch-all view alongside Dashboard and Search.
//

import SwiftUI
import SwiftData

struct AllItemsView: View {

    enum SortOption: String, CaseIterable, Identifiable {
        case newest = "Newest"
        case name = "Name"
        case expiry = "Expiry Date"
        var id: String { rawValue }
    }

    @Query private var allItems: [StashItem]
    @State private var sortOption: SortOption = .newest
    @State private var categoryFilter: String?
    @Namespace private var heroNamespace

    private var categories: [String] {
        Array(Set(allItems.map(\.category))).sorted()
    }

    private var sortedFilteredItems: [StashItem] {
        var items = allItems
        if let categoryFilter {
            items = items.filter { $0.category == categoryFilter }
        }
        switch sortOption {
        case .newest:
            items.sort { $0.createdAt > $1.createdAt }
        case .name:
            items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .expiry:
            items.sort { ($0.expiryDate ?? .distantFuture) < ($1.expiryDate ?? .distantFuture) }
        }
        return items
    }

    var body: some View {
        List {
            ForEach(sortedFilteredItems) { item in
                NavigationLink {
                    ItemDetailView(item: item, heroNamespace: heroNamespace)
                } label: {
                    ItemRow(item: item)
                }
                #if os(iOS)
                .matchedTransitionSource(id: item.id, in: heroNamespace)
                #endif
                .itemRowInteractions(for: item)
            }
        }
        .navigationTitle("All Items")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort", selection: $sortOption) {
                        ForEach(SortOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    Divider()
                    Picker("Category", selection: $categoryFilter) {
                        Text("All Categories").tag(String?.none)
                        ForEach(categories, id: \.self) { category in
                            Text(category).tag(String?.some(category))
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .overlay {
            if sortedFilteredItems.isEmpty {
                ContentUnavailableView("No Items", systemImage: "shippingbox")
            }
        }
    }
}

#Preview {
    NavigationStack { AllItemsView() }
        .modelContainer(for: [StashItem.self, StorageLocation.self, StreakRecord.self], inMemory: true)
}
