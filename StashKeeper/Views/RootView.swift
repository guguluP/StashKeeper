//
//  RootView.swift
//  StashKeeper
//
//  Each device gets the navigation it already uses:
//  - iPhone: a five-item tab bar (Home, Items, Shopping, More, Search).
//  - iPad: a sidebar in a split view, including Settings.
//  - Mac: the same split view, with the system sidebar style. Settings
//    opens from the app menu, not the sidebar.
//  iPad Slide Over uses the iPhone tabs because the width is compact.
//

import SwiftUI
import SwiftData

struct RootView: View {

    enum Section: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard"
        case search = "Search"
        case locations = "Locations"
        case allItems = "All Items"
        case shopping = "Shopping"
        case household = "Household"
        case milestones = "Milestones"
        case settings = "Settings"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .dashboard: return "square.grid.2x2"
            case .search: return "magnifyingglass"
            case .locations: return "archivebox"
            case .allItems: return "list.bullet"
            case .shopping: return "checklist"
            case .household: return "person.2"
            case .milestones: return "rosette"
            case .settings: return "gearshape"
            }
        }

        /// Short labels for tabs and the sidebar. The screens keep their own titles.
        var label: String {
            switch self {
            case .dashboard: return "Home"
            case .allItems: return "Items"
            default: return rawValue
            }
        }
    }

    private var stashSections: [Section] {
        [.dashboard, .allItems, .locations, .shopping, .search]
    }

    private var personalSections: [Section] {
        #if os(macOS)
        [.household, .milestones]
        #else
        [.household, .milestones, .settings]
        #endif
    }

    @State private var selectedSection: Section? = .dashboard
    @State private var showingAddItem = false
    @State private var routedItemID: UUID?

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Query private var allItems: [StashItem]

    var body: some View {
        Group {
            #if os(iOS)
            if horizontalSizeClass == .compact {
                phoneLayout
            } else {
                padLayout
            }
            #else
            macLayout
            #endif
        }
        .displayAdaptive()
        .task { drainPendingRoute() }
    }

    // MARK: - iPhone

    #if os(iOS)
    @ViewBuilder
    private var phoneLayout: some View {
        TabView(selection: $selectedSection) {
            Tab(Section.dashboard.label, systemImage: Section.dashboard.systemImage, value: Optional(Section.dashboard)) {
                phoneStack { DashboardView() }
            }
            Tab(Section.allItems.label, systemImage: Section.allItems.systemImage, value: Optional(Section.allItems)) {
                phoneStack { AllItemsView() }
            }
            Tab(Section.shopping.label, systemImage: Section.shopping.systemImage, value: Optional(Section.shopping)) {
                phoneStack { ShoppingListView() }
            }
            .badge(badgeCount(for: .shopping))
            Tab("More", systemImage: "ellipsis", value: Optional(Section.settings)) {
                NavigationStack {
                    PhoneMoreView()
                        .phoneAddToolbar { showingAddItem = true }
                }
            }
            Tab("Search", systemImage: "magnifyingglass", value: Optional(Section.search), role: .search) {
                phoneStack { SearchView() }
            }
        }
        .rootRouting(
            showingAddItem: $showingAddItem,
            routedItem: routedItemBinding,
            onOpenURL: handleOpenURL,
            onShowShopping: { selectedSection = .shopping },
            onFocusSearch: { selectedSection = .search },
            onOpenItem: { routedItemID = $0 }
        )
    }

    private func phoneStack<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .phoneAddToolbar { showingAddItem = true }
        }
    }

    #endif

    // MARK: - iPad

    #if os(iOS)
    private var padLayout: some View {
        splitLayout(columnMin: 260, columnIdeal: 300, wideAddSheet: false)
    }
    #endif

    // MARK: - Mac

    #if os(macOS)
    private var macLayout: some View {
        splitLayout(columnMin: 220, columnIdeal: 240, wideAddSheet: true)
    }
    #endif

    private func splitLayout(columnMin: CGFloat, columnIdeal: CGFloat, wideAddSheet: Bool) -> some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                SwiftUI.Section("Stash") {
                    ForEach(stashSections) { section in
                        sidebarRow(section)
                    }
                }
                SwiftUI.Section("You") {
                    ForEach(personalSections) { section in
                        sidebarRow(section)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("StashKeeper")
            .navigationSplitViewColumnWidth(min: columnMin, ideal: columnIdeal)
        } detail: {
            NavigationStack {
                destinationView
                    .id(selectedSection)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    StashHaptics.impact()
                    showingAddItem = true
                } label: {
                    Label("Add Item", systemImage: "plus")
                }
                #if os(iOS)
                .keyboardShortcut("n", modifiers: .command)
                #endif
                .buttonStyle(.borderedProminent)
            }
        }
        .rootRouting(
            showingAddItem: $showingAddItem,
            routedItem: routedItemBinding,
            onOpenURL: handleOpenURL,
            onShowShopping: { selectedSection = .shopping },
            onFocusSearch: { selectedSection = .search },
            onOpenItem: { routedItemID = $0 },
            wideAddSheet: wideAddSheet
        )
    }

    private func sidebarRow(_ section: Section) -> some View {
        Label(section.label, systemImage: section.systemImage)
            .badge(badgeCount(for: section))
            .tag(section)
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
        case .shopping:
            ShoppingListView()
        case .household:
            HouseholdView()
        case .milestones:
            MilestonesView()
        case .settings:
            SettingsView()
        }
    }

    private func badgeCount(for section: Section) -> Int {
        if section == .shopping || section == .dashboard {
            return ExpiryEngine.shared.attentionNeeded(items: allItems).filter {
                !ShoppingListStore.isHandled(id: $0.id, expiry: $0.expiryDate)
            }.count
        }
        return 0
    }

    private func handleOpenURL(_ url: URL) {
        guard url.scheme == "stashkeeper" else { return }
        if url.host == "item" {
            let idString = url.pathComponents.last ?? url.host
            if let idString, let id = UUID(uuidString: idString) {
                routedItemID = id
            }
        } else if url.host == "add" {
            showingAddItem = true
        }
    }

    /// Reads a route stashed by an intent or a notification before this view existed.
    private func drainPendingRoute() {
        if StashPendingRoute.showAddItem {
            StashPendingRoute.showAddItem = false
            showingAddItem = true
        }
        if StashPendingRoute.showExpiring {
            StashPendingRoute.showExpiring = false
            selectedSection = .shopping
        }
        if let id = StashPendingRoute.itemID {
            StashPendingRoute.itemID = nil
            routedItemID = id
        }
    }
}

