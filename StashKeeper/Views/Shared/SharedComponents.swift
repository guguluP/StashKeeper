//
//  SharedComponents.swift
//  StashKeeper
//
//  Small reusable views shared across Dashboard, Search, Locations, and
//  Item Detail screens.
//

import SwiftUI
import SwiftData
import AppIntents
#if canImport(WidgetKit)
import WidgetKit
#endif

func reloadWidgets() {
    #if canImport(WidgetKit)
    WidgetCenter.shared.reloadAllTimelines()
    #endif
}

/// Swipeable carousel of every photo an item has (a single photo shows as
/// a static image with no page dots), used in Item Detail so the extra
/// angles captured via the multi-angle merge flow are actually viewable
/// rather than only ever showing `photoFilenames.first`.
struct PhotoCarouselView: View {
    let item: StashItem
    var size: CGFloat = 220

    @State private var selectedIndex = 0

    var body: some View {
        if item.photoFilenames.count <= 1 {
            ItemThumbnail(item: item, size: size)
                .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
        } else {
            VStack(spacing: 8) {
                TabView(selection: $selectedIndex) {
                    ForEach(Array(item.photoFilenames.enumerated()), id: \.offset) { index, filename in
                        SinglePhotoView(filename: filename, size: size)
                            .tag(index)
                    }
                }
                #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .never))
                #endif
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.15), radius: 12, y: 6)

                HStack(spacing: 6) {
                    ForEach(item.photoFilenames.indices, id: \.self) { index in
                        Circle()
                            .fill(index == selectedIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 6, height: 6)
                            .animation(.stashSpring, value: selectedIndex)
                    }
                }
            }
        }
    }
}

/// Loads and displays a single known photo filename — the building block
/// `PhotoCarouselView` pages between, and `ItemThumbnail` uses internally
/// for the primary photo.
private struct SinglePhotoView: View {
    let filename: String
    let size: CGFloat

    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                image.resizableImage
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
        .task(id: filename) {
            guard let data = PhotoStore.loadData(filename: filename) else { return }
            let loaded = PlatformImage(data: data)
            withAnimation(.easeOut(duration: 0.2)) {
                image = loaded
            }
        }
    }
}

/// Loads and displays an item's primary photo from disk, with a placeholder
/// while loading and a system-icon fallback if there's no photo.
struct ItemThumbnail: View {
    let item: StashItem
    var size: CGFloat = 56

    @State private var image: PlatformImage?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let image {
                image.resizableImage
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity.animation(.easeOut(duration: 0.25)))
            } else if item.photoFilenames.isEmpty {
                Image(systemName: categoryFallbackIcon)
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        .task(id: item.photoFilenames.first) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        guard let filename = item.photoFilenames.first,
              let data = PhotoStore.loadData(filename: filename) else { return }
        let loaded = PlatformImage(data: data)
        withAnimation(.easeOut(duration: 0.25)) {
            image = loaded
        }
    }

    private var categoryFallbackIcon: String {
        switch item.category {
        case "Pantry & Food": return "cart"
        case "Fresh Produce": return "carrot"
        case "Dairy": return "drop"
        case "Beverages": return "waterbottle"
        case "Medicine & Health": return "cross.case"
        case "Cosmetics & Toiletries": return "sparkles"
        case "Electronics": return "cable.connector"
        case "Watches & Jewelry": return "clock"
        case "Documents": return "doc.text"
        case "Clothing": return "tshirt"
        case "Tools & Hardware": return "wrench.and.screwdriver"
        case "Kitchenware": return "fork.knife"
        case "Cleaning Supplies": return "bubbles.and.sparkles"
        case "Stationery": return "pencil"
        case "Toys & Games": return "gamecontroller"
        case "Sports & Outdoors": return "figure.hiking"
        case "Automotive": return "car"
        default: return "shippingbox"
        }
    }
}

