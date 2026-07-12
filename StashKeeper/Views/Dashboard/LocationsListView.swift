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

    @Query(sort: \StorageLocation.name) private var locations: [StorageLocation]
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
                            Text("\(location.items.count) item\(location.items.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete(perform: deleteLocations)
        }
        .navigationTitle("Locations")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddLocation = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddLocation) {
            AddLocationSheet()
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

    private func deleteLocations(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(locations[index])
        }
        try? modelContext.save()
    }
}

struct LocationDetailView: View {
    @Bindable var location: StorageLocation
    @Namespace private var heroNamespace

    var body: some View {
        List {
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
        .overlay {
            if location.items.isEmpty {
                ContentUnavailableView(
                    "Nothing Kept Here Yet",
                    systemImage: location.iconSystemName
                )
            }
        }
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
