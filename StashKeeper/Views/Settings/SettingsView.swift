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
        .task { await refreshNotificationStatus() }
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