/// A compact "peek" card shown when long-pressing an item row (via
/// `.contextMenu(menuItems:preview:)`), giving a quick look at the item's
/// photo and key facts without navigating away from the list — the
/// standard iOS long-press-to-preview interaction (same idiom as Mail/
/// Messages), backed here by a lightweight custom SwiftUI view rather than
/// `QLPreviewController` since that API is built around previewing
/// arbitrary documents/files and adds delegate/UIKit bridging overhead for
/// what's really just "show a bigger thumbnail plus a few facts."
struct QuickLookPreviewContent: View {
    let item: StashItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PhotoCarouselView(item: item, size: 220)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.title3.weight(.semibold))

                HStack(spacing: 6) {
                    Text(item.category)
                    if let location = item.location {
                        Text("·")
                        Text(location.name)
                    }
                    if item.quantity > 1 {
                        Text("·")
                        Text("×\(item.quantity)")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if let formattedPrice = item.formattedPrice {
                    Text(formattedPrice)
                        .font(.subheadline.weight(.medium))
                }

                if item.isPerishable {
                    HStack(spacing: 4) {
                        Image(systemName: item.expiryStatus.systemImage)
                        Text(item.expiryStatus.label)
                        if let days = item.daysUntilExpiry {
                            Text("· \(days < 0 ? "\(-days)d ago" : "\(days)d left")")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(item.expiryStatus.tint)
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        .frame(width: 260)
    }
}

/// Shared row-level interactions applied everywhere `ItemRow` appears in a
/// `List`: swipe-to-delete (leading swipe on iOS follows platform
/// convention as an edit affordance, so delete is kept as the trailing
/// swipe action) and a long-press quick-look peek via context menu preview.
/// Centralizing this means the delete confirmation, haptics, and cleanup
/// (photo files + scheduled notifications) stay consistent no matter which
/// list the user deletes from, rather than three subtly different
/// implementations drifting apart over time.
struct ItemRowInteractions: ViewModifier {
    let item: StashItem
    @Environment(\.modelContext) private var modelContext
    @State private var showingDeleteConfirm = false

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    StashHaptics.impact()
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            // Leading swipe: quick quantity adjust without opening the full
            // detail screen — the fastest path for the most common edit
            // (used one, restocked a couple). Full swipe on the leading
            // edge bumps by 1 rather than triggering a destructive-feeling
            // action, since decrementing to zero here doesn't delete the
            // item (that stays an explicit trailing-swipe/detail action).
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    StashHaptics.alignment()
                    adjustQuantity(by: 1)
                } label: {
                    Label("Add One", systemImage: "plus")
                }
                .tint(.green)

                if item.quantity > 0 {
                    Button {
                        StashHaptics.alignment()
                        adjustQuantity(by: -1)
                    } label: {
                        Label("Remove One", systemImage: "minus")
                    }
                    .tint(.orange)
                }
            }
            .contextMenu {
                Button(role: .destructive) {
                    StashHaptics.impact()
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } preview: {
                QuickLookPreviewContent(item: item)
            }
            #else
            // macOS has no swipe-to-delete or long-press preview idiom;
            // a standard right-click context menu covers delete, and
            // hovering already shows a highlight (see ItemRow's onHover)
            // so a peek isn't needed the same way it is on a touch screen.
            .contextMenu {
                Button(role: .destructive) {
                    StashHaptics.impact()
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            #endif
            .confirmationDialog(
                "Delete \"\(item.name)\"?",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    deleteItem()
                }
                Button("Cancel", role: .cancel) {}
            }
    }

    private func deleteItem() {
        StashItemLifecycle.delete(item, from: modelContext)
        StashHaptics.success()
    }

    /// Bumps quantity by `delta`, clamped at 0 (never negative). Doesn't
    /// touch expiry/notification scheduling — those are tied to the
    /// item existing at all, not to count, so a quantity-only edit here
    /// deliberately stays lightweight compared to the full save path in
    /// AddItemFlowView.
    private func adjustQuantity(by delta: Int) {
        item.quantity = max(0, item.quantity + delta)
        item.updatedAt = .now
        try? modelContext.save()
        reloadWidgets()
    }
}

extension View {
    /// Applies the standard swipe-to-delete + long-press quick-look
    /// behavior used everywhere an `ItemRow` appears in a list.
    func itemRowInteractions(for item: StashItem) -> some View {
        modifier(ItemRowInteractions(item: item))
    }
}

/// Cross-platform image wrapper so the same view code works on iOS and macOS.
struct PlatformImage {
    #if os(macOS)
    let nsImage: NSImage?
    init?(data: Data) {
        guard let img = NSImage(data: data) else { return nil }
        self.nsImage = img
    }
    var resizableImage: Image {
        Image(nsImage: nsImage ?? NSImage())
            .resizable()
    }
    #else
    let uiImage: UIImage?
    init?(data: Data) {
        guard let img = UIImage(data: data) else { return nil }
        self.uiImage = img
    }
    var resizableImage: Image {
        Image(uiImage: uiImage ?? UIImage())
            .resizable()
    }
    #endif
}

/// A compact row for an item, used in lists across the app.
struct ItemRow: View {
    let item: StashItem
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            ItemThumbnail(item: item, size: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(item.category)
                    if let location = item.location {
                        Text("·")
                        Text(location.name)
                    }
                    Text("·")
                    Text("×\(item.quantity)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                ExpiryBadge(item: item)
            }

            Spacer(minLength: 8)

            if let formattedPrice = item.formattedPrice {
                Text(formattedPrice)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .padding(.vertical, 6)
        .appEntityIdentifier(EntityIdentifier(for: StashItemEntity.self, identifier: item.id))
        #if os(macOS)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.primary.opacity(isHovering ? 0.05 : 0))
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        #endif
    }
}

/// A pill-style badge for category/tag display.
struct BadgeLabel: View {
    let text: String
    var tint: Color = .blue

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
            .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
    }
}
