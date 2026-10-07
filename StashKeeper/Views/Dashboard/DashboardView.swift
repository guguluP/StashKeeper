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
    @Environment(\.displayMetrics) private var metrics

    private var attentionItems: [StashItem] {
        ExpiryEngine.shared.attentionNeeded(items: allItems)
    }

    private var nextMilestones: [CategoryMilestone] {
        Array(MilestoneEngine.shared.nextMilestones(items: allItems).prefix(5))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                todayHero
                quickActions

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
                    emptyInventory
                }
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.vertical, 12)
            .adaptivePage()
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: metrics.reduceMotion ? 0 : (hasAppeared ? 0 : 12))
        }
        .background { StashTheme.screenBackground }
        .navigationTitle("Home")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .onAppear {
            withAnimation(.stashSpring(for: metrics)) {
                hasAppeared = true
            }
        }
        .sheet(isPresented: $showingAssistant) {
            StashAssistantChatView()
                .sheetPopIn()
        }
        .sheet(isPresented: $showingRecipeIdeas) {
            RecipeSuggestionsSheet(suggestions: recipeIdeas, isLoading: isLoadingRecipeIdeas)
                .sheetPopIn()
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingReceiptScan) {
            ReceiptScanView()
                .sheetPopIn()
        }
        #endif
    }

    // MARK: Sections

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var todayInsight: String {
        let expired = attentionItems.filter { $0.expiryStatus == .expired }.count
        if allItems.isEmpty { return "Photograph a shelf or package to start your stash." }
        if expired > 0 { return "\(expired) expired · \(attentionItems.count) need a look" }
        if !attentionItems.isEmpty { return "Use the soonest items first — the assistant can cook around them." }
        return "Nothing urgent. \(allItems.count) items across \(locations.count) places."
    }

    private var todayHero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(greeting)
                .font(.title2.weight(.semibold))
            Text(todayInsight)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background { StashTheme.heroGradient.opacity(0.55) }
        .glassSurface(cornerRadius: 24)
    }

    private var quickActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { quickActionButtons }
            VStack(spacing: 10) { quickActionButtons }
        }
    }

    @ViewBuilder
    private var quickActionButtons: some View {
        quickActionTile(title: "Ask", systemImage: "sparkles", tint: .blue) {
            showingAssistant = true
        }
        quickActionTile(title: "Cook", systemImage: "fork.knife", tint: .orange) {
            requestRecipeIdeas()
        }
        quickActionTile(title: "Receipt", systemImage: "doc.text.viewfinder", tint: .purple) {
            showingReceiptScan = true
        }
    }

    private func quickActionTile(title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            StashHaptics.impact()
            action()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(tint.opacity(0.15), in: Circle())
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.pressScale)
        .glassSurface(cornerRadius: 18, interactive: true)
        .accessibilityLabel(title)
    }

    private var emptyInventory: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Start with one of these")
                .font(.title3.weight(.semibold))
            Text("Nothing is saved yet. These samples show what each path looks like. Tap one to do it for real.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            sampleCard(
                title: "Photograph a shelf",
                detail: "Milk · Fridge · expires in 4 days",
                systemImage: "camera.viewfinder",
                tint: .blue
            ) {
                NotificationCenter.default.post(name: .requestNewItemFlow, object: nil)
            }
            sampleCard(
                title: "Scan a receipt",
                detail: "3 lines ready to catalog, prices filled in",
                systemImage: "doc.text.viewfinder",
                tint: .purple
            ) {
                showingReceiptScan = true
            }
            NavigationLink {
                LocationsListView()
            } label: {
                sampleCardLabel(
                    title: "Name a place",
                    detail: "Pantry, Fridge, or a drawer you actually use",
                    systemImage: "archivebox",
                    tint: .orange
                )
            }
            .buttonStyle(.pressScale)
        }
        .padding(.top, 8)
    }

    private func sampleCard(title: String, detail: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            sampleCardLabel(title: title, detail: detail, systemImage: systemImage, tint: tint)
        }
        .buttonStyle(.pressScale)
    }

    private func sampleCardLabel(title: String, detail: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .glassSurface(cornerRadius: 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
        .accessibilityAddTraits(.isButton)
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
            StashSectionHeader(title: "Needs attention", systemImage: "exclamationmark.triangle.fill", tint: .orange)

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
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: 12),
            count: min(3, max(metrics.columnCount, metrics.width >= 520 ? 3 : 1))
        )
        return StashGlassGroup(spacing: 12) {
            LazyVGrid(columns: columns, spacing: 12) {
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
    @Environment(\.displayMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        .frame(width: metrics.locationChipWidth + 16)
        .onAppear {
            if reduceMotion {
                animatedProgress = milestone.progress
            } else {
                withAnimation(.stashSpring(for: metrics).delay(0.1)) {
                    animatedProgress = milestone.progress
                }
            }
        }
    }
}

private struct AttentionCard: View {
    let item: StashItem
    @Environment(\.displayMetrics) private var metrics
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ItemThumbnail(item: item, size: metrics.attentionCardWidth - 28)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: item.expiryStatus.systemImage)
                        .font(.caption)
                        .padding(6)
                        .background(item.expiryStatus.tint, in: Circle())
                        .foregroundStyle(StashPalette.ink(for: colorScheme))
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
        .frame(width: metrics.attentionCardWidth)
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
    @Environment(\.displayMetrics) private var metrics
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
        .frame(width: metrics.locationChipWidth)
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
