//
//  LocationsListView.swift
//  StashKeeper
//
//  Browse all storage locations and drill into each one to see what's kept
//  there.
//

import SwiftUI
import SwiftData

struct LocationsListView: View {

    @Query(sort: \StorageLocation.sortIndex) private var locations: [StorageLocation]
    @Environment(\.modelContext) private var modelContext
    @State private var showingAddLocation = false

    var body: some View {
        List {
            ForEach(locations) { location in
                NavigationLink {
                    LocationDetailView(location: location)
                } label: {
                    HStack {
                        Image(systemName: location.iconSystemName)
                            .foregroundStyle(.blue)
                            .frame(width: 28)
                        VStack(alignment: .leading) {
                            Text(location.name)
                            Text(locationCaption(location))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete(perform: deleteLocations)
            .onMove(perform: moveLocations)
        }
        .navigationTitle("Locations")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddLocation = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add location")
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
            #endif
        }
        .sheet(isPresented: $showingAddLocation) {
            AddLocationSheet()
                .sheetPopIn()
        }
        .overlay {
            if locations.isEmpty {
                ContentUnavailableView(
                    "No Locations Yet",
                    systemImage: "archivebox",
                    description: Text("Locations are created automatically when you add items, or you can add one manually.")
                )
            }
        }
    }

    private func locationCaption(_ location: StorageLocation) -> String {
        let count = "\(location.items.count) item\(location.items.count == 1 ? "" : "s")"
        if let parent = location.parent {
            return "In \(parent.name) · \(count)"
        }
        return count
    }

    private func deleteLocations(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(locations[index])
        }
        try? modelContext.save()
    }

    private func moveLocations(from source: IndexSet, to destination: Int) {
        var ordered = locations
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, location) in ordered.enumerated() {
            location.sortIndex = index
        }
        try? modelContext.save()
    }
}

struct LocationDetailView: View {
    @Bindable var location: StorageLocation
    @Query(sort: \StorageLocation.sortIndex) private var allLocations: [StorageLocation]
    @Namespace private var heroNamespace

    var body: some View {
        List {
            Section("Place") {
                TextField("Name", text: $location.name)
                Picker("Inside", selection: parentBinding) {
                    Text("None").tag(Optional<UUID>.none)
                    ForEach(parentChoices) { candidate in
                        Text(candidate.fullPath).tag(Optional(candidate.id))
                    }
                }
            }
            ForEach(location.items) { item in
                NavigationLink {
                    ItemDetailView(item: item, heroNamespace: heroNamespace)
                } label: {
                    ItemRow(item: item)
                }
                #if os(iOS)
                .matchedTransitionSource(id: item.id, in: heroNamespace)
                #endif
                .itemRowInteractions(for: item)
            }
        }
        .navigationTitle(location.name)
        .onChange(of: location.name) { old, new in
            if new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                location.name = old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : old
            }
        }
        .overlay {
            if location.items.isEmpty {
                ContentUnavailableView(
                    "Nothing Kept Here Yet",
                    systemImage: location.iconSystemName
                )
            }
        }
    }

    private var parentChoices: [StorageLocation] {
        allLocations.filter { candidate in
            candidate.id != location.id && !candidate.isUnder(location)
        }
    }

    private var parentBinding: Binding<UUID?> {
        Binding(
            get: { location.parent?.id },
            set: { newID in
                location.parent = allLocations.first { $0.id == newID }
            }
        )
    }
}

private struct AddLocationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var icon = "archivebox"

    private let iconOptions: [(name: String, symbol: String)] = [
        ("Box", "archivebox"),
        ("Cabinet", "cabinet"),
        ("Fridge", "refrigerator"),
        ("Medicine", "cross.case"),
        ("Car", "car"),
        ("Bedroom", "bed.double"),
        ("Table", "table.furniture"),
        ("Shipping Box", "shippingbox")
    ]

    var body: some View {
        NavigationStack {
            Form {
                TextField("Location Name", text: $name)
                Picker("Icon", selection: $icon) {
                    ForEach(iconOptions, id: \.symbol) { option in
                        Label(option.name, systemImage: option.symbol).tag(option.symbol)
                    }
                }
                .pickerStyle(.inline)
            }
            .navigationTitle("New Location")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let location = StorageLocation(name: name, iconSystemName: icon)
                        modelContext.insert(location)
                        try? modelContext.save()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

#Preview {
    NavigationStack { LocationsListView() }
        .modelContainer(for: [StashItem.self, StorageLocation.self, StreakRecord.self], inMemory: true)
}
