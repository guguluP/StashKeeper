//
//  RootView.swift
//  StashKeeper
//
//  Adaptive root navigation:
//  - iPhone (compact width): bottom TabView, one NavigationStack per tab so
//    each section keeps its own back-stack, plus a floating Add button.
//  - iPad / macOS (regular width): NavigationSplitView sidebar, which also
//    covers iPad Slide Over/compact multitasking via the size-class check.
//  Handles routing from notification taps and the macOS menu bar "New Item"
//  command in both layouts identically.
//

import SwiftUI
import SwiftData

struct RootView: View {

    enum Section: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard"
        case search = "Search"
        case locations = "Locations"
        case allItems = "All Items"
        case milestones = "Milestones"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .dashboard: return "square.grid.2x2"
            case .search: return "magnifyingglass"
            case .locations: return "archivebox"
            case .allItems: return "list.bullet"
            case .milestones: return "rosette"
            }
        }
    }

    @State private var selectedSection: Section? = .dashboard
    @State private var showingAddItem = false
    @State private var routedItemID: UUID?

    @Environment(\.modelContext) private var modelContext
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Query private var allItems: [StashItem]

    var body: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            compactLayout
        } else {
            regularLayout
        }
        #else
        regularLayout
        #endif
    }

    // MARK: - iPhone layout (compact width)

    #if os(iOS)
    @ViewBuilder
    private var compactLayout: some View {
        ZStack(alignment: .bottomTrailing) {
            TabView(selection: $selectedSection) {
                ForEach(Section.allCases) { section in
                    NavigationStack {
                        tabDestinationView(for: section)
                    }
                    .tabItem {
                        Label(section.rawValue, systemImage: section.systemImage)
                    }
                    .badge(badgeCount(for: section))
                    .tag(Optional(section))
                }
            }

            addItemFloatingButton
                .padding(.trailing, 20)
                .padding(.bottom, 78) // clears the tab bar
        }
        .sheet(isPresented: $showingAddItem) {
            AddItemFlowView()
        }
        .sheet(item: routedItemBinding) { item in
            NavigationStack {
                ItemDetailSheetWrapper(item: item)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestNewItemFlow)) { _ in
            showingAddItem = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .stashItemNotificationAction)) { notification in
            handleNotificationAction(notification)
        }
    }

    /// Each tab hosts a section directly (not through `destinationView`,
    /// which is keyed off `selectedSection` for the split-view detail pane)
    /// so every tab keeps its own live view rather than being torn down
    /// when the user switches tabs.
    @ViewBuilder
    private func tabDestinationView(for section: Section) -> some View {
        switch section {
        case .dashboard: DashboardView()
        case .search: SearchView()
        case .locations: LocationsListView()
        case .allItems: AllItemsView()
        case .milestones: MilestonesView()
        }
    }

    private var addItemFloatingButton: some View {
        Button {
            StashHaptics.impact()
            showingAddItem = true
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        }
        .accessibilityLabel("Add Item")
    }
    #endif

    // MARK: - iPad / macOS layout (regular width)

    @ViewBuilder
    private var regularLayout: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .badge(badgeCount(for: section))
                    .tag(section)
                    .contentTransition(.numericText())
                    .animation(.stashSpring, value: badgeCount(for: section))
            }
            .navigationTitle("StashKeeper")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .scrollContentBackground(.hidden)
            .background(.ultraThinMaterial)
            #endif
        } detail: {
            NavigationStack {
                destinationView
                    .id(selectedSection)
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            }
            .animation(.stashSpring, value: selectedSection)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    StashHaptics.impact()
                    showingAddItem = true
                } label: {
                    Label("Add Item", systemImage: "plus.circle.fill")
                }
                .keyboardShortcut("n", modifiers: .command)
                #if os(macOS)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                #endif
            }
        }
        .sheet(isPresented: $showingAddItem) {
            AddItemFlowView()
                #if os(macOS)
                .frame(minWidth: 560, minHeight: 640)
                #endif
        }
        .sheet(item: routedItemBinding) { item in
            NavigationStack {
                ItemDetailSheetWrapper(item: item)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestNewItemFlow)) { _ in
            showingAddItem = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .stashItemNotificationAction)) { notification in
            handleNotificationAction(notification)
        }
    }

    /// Bridges `routedItemID` (set when a notification is tapped) to a
    /// `.sheet(item:)` presentation of that specific item's detail view.
    private var routedItemBinding: Binding<StashItem?> {
        Binding(
            get: { routedItemID.flatMap { id in allItems.first { $0.id == id } } },
            set: { newValue in routedItemID = newValue?.id }
        )
    }

    @ViewBuilder
    private var destinationView: some View {
        switch selectedSection {
        case .dashboard, .none:
            DashboardView()
        case .search:
            SearchView()
        case .locations:
            LocationsListView()
        case .allItems:
            AllItemsView()
        case .milestones:
            MilestonesView()
        }
    }

    private func badgeCount(for section: Section) -> Int {
        guard section == .dashboard else { return 0 }
        return ExpiryEngine.shared.attentionNeeded(items: allItems).count
    }

    private func handleNotificationAction(_ notification: Notification) {
        guard let itemID = notification.userInfo?["itemID"] as? UUID,
              let actionID = notification.userInfo?["actionID"] as? String,
              let item = allItems.first(where: { $0.id == itemID }) else { return }

        switch actionID {
        case NotificationManager.markUsedActionID:
            // Full cleanup: photos + notifications + model row.
            StashItemLifecycle.delete(item, from: modelContext)
        case NotificationManager.snoozeActionID:
            if let newDate = Calendar.current.date(byAdding: .day, value: 1, to: item.expiryDate ?? .now) {
                item.expiryDate = newDate
                item.expiryUserConfirmed = true
                Task { await ExpiryEngine.shared.syncNotifications(for: item) }
            }
        default:
            // User tapped the notification body itself (not an action
            // button) — route them directly to that item.
            routedItemID = itemID
        }
    }
}

/// Standalone presentation of ItemDetailView for contexts (like a
/// notification tap) that have no natural "source" thumbnail to zoom from
/// — provides its own private namespace since ItemDetailView requires one
/// for its `.navigationTransition(.zoom:)`, but the zoom simply has no
/// visible source view to animate from here, which is fine; SwiftUI falls
/// back to a plain presentation in that case.
private struct ItemDetailSheetWrapper: View {
    let item: StashItem
    @Namespace private var namespace

    var body: some View {
        ItemDetailView(item: item, heroNamespace: namespace)
    }
}

#Preview {
    RootView()
        .modelContainer(for: [StashItem.self, StorageLocation.self, StreakRecord.self], inMemory: true)
}
