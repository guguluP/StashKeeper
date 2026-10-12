//
//  SettingsView.swift
//  StashKeeper
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [StashItem]
    @Query private var locations: [StorageLocation]
    @State private var warningWindowDays = StashSettings.currentWarningWindowDays
    @State private var shareGroceries = StashSettings.shareGroceriesWithReminders
    @State private var exportDocument = JSONFile(data: Data())
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var statusMessage: String?
    @State private var notificationStatus: String = "Unknown"
    @State private var lookupEntries: [BarcodeLookupEntry] = []

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your stash, your rules")
                        .font(.headline)
                    Text("Reminders, backup, and how soon we warn you before food goes off.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Household") {
                TextField("Your name", text: Binding(
                    get: { StashSettings.householdName == "Me" ? "" : StashSettings.householdName },
                    set: { StashSettings.householdName = $0.isEmpty ? "Me" : $0 }
                ), prompt: Text("Me"))
                Text("This name is stored on each quantity change, so another device on this iCloud account can see who used an item.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show the buy list in Reminders", isOn: $shareGroceries)
                Text("Siri can ask what groceries you need. When this is on, the same list is a Reminders list named StashKeeper Groceries, so Reminders and other apps can use it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: shareGroceries) { _, enabled in
                Task {
                    if enabled {
                        let granted = await GroceryRemindersSync.shared.requestAccessAndSync()
                        if !granted {
                            shareGroceries = false
                            StashSettings.shareGroceriesWithReminders = false
                            statusMessage = "Reminders access is off, so other apps cannot see the buy list yet."
                        }
                    } else {
                        StashSettings.shareGroceriesWithReminders = false
                    }
                }
            }
            Section("Expiry reminders") {
                Picker("Warn me", selection: $warningWindowDays) {
                    ForEach(StashSettings.allowedWarningWindowDays, id: \.self) { days in
                        Text("\(days) days before expiry").tag(days)
                    }
                }
                Text("Notifications: \(notificationStatus)")
                    .foregroundStyle(.secondary)
                Button("Request notification access") {
                    Task {
                        await NotificationManager.shared.requestAuthorizationIfNeeded()
                        await refreshNotificationStatus()
                    }
                }
            }

            barcodeLookupSection

            Section("Backup") {
                Button("Export inventory as JSON") {
                    do {
                        let data = try InventoryExport.makeBackup(items: items, locations: locations)
                        exportDocument.data = data
                        showingExporter = true
                    } catch {
                        statusMessage = "Export failed: \(error.localizedDescription)"
                    }
                }
                Button("Import inventory JSON") {
                    showingImporter = true
                }
                Text("Photos are not inside the JSON; they stay in this device's photo store.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                }
            }
        }
        .navigationTitle("Settings")
        .onChange(of: warningWindowDays) { _, newValue in
            StashSettings.warningWindowDays = newValue
            Task { await resyncReminders() }
        }
        .task {
            await refreshNotificationStatus()
            await reloadLookupStats()
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "StashKeeper-backup"
        ) { result in
            if case .failure(let error) = result {
                statusMessage = error.localizedDescription
            } else {
                statusMessage = "Export saved."
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let result = try InventoryExport.importBackup(data, into: modelContext)
                    statusMessage = importStatus(result)
                    Task { await resyncReminders() }
                } catch {
                    statusMessage = "Import failed: \(error.localizedDescription)"
                }
            case .failure(let error):
                statusMessage = error.localizedDescription
            }
        }
    }

    private func importStatus(_ result: InventoryImportResult) -> String {
        "Added \(result.inserted) new item\(result.inserted == 1 ? "" : "s"), updated \(result.updated)."
    }

    private func resyncReminders() async {
        let fetched = (try? modelContext.fetch(FetchDescriptor<StashItem>())) ?? items
        await ExpiryEngine.shared.resyncAll(items: fetched)
        try? modelContext.save()
        reloadWidgets()
    }

    @ViewBuilder
    private var barcodeLookupSection: some View {
        let notFound = lookupEntries.filter { $0.outcome == .miss }
        let networkFailures = lookupEntries.filter { $0.outcome == .networkFailure }
        let hits = lookupEntries.filter {
            if case .hit = $0.outcome { return true }
            return false
        }
        Section("Barcode lookup") {
            if lookupEntries.isEmpty {
                Text("No scans recorded yet. Each barcode lookup is kept on this device so you can see whether a miss is a real gap or a failed request.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Recorded lookups", value: "\(lookupEntries.count)")
                LabeledContent("Hits", value: "\(hits.count)")
                LabeledContent("Not in a database", value: "\(notFound.count)")
                LabeledContent("Couldn't reach a database", value: "\(networkFailures.count)")
                LabeledContent(
                    "Miss rate",
                    value: missRateLabel(misses: notFound.count, total: hits.count + notFound.count)
                )
                let missedBarcodes = uniqueMissedBarcodes(from: notFound)
                if !missedBarcodes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Barcodes with no match")
                            .font(.subheadline)
                        ForEach(missedBarcodes.prefix(8), id: \.barcode) { row in
                            Text("\(row.barcode) · \(row.count)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Barcodes with no match: \(missedBarcodes.prefix(8).map(\.barcode).joined(separator: ", "))")
                }
            }
            Button("Clear lookup history", role: .destructive) {
                Task {
                    await BarcodeLookupTelemetry.shared.clear()
                    await reloadLookupStats()
                }
            }
            .disabled(lookupEntries.isEmpty)
            Text("Nutrition and ingredients are read on device from the printed label.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func missRateLabel(misses: Int, total: Int) -> String {
        guard total > 0 else { return "0%" }
        let percent = Int((Double(misses) / Double(total) * 100).rounded())
        return "\(percent)%"
    }

    private func uniqueMissedBarcodes(from misses: [BarcodeLookupEntry]) -> [(barcode: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in misses {
            counts[entry.barcode, default: 0] += 1
        }
        return counts
            .map { (barcode: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    private func reloadLookupStats() async {
        lookupEntries = await BarcodeLookupTelemetry.shared.allEntries()
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: notificationStatus = "Allowed"
        case .denied: notificationStatus = "Denied"
        case .notDetermined: notificationStatus = "Not asked yet"
        @unknown default: notificationStatus = "Unknown"
        }
    }
}

nonisolated struct JSONFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
