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
                guard url.startAccessingSecurityScopedResource() else {
                    statusMessage = "Couldn't read the selected file."
                    return
                }
                defer { url.stopAccessingSecurityScopedResource() }
                do {
                    let data = try Data(contentsOf: url)
                    let count = try InventoryExport.importBackup(data, into: modelContext)
                    statusMessage = "Imported \(count) new item\(count == 1 ? "" : "s")."
                    reloadWidgets()
                } catch {
                    statusMessage = "Import failed: \(error.localizedDescription)"
                }
            case .failure(let error):
                statusMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var barcodeLookupSection: some View {
        let misses = lookupEntries.filter { $0.outcome == .miss }
        let hits = lookupEntries.count - misses.count
        Section("Barcode lookup") {
            if lookupEntries.isEmpty {
                Text("No scans recorded yet. Each barcode lookup is kept on this device so you can see whether misses come from the product databases.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Recorded lookups", value: "\(lookupEntries.count)")
                LabeledContent("Hits", value: "\(hits)")
                LabeledContent("Misses", value: "\(misses.count)")
                LabeledContent("Miss rate", value: missRateLabel(misses: misses.count, total: lookupEntries.count))
                let missedBarcodes = uniqueMissedBarcodes(from: misses)
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
