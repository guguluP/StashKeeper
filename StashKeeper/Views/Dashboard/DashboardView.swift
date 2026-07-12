//
//  DashboardView.swift
//  StashKeeper
//
//  Home screen: surfaces what needs attention (expiring/expired items) up
//  top, then gives a quick overview of storage locations and recent items.
//

import SwiftUI
import SwiftData

struct DashboardView: View {

    @Query(sort: \StashItem.createdAt, order: .reverse) private var allItems: [StashItem]
    @Query(sort: \StorageLocation.name) private var locations: [StorageLocation]

    @State private var hasAppeared = false
    @State private var showingAssistant = false
    @State private var showingRecipeIdeas = false
    @State private var recipeIdeas: [RecipeSuggestion] = []
    @State private var isLoadingRecipeIdeas = false
    @State private var showingReceiptScan = false
    @Namespace private var heroNamespace

    private var attentionItems: [StashItem] {
        ExpiryEngine.shared.attentionNeeded(items: allItems)
    }

    private var nextMilestones: [CategoryMilestone] {
        Array(MilestoneEngine.shared.nextMilestones(items: allItems).prefix(5))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                assistantPromptChip

                if !attentionItems.isEmpty {
                    attentionSection
                }

                statsRow

                if !nextMilestones.isEmpty {
                    milestonePreviewSection
                }

                if !locations.isEmpty {
                    locationsSection
                }

                if !allItems.isEmpty {
                    recentSection
                } else {
                    ContentUnavailableView(
                        "No Items Yet",
                        systemImage: "shippingbox",
                        description: Text("Tap the + button to photograph and catalog your first item.")
                    )
                    .padding(.top, 60)
                }
            }
            .padding()
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 16)
        }
        .navigationTitle("Dashboard")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                hasAppeared = true
            }
        }
        .sheet(isPresented: $showingAssistant) {
            StashAssistantChatView()
        }
        .sheet(isPresented: $showingRecipeIdeas) {
            RecipeSuggestionsSheet(suggestions: recipeIdeas, isLoading: isLoadingRecipeIdeas)
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingReceiptScan) {
            ReceiptScanView()
        }
        #endif
    }

    // MARK: Sections

    /// Collapsed entry point into the full chat screen — a lightweight,
    /// always-visible chip rather than a full tab, since the assistant is
    /// used in short bursts ("what can I cook tonight") more often than
    /// sustained conversation. Mirrors the Siri/Spotlight pattern of a
    /// small prompt surface that expands into a full screen on tap.
    private var assistantPromptChip: some View {
        VStack(spacing: 10) {
            Button {
                StashHaptics.impact()
                showingAssistant = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.blue)
                    Text("Ask about your stash…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
            }
            .buttonStyle(.pressScale)
            .glassSurface(cornerRadius: 14)

            Button {
                StashHaptics.impact()
                requestRecipeIdeas()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "fork.knife")
                        .foregroundStyle(.orange)
                    Text("What can I cook with what I have?")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
            }
            .buttonStyle(.pressScale)
            .glassSurface(cornerRadius: 14)

            Button {
                StashHaptics.impact()
                showingReceiptScan = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text.viewfinder")
                        .foregroundStyle(.purple)
                    Text("Scan a receipt")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
            }
            .buttonStyle(.pressScale)
            .glassSurface(cornerRadius: 14)
        }
    }

    /// Kicks off on-demand recipe generation from the full current
    /// inventory (not just a scan session's produce) — presents the sheet
    /// immediately in a loading state so tapping feels responsive, then
    /// fills it in once generation completes.
    private func requestRecipeIdeas() {
        recipeIdeas = []
        isLoadingRecipeIdeas = true
        showingRecipeIdeas = true

        Task {
            var fitnessContext: FitnessContext?
            #if os(iOS)
            if let summary = await HealthKitService.shared.fetchTodayFitnessSummary() {
                fitnessContext = FitnessContext(
                    approximateSteps: summary.approximateSteps,
                    approximateActiveEnergyBurned: summary.approximateActiveEnergyBurned,
                    approximateDietaryEnergyConsumed: summary.approximateDietaryEnergyConsumed
                )
            }
            #endif
            let suggestions = await RecipeSuggestionService.shared.suggestRecipesFromInventory(
                items: allItems,
                fitnessContext: fitnessContext
            )
            recipeIdeas = suggestions
            isLoadingRecipeIdeas = false
        }
    }

    private var milestonePreviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Almost There", systemImage: "rosette")
                    .font(.headline)
                Spacer()
                NavigationLink("See All") { MilestonesView() }
                    .font(.subheadline)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(nextMilestones) { milestone in
                        NavigationLink {
                            MilestonesView()
                        } label: {
                            MilestonePreviewChip(milestone: milestone)
                        }
                        .buttonStyle(.pressScale)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }

    private var attentionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Needs Attention", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(attentionItems) { item in
                        NavigationLink(value: item.id) {
                            AttentionCard(item: item)
                        }
                        .buttonStyle(.pressScale)
                        #if os(iOS)
                        .matchedTransitionSource(id: item.id, in: heroNamespace)
                        #endif
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
        .navigationDestination(for: UUID.self) { id in
            if let item = allItems.first(where: { $0.id == id }) {
                ItemDetailView(item: item, heroNamespace: heroNamespace)
            }
        }
    }

    private var statsRow: some View {
        StashGlassGroup(spacing: 12) {
            HStack(spacing: 12) {
                StatTile(title: "Total Items", value: "\(allItems.count)", systemImage: "shippingbox", tint: .blue)
                StatTile(title: "Locations", value: "\(locations.count)", systemImage: "archivebox", tint: .purple)
                StatTile(title: "Expiring Soon", value: "\(attentionItems.count)", systemImage: "clock.badge.exclamationmark", tint: .orange)
            }
        }
    }

    private var locationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Locations").font(.headline)
                Spacer()
                NavigationLink("See All") { LocationsListView() }
                    .font(.subheadline)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(locations.prefix(8)) { location in
                        NavigationLink {
                            LocationDetailView(location: location)
                        } label: {
                            LocationChip(location: location)
                        }
                        .buttonStyle(.pressScale)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recently Added").font(.headline)
            LazyVStack(spacing: 8) {
                ForEach(allItems.prefix(6)) { item in
                    NavigationLink {
                        ItemDetailView(item: item, heroNamespace: heroNamespace)
                    } label: {
                        ItemRow(item: item)
                    }
                    .buttonStyle(.pressScale)
                    #if os(iOS)
                    .matchedTransitionSource(id: item.id, in: heroNamespace)
                    #endif
                }
            }
        }
    }
}

