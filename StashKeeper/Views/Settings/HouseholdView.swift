//
//  HouseholdView.swift
//  StashKeeper
//
//  Another person gets a copy of the catalog by receiving the JSON file
//  and importing it. Live multi-device sync needs CloudKit, which this
//  app's entitlements do not include.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct HouseholdView: View {
    @Query private var items: [StashItem]
    @Query private var locations: [StorageLocation]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayMetrics) private var metrics

    @State private var exportDocument = JSONFile(data: Data())
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section {
                Text("Send your stash to someone else as a file. Import adds new items and places, and updates items that share an id. Photos already on this device stay here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Devices signed into this iCloud account share the stash when iCloud is enabled for StashKeeper. A file is still how you hand a copy to someone else. Photos stay on the device that took them. Quantity changes record the household name from Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section("Share") {
                Button("Prepare stash file") {
                    do {
                        exportDocument.data = try InventoryExport.makeBackup(items: items, locations: locations)
                        showingExporter = true
                    } catch {
                        statusMessage = error.localizedDescription
                    }
                }
                Button("Import a household file") {
                    showingImporter = true
                }
            }
            if let statusMessage {
                Section {
                    Text(statusMessage)
                }
            }
        }
        .navigationTitle("Household")
        .frame(maxWidth: metrics.readableWidth)
        .frame(maxWidth: .infinity)
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "StashKeeper-household"
        ) { result in
            if case .failure(let error) = result {
                statusMessage = error.localizedDescription
            } else {
                statusMessage = "File ready to send."
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
                    statusMessage = "Added \(result.inserted) new item\(result.inserted == 1 ? "" : "s"), updated \(result.updated)."
                    Task {
                        let fetched = (try? modelContext.fetch(FetchDescriptor<StashItem>())) ?? items
                        await ExpiryEngine.shared.resyncAll(items: fetched)
                        try? modelContext.save()
                        reloadWidgets()
                    }
                } catch {
                    statusMessage = error.localizedDescription
                }
            case .failure(let error):
                statusMessage = error.localizedDescription
            }
        }
    }
}