private struct PhoneMoreView: View {
    var body: some View {
        List {
            NavigationLink {
                LocationsListView()
            } label: {
                Label("Locations", systemImage: "archivebox")
            }
            NavigationLink {
                HouseholdView()
            } label: {
                Label("Household", systemImage: "person.2")
            }
            NavigationLink {
                MilestonesView()
            } label: {
                Label("Milestones", systemImage: "rosette")
            }
            NavigationLink {
                SettingsView()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .navigationTitle("More")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
    }
}

private struct PhoneAddToolbar: ViewModifier {
    let add: () -> Void

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: add) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Item")
            }
        }
    }
}

private extension View {
    func phoneAddToolbar(add: @escaping () -> Void) -> some View {
        modifier(PhoneAddToolbar(add: add))
    }

    func rootRouting(
        showingAddItem: Binding<Bool>,
        routedItem: Binding<StashItem?>,
        onOpenURL: @escaping (URL) -> Void,
        onShowShopping: @escaping () -> Void,
        onFocusSearch: @escaping () -> Void,
        onOpenItem: @escaping (UUID) -> Void,
        wideAddSheet: Bool = false
    ) -> some View {
        modifier(RootRouting(
            showingAddItem: showingAddItem,
            routedItem: routedItem,
            onOpenURL: onOpenURL,
            onShowShopping: onShowShopping,
            onFocusSearch: onFocusSearch,
            onOpenItem: onOpenItem,
            wideAddSheet: wideAddSheet
        ))
    }
}

private struct RootRouting: ViewModifier {
    @Binding var showingAddItem: Bool
    @Binding var routedItem: StashItem?
    let onOpenURL: (URL) -> Void
    let onShowShopping: () -> Void
    let onFocusSearch: () -> Void
    let onOpenItem: (UUID) -> Void
    var wideAddSheet = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingAddItem) {
                AddItemFlowView()
                    .frame(minWidth: wideAddSheet ? 560 : nil, minHeight: wideAddSheet ? 640 : nil)
                    .sheetPopIn()
            }
            .sheet(item: $routedItem) { item in
                NavigationStack {
                    ItemDetailSheetWrapper(item: item)
                }
                .sheetPopIn()
            }
            .onReceive(NotificationCenter.default.publisher(for: .requestNewItemFlow)) { _ in
                StashPendingRoute.showAddItem = false
                showingAddItem = true
            }
            .onOpenURL(perform: onOpenURL)
            .onReceive(NotificationCenter.default.publisher(for: .openStashItem)) { notification in
                StashPendingRoute.itemID = nil
                if let id = notification.userInfo?["itemID"] as? UUID {
                    onOpenItem(id)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showExpiringItems)) { _ in
                StashPendingRoute.showExpiring = false
                onShowShopping()
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
                onFocusSearch()
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