// MARK: - Subviews

private struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: value)
            Text(value)
                .font(.title2.bold())
                .contentTransition(.numericText())
                .animation(.spring(response: 0.4, dampingFraction: 0.75), value: value)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .glassSurface(cornerRadius: 16)
        #if os(macOS)
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .shadow(color: .black.opacity(isHovering ? 0.12 : 0), radius: 10, y: 4)
        .onHover { hovering in
            withAnimation(.stashSpring) { isHovering = hovering }
        }
        #endif
    }
}

private struct MilestonePreviewChip: View {
    let milestone: CategoryMilestone
    @State private var animatedProgress: Double = 0

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(milestone.tier.tint.opacity(0.15), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: animatedProgress)
                    .stroke(milestone.tier.tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: milestone.systemImage)
                    .font(.callout)
                    .foregroundStyle(milestone.tier.tint)
            }
            .frame(width: 52, height: 52)

            Text(milestone.category)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .frame(width: 84)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75).delay(0.1)) {
                animatedProgress = milestone.progress
            }
        }
    }
}

private struct AttentionCard: View {
    let item: StashItem
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ItemThumbnail(item: item, size: 90)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: item.expiryStatus.systemImage)
                        .font(.caption)
                        .padding(6)
                        .background(item.expiryStatus.tint, in: Circle())
                        .foregroundStyle(.white)
                        .padding(6)
                }

            Text(item.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            if let days = item.daysUntilExpiry {
                Text(days < 0 ? "Expired" : days == 0 ? "Today" : "\(days)d left")
                    .font(.caption)
                    .foregroundStyle(item.expiryStatus.tint)
            }
        }
        .frame(width: 110)
        .padding(10)
        .glassSurface(cornerRadius: 16)
        #if os(macOS)
        .scaleEffect(isHovering ? 1.03 : 1.0)
        .shadow(color: .black.opacity(isHovering ? 0.15 : 0), radius: 12, y: 6)
        .onHover { hovering in
            withAnimation(.stashSpring) { isHovering = hovering }
        }
        #endif
    }
}

private struct LocationChip: View {
    let location: StorageLocation
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: location.iconSystemName)
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(.blue.opacity(isHovering ? 0.25 : 0.15), in: Circle())
                .foregroundStyle(.blue)
                .scaleEffect(isHovering ? 1.08 : 1.0)
            Text(location.name)
                .font(.caption)
                .lineLimit(1)
            Text("\(location.items.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 76)
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.stashSpring) { isHovering = hovering }
        }
        #endif
    }
}

#Preview {
    NavigationStack { DashboardView() }
        .modelContainer(for: [StashItem.self, StorageLocation.self, StreakRecord.self], inMemory: true)
}
