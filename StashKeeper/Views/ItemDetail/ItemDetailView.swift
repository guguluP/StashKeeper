//
//  ItemDetailView.swift
//  StashKeeper
//
//  Full detail + edit screen for a single item. Lets the user correct
//  AI-derived fields (which feeds back into notification scheduling) and
//  delete the item.
//

import SwiftUI
import SwiftData

struct ItemDetailView: View {

    @Bindable var item: StashItem
    var heroNamespace: Namespace.ID
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \StorageLocation.name) private var locations: [StorageLocation]

    @State private var showingDeleteConfirm = false
    @State private var showFullFields = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    PhotoCarouselView(item: item, size: 160)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)
            .opacity(showFullFields ? 1 : 0)
            .scaleEffect(showFullFields ? 1 : 0.9)

            Section("Item") {
                TextField("Name", text: $item.name)
                Picker("Category", selection: $item.category) {
                    ForEach(ItemAnalysis.categoryOptions, id: \.self) { Text($0).tag($0) }
                }
                TextField("Subcategory", text: Binding(
                    get: { item.subcategory ?? "" },
                    set: { item.subcategory = $0.isEmpty ? nil : $0 }
                ))
                Stepper("Quantity: \(item.quantity)", value: $item.quantity, in: 1...999)
            }

            Section("Location") {
                Picker("Location", selection: $item.location) {
                    Text("None").tag(StorageLocation?.none)
                    ForEach(locations) { location in
                        Text(location.name).tag(StorageLocation?.some(location))
                    }
                }
            }

            Section("Price") {
                HStack {
                    Picker("Currency", selection: Binding(
                        get: { item.priceCurrency ?? "INR" },
                        set: { item.priceCurrency = $0 }
                    )) {
                        ForEach(["INR", "USD", "EUR", "GBP", "AUD", "CAD"], id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()

                    TextField("Amount", value: Binding(
                        get: { item.priceAmount ?? 0 },
                        set: { item.priceAmount = $0 == 0 ? nil : $0 }
                    ), format: .number)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                }
                if item.priceDetectedAutomatically {
                    Label("Detected from price tag in photo", systemImage: "tag")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            if let barcodePayload = item.barcodePayload {
                Section("Barcode") {
                    HStack {
                        Image(systemName: "barcode.viewfinder")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(barcodePayload)
                                .font(.system(.body, design: .monospaced))
                            if let source = item.barcodeLookupSource {
                                Text("Matched via \(source)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Perishability") {
                Toggle("Perishable", isOn: $item.isPerishable)
                if item.isPerishable {
                    DatePicker(
                        "Expiry Date",
                        selection: Binding(
                            get: { item.expiryDate ?? .now },
                            set: { item.expiryDate = $0; item.expiryUserConfirmed = true }
                        ),
                        displayedComponents: .date
                    )

                    HStack {
                        Image(systemName: item.expiryStatus.systemImage)
                            .foregroundStyle(item.expiryStatus.tint)
                        Text(item.expiryStatus.label)
                            .foregroundStyle(item.expiryStatus.tint)
                        Spacer()
                        if let days = item.daysUntilExpiry {
                            Text(days < 0 ? "\(-days)d ago" : "\(days)d left")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let confidence = item.expiryConfidence, !item.expiryUserConfirmed {
                        Label(
                            confidence < 0.6 ? "AI estimate — please confirm" : "AI-detected from packaging",
                            systemImage: confidence < 0.6 ? "questionmark.circle" : "checkmark.seal"
                        )
                        .font(.caption)
                        .foregroundStyle(confidence < 0.6 ? .orange : .green)
                    }
                }
            }

            if !item.tags.isEmpty {
                Section("Tags") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(item.tags, id: \.self) { tag in
                                BadgeLabel(text: tag)
                            }
                        }
                    }
                }
            }

            if item.hasNutrition {
                Section("Nutrition" + (item.nutritionServingSize.map { " (per \($0))" } ?? "")) {
                    if let calories = item.nutritionCalories {
                        nutritionRow("Calories", "\(calories) kcal")
                    }
                    if let protein = item.nutritionProteinGrams {
                        nutritionRow("Protein", "\(formattedGrams(protein))g")
                    }
                    if let carbs = item.nutritionCarbsGrams {
                        nutritionRow("Carbohydrates", "\(formattedGrams(carbs))g")
                    }
                    if let sugar = item.nutritionSugarGrams {
                        nutritionRow("Sugars", "\(formattedGrams(sugar))g")
                    }
                    if let fat = item.nutritionFatGrams {
                        nutritionRow("Fat", "\(formattedGrams(fat))g")
                    }
                    if let fiber = item.nutritionFiberGrams {
                        nutritionRow("Fiber", "\(formattedGrams(fiber))g")
                    }
                    if let sodium = item.nutritionSodiumMilligrams {
                        nutritionRow("Sodium", "\(formattedGrams(sodium))mg")
                    }

                    #if os(iOS)
                    // Manual only — HealthKit models consumption, not pantry stock.
                    Button {
                        Task {
                            try? await HealthKitService.shared.requestAuthorizationIfNeeded()
                            let synced = await HealthKitService.shared.logNutrition(for: item)
                            if synced { StashHaptics.success() }
                            withAnimation(.stashSpring) { item.healthKitSynced = synced }
                        }
                    } label: {
                        Label(
                            item.healthKitSynced ? "Logged to Health" : "Log nutrition to Health",
                            systemImage: item.healthKitSynced ? "checkmark.circle.fill" : "heart.text.square"
                        )
                    }
                    .foregroundStyle(item.healthKitSynced ? .green : .accentColor)
                    .disabled(item.healthKitSynced)

                    if !item.healthKitSynced {
                        Text("Health only tracks food you consume. Use this when you've eaten this item (or accept logging storage as an estimate).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    #endif
                }
            }

            Section("Notes") {
                TextField("Add notes…", text: Binding(
                    get: { item.notes ?? "" },
                    set: { item.notes = $0.isEmpty ? nil : $0 }
                ), axis: .vertical)
                .lineLimit(3...6)
            }

            if let recognizedText = item.recognizedText, !recognizedText.isEmpty {
                Section("Text Found on Item") {
                    Text(recognizedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Delete Item", role: .destructive) {
                    StashHaptics.impact()
                    showingDeleteConfirm = true
                }
            }
        }
        .navigationTitle(item.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTransition(.zoom(sourceID: item.id, in: heroNamespace))
        #endif
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8).delay(0.05)) {
                showFullFields = true
            }
        }
        .onChange(of: item.isPerishable) { _, _ in Task { await resync() } }
        .onChange(of: item.expiryDate) { _, _ in Task { await resync() } }
        .onDisappear {
            try? modelContext.save()
        }
        .confirmationDialog(
            "Delete this item?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteItem()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func resync() async {
        await ExpiryEngine.shared.syncNotifications(for: item)
    }

    private func nutritionRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func formattedGrams(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    private func deleteItem() {
        StashItemLifecycle.delete(item, from: modelContext)
        StashHaptics.success()
        dismiss()
    }
}

#Preview {
    let container = try! ModelContainer(
        for: StashItem.self, StorageLocation.self,
        configurations: .init(isStoredInMemoryOnly: true)
    )
    let sample = StashItem(name: "Milk", category: "Beverages", isPerishable: true, expiryDate: .now.addingTimeInterval(86400 * 3))
    container.mainContext.insert(sample)
    return PreviewHeroWrapper(item: sample)
        .modelContainer(container)
}

private struct PreviewHeroWrapper: View {
    let item: StashItem
    @Namespace private var namespace
    var body: some View {
        NavigationStack { ItemDetailView(item: item, heroNamespace: namespace) }
    }
}
