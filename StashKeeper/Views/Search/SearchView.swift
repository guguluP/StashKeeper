//
//  SearchView.swift
//  StashKeeper
//
//  Lets the user search their stash in plain language ("where's my
//  passport", "what's expiring in the fridge") as well as plain keyword
//  matching. Foundation Models translates the query into a SearchIntent;
//  we apply that as an in-memory filter over the SwiftData results.
//  Falls back to simple substring search if Apple Intelligence is
//  unavailable, so the feature never fully breaks.
//

import SwiftUI
import SwiftData

struct SearchView: View {

    @Query private var allItems: [StashItem]
    @Query(sort: \StorageLocation.name) private var locations: [StorageLocation]

    @State private var queryText = ""
    @State private var isInterpreting = false
    @State private var lastIntent: SearchIntent?
    @State private var searchTask: Task<Void, Never>?
    @Namespace private var heroNamespace

    var body: some View {
        VStack(spacing: 0) {
            searchField

            if let lastIntent, hasStructuredFilter(lastIntent) {
                interpretedFiltersBar(lastIntent)
            }

            if results.isEmpty && !queryText.isEmpty {
                ContentUnavailableView.search(text: queryText)
            } else {
                List {
                    ForEach(results) { item in
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
                .listStyle(.plain)
            }
        }
        .navigationTitle("Search")
        .onChange(of: queryText) { _, newValue in
            debounceInterpret(newValue)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: isInterpreting ? "sparkles" : "magnifyingglass")
                .foregroundStyle(isInterpreting ? .blue : .secondary)
                .symbolEffect(.pulse, isActive: isInterpreting)
            TextField("Try \"expired food\" or \"passport\"", text: $queryText)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            if !queryText.isEmpty {
                Button {
                    queryText = ""
                    lastIntent = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding()
    }

    private func interpretedFiltersBar(_ intent: SearchIntent) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if !intent.category.isEmpty {
                    BadgeLabel(text: intent.category, tint: .purple)
                }
                if !intent.location.isEmpty {
                    BadgeLabel(text: intent.location, tint: .blue)
                }
                if intent.expiryFocused {
                    BadgeLabel(text: "Expiring / Expired", tint: .orange)
                }
                ForEach(intent.keywords, id: \.self) { keyword in
                    BadgeLabel(text: keyword, tint: .gray)
                }
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Filtering

    private var results: [StashItem] {
        guard !queryText.isEmpty else { return allItems }

        guard let intent = lastIntent else {
            // Fallback: plain substring match while AI interpretation is pending
            // or unavailable.
            return allItems.filter {
                $0.searchableText.localizedCaseInsensitiveContains(queryText)
            }
        }

        var filtered = allItems

        if !intent.category.isEmpty {
            filtered = filtered.filter { $0.category.localizedCaseInsensitiveCompare(intent.category) == .orderedSame }
        }
        if !intent.location.isEmpty {
            filtered = filtered.filter { $0.location?.name.localizedCaseInsensitiveCompare(intent.location) == .orderedSame }
        }
        if intent.expiryFocused {
            filtered = filtered.filter { $0.expiryStatus == .expiringSoon || $0.expiryStatus == .expired }
        }
        if !intent.keywords.isEmpty {
            filtered = filtered.filter { item in
                intent.keywords.contains { keyword in
                    item.searchableText.localizedCaseInsensitiveContains(keyword)
                }
            }
        }

        // If structured filters produced nothing (e.g. slight mismatch), fall
        // back to raw substring search so the user isn't left with a dead end.
        if filtered.isEmpty {
            return allItems.filter { $0.searchableText.localizedCaseInsensitiveContains(queryText) }
        }
        return filtered
    }

    private func hasStructuredFilter(_ intent: SearchIntent) -> Bool {
        !intent.category.isEmpty || !intent.location.isEmpty || intent.expiryFocused || !intent.keywords.isEmpty
    }

    private func debounceInterpret(_ text: String) {
        searchTask?.cancel()
        guard !text.isEmpty, ItemIntelligenceService.shared.isAvailableViaAnyTier else {
            lastIntent = nil
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            isInterpreting = true
            defer { isInterpreting = false }

            let intent = try? await ItemIntelligenceService.shared.interpretSearchQuery(
                text,
                knownCategories: Array(Set(allItems.map(\.category))),
                knownLocations: locations.map(\.name),
                existingItems: allItems
            )
            guard !Task.isCancelled else { return }
            lastIntent = intent
        }
    }
}

#Preview {
    NavigationStack { SearchView() }
        .modelContainer(for: [StashItem.self, StorageLocation.self, StreakRecord.self], inMemory: true)
}
