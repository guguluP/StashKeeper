//
//  MenuBarSummaryView.swift
//  StashKeeper (macOS)
//
//  Compact popover shown from the macOS menu bar icon — quick glance at
//  what's expiring without opening the full app window.
//

#if os(macOS)
import SwiftUI
import SwiftData

struct MenuBarSummaryView: View {

    @Query private var allItems: [StashItem]
    @Environment(\.openWindow) private var openWindow

    private var attentionItems: [StashItem] {
        ExpiryEngine.shared.attentionNeeded(items: allItems)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("StashKeeper")
                    .font(.headline)
                Spacer()
                Text("\(allItems.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            if attentionItems.isEmpty {
                Text("Nothing expiring soon")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(attentionItems.prefix(6)) { item in
                            HStack {
                                Image(systemName: item.expiryStatus.systemImage)
                                    .foregroundStyle(item.expiryStatus.tint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).font(.subheadline)
                                    Text(item.location?.name ?? "Unsorted")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let days = item.daysUntilExpiry {
                                    Text(days < 0 ? "Expired" : "\(days)d")
                                        .font(.caption)
                                        .foregroundStyle(item.expiryStatus.tint)
                                }
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 260)
            }

            Divider()

            HStack {
                Button("Open StashKeeper") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(12)
        }
        .frame(width: 300)
    }
}
#endif
