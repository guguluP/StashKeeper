//
//  StashKeeperApp.swift
//  StashKeeper
//
//  App entry point. Sets up the SwiftData container, requests notification
//  permission, and re-syncs expiry notifications on launch so scheduled
//  reminders always reflect the latest data (in case items changed while
//  the app wasn't running, e.g. via iCloud sync in a future version).
//

import SwiftUI
import SwiftData

@main
struct StashKeeperApp: App {

    let modelContainer: ModelContainer

    init() {
        modelContainer = ModelContainerProvider.shared
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .task {
                    await NotificationManager.shared.requestAuthorizationIfNeeded()
                    await resyncAllNotifications()
                    MilestoneEngine.shared.recordDailyActivity(context: modelContainer.mainContext)
                    await SpotlightIndexer.reindexAll()
                }
        }
        .modelContainer(modelContainer)
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Item…") {
                    NotificationCenter.default.post(name: .requestNewItemFlow, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        #endif

        #if os(macOS)
        MenuBarExtra("StashKeeper", systemImage: "shippingbox.fill") {
            MenuBarSummaryView()
                .modelContainer(modelContainer)
        }
        .menuBarExtraStyle(.window)
        #endif
    }

    @MainActor
    private func resyncAllNotifications() async {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<StashItem>()
        guard let items = try? context.fetch(descriptor) else { return }
        await ExpiryEngine.shared.resyncAll(items: items)
        try? context.save()
    }
}


