//
//  ItemCandidateEditView.swift
//  StashKeeper
//
//  Edit sheet for a single detected item candidate before it's saved.
//  Reused both from the bounding-box overlay (tap the pencil on a box) and
//  from the final per-item review list. Lets the user review/correct
//  AI-detected price, barcode-resolved product info, and nutrition facts
//  alongside the core item fields.
//

import SwiftUI
import SwiftData

struct ItemCandidateEditView: View {

    @Binding var analysis: ItemAnalysis
    @Binding var quantity: Int
    @Binding var selectedLocation: StorageLocation?
    @Binding var newLocationName: String
    @Binding var expiryDate: Date
    @Binding var price: (amount: Double, currency: String, autoDetected: Bool)?
    var barcodePayload: String?
    var barcodeLookupSource: String?
    let recognizedText: [String]

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \StorageLocation.name) private var locations: [StorageLocation]

    @State private var priceText: String = ""
    @State private var priceCurrency: String = "INR"

    private let currencyOptions = ["INR", "USD", "EUR", "GBP", "AUD", "CAD"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Item") {
                    TextField("Name", text: $analysis.name)
                    Picker("Category", selection: $analysis.category) {
                        ForEach(ItemAnalysis.categoryOptions, id: \.self) { Text($0).tag($0) }
                    }
                    if analysis.categoryConfidence > 0, analysis.categoryConfidence < 0.5 {
                        Label("Low confidence — please double check", systemImage: "questionmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    TextField("Subcategory (optional)", text: $analysis.subcategory)
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1...999)
                }

                if !analysis.possibleDuplicateNote.isEmpty {
                    Section {
                        Label(analysis.possibleDuplicateNote, systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }

                if barcodePayload != nil {
                    Section("Barcode") {
                        HStack {
                            Image(systemName: "barcode.viewfinder")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(barcodePayload ?? "")
                                    .font(.system(.body, design: .monospaced))
                                if let barcodeLookupSource {
                                    Text("Matched via \(barcodeLookupSource)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("No online match found")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Location") {
                    Picker("Existing Location", selection: $selectedLocation) {
                        Text("None").tag(StorageLocation?.none)
                        ForEach(locations) { location in
                            Text(location.name).tag(StorageLocation?.some(location))
                        }
                    }
                    TextField("Or create new location", text: $newLocationName)
                }

                Section("Perishability") {
                    Toggle("This item is perishable", isOn: $analysis.isPerishable)
                    if analysis.isPerishable {
                        DatePicker("Expiry Date", selection: $expiryDate, displayedComponents: .date)
                        if analysis.expiryConfidence < 0.6 {
                            Label("Estimated — please confirm this date", systemImage: "questionmark.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("Price") {
                    HStack {
                        Picker("Currency", selection: $priceCurrency) {
                            ForEach(currencyOptions, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()

                        TextField("Amount", text: $priceText)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                    if price?.autoDetected == true {
                        Label("Detected from price tag in photo", systemImage: "tag")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                .onChange(of: priceText) { _, newValue in
                    if let amount = Double(newValue) {
                        price = (amount, priceCurrency, price?.autoDetected ?? false)
                    } else if newValue.isEmpty {
                        price = nil
                    }
                }
                .onChange(of: priceCurrency) { _, newValue in
                    if let amount = price?.amount {
                        price = (amount, newValue, price?.autoDetected ?? false)
                    }
                }

                if analysis.hasUsableNutrition {
                    Section("Nutrition" + (analysis.nutrition.servingSize.isEmpty ? "" : " (per \(analysis.nutrition.servingSize))")) {
                        if analysis.nutrition.calories >= 0 {
                            nutritionRow("Calories", "\(analysis.nutrition.calories) kcal")
                        }
                        if analysis.nutrition.proteinGrams >= 0 {
                            nutritionRow("Protein", "\(formatted(analysis.nutrition.proteinGrams))g")
                        }
                        if analysis.nutrition.carbsGrams >= 0 {
                            nutritionRow("Carbohydrates", "\(formatted(analysis.nutrition.carbsGrams))g")
                        }
                        if analysis.nutrition.sugarGrams >= 0 {
                            nutritionRow("Sugars", "\(formatted(analysis.nutrition.sugarGrams))g")
                        }
                        if analysis.nutrition.fatGrams >= 0 {
                            nutritionRow("Fat", "\(formatted(analysis.nutrition.fatGrams))g")
                        }
                        if analysis.nutrition.fiberGrams >= 0 {
                            nutritionRow("Fiber", "\(formatted(analysis.nutrition.fiberGrams))g")
                        }
                        if analysis.nutrition.sodiumMilligrams >= 0 {
                            nutritionRow("Sodium", "\(formatted(analysis.nutrition.sodiumMilligrams))mg")
                        }
                        Text("Estimated by Apple Intelligence — always check packaging for exact values.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if !analysis.ripenessNote.isEmpty {
                    Section("Freshness") {
                        Text(analysis.ripenessNote)
                            .font(.subheadline)
                    }
                }

                if !analysis.tags.isEmpty {
                    Section("Tags") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(analysis.tags, id: \.self) { tag in
                                    BadgeLabel(text: tag)
                                }
                            }
                        }
                    }
                }

                if !recognizedText.isEmpty {
                    Section("Text Found") {
                        Text(recognizedText.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Edit Item")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                if let price {
                    priceText = String(format: "%.2f", price.amount)
                    priceCurrency = price.currency
                }
            }
        }
    }

    private func nutritionRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func formatted(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }
}
