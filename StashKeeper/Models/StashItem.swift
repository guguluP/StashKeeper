//
//  StashItem.swift
//  StashKeeper
//
//  The core persisted entity: something the user has stored somewhere,
//  with AI-derived metadata (category, perishability, expiry estimate).
//

import Foundation
import SwiftData
import SwiftUI

nonisolated private final class FormatterCache: @unchecked Sendable {
    let cache = NSCache<NSString, NumberFormatter>()
}

@Model
final class StashItem {

    // MARK: Identity

    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date

    // MARK: User / AI derived facts

    /// Human readable name, e.g. "AA Batteries", "Passport", "Basmati Rice"
    var name: String

    /// Broad category, e.g. "Electronics", "Documents", "Pantry", "Tools"
    var category: String

    /// Optional finer-grained subcategory, e.g. "Rechargeable Battery"
    var subcategory: String?

    /// How many of this item / unit of this item are kept at this location.
    var quantity: Int

    /// Free-form unit if relevant ("boxes", "packets", "pairs"). Nil = count of items.
    var unit: String?

    /// Whether Foundation Models judged this item perishable (food, medicine,
    /// cosmetics, batteries with shelf life, etc).
    var isPerishable: Bool

    /// Estimated or user-confirmed expiry date, if perishable.
    var expiryDate: Date?

    /// Confidence (0...1) the model had in the expiry estimate — used to decide
    /// whether to proactively ask the user to confirm it.
    var expiryConfidence: Double?

    /// Whether the user manually corrected the AI's expiry estimate.
    var expiryUserConfirmed: Bool

    /// Free-text notes the user can add.
    var notes: String?

    /// Raw text Vision OCR'd off the item/packaging (e.g. printed expiry, brand name).
    var recognizedText: String?

    /// Tags for search, derived by Foundation Models plus any the user adds.
    var tags: [String]

    // MARK: Price

    /// Price amount, either OCR'd from a visible price tag or entered manually.
    var priceAmount: Double?

    /// ISO 4217 currency code, e.g. "INR", "USD".
    var priceCurrency: String?

    /// Whether the price was detected automatically from a photo (true) or
    /// entered/edited by the user (false) — shown as a subtle provenance hint.
    /// Has a default value so SwiftData can lightweight-migrate existing
    /// records that predate this field without crashing on launch.
    var priceDetectedAutomatically: Bool = false

    // MARK: Barcode

    /// Barcode payload (UPC/EAN/etc) detected on this item, if any.
    var barcodePayload: String?

    /// Which source resolved product info from the barcode, e.g. "Open Food Facts".
    /// Nil if no barcode was found or lookup didn't return a match.
    var barcodeLookupSource: String?

    // MARK: Nutrition

    /// Serving size nutrition figures refer to, e.g. "100g".
    var nutritionServingSize: String?
    var nutritionCalories: Int?
    var nutritionProteinGrams: Double?
    var nutritionCarbsGrams: Double?
    var nutritionSugarGrams: Double?
    var nutritionFatGrams: Double?
    var nutritionFiberGrams: Double?
    var nutritionSodiumMilligrams: Double?

    /// Whether this item's nutrition has already been written to Apple
    /// Health. Persisted (not just view-local @State) so revisiting this
    /// item's detail screen doesn't invite writing a duplicate Health
    /// sample — HealthKit has no natural "upsert" semantics for these
    /// writes, so preventing the repeat write at the source is important.
    var healthKitSynced: Bool = false

    // MARK: Relationships

    /// The location this item is stored in.
    var location: StorageLocation?

    /// Filenames of stored photos, relative to the app's photo storage directory.
    var photoFilenames: [String]

    // MARK: Notification bookkeeping

    /// IDs of scheduled UNNotificationRequests for this item, so we can cancel/update them.
    var scheduledNotificationIDs: [String]

    /// Whether an "expired" notification has already fired, to avoid duplicates.
    var expiredNotificationSent: Bool

    init(
        name: String,
        category: String,
        subcategory: String? = nil,
        quantity: Int = 1,
        unit: String? = nil,
        isPerishable: Bool = false,
        expiryDate: Date? = nil,
        expiryConfidence: Double? = nil,
        notes: String? = nil,
        recognizedText: String? = nil,
        tags: [String] = [],
        location: StorageLocation? = nil,
        photoFilenames: [String] = [],
        priceAmount: Double? = nil,
        priceCurrency: String? = nil,
        priceDetectedAutomatically: Bool = false,
        barcodePayload: String? = nil,
        barcodeLookupSource: String? = nil,
        nutrition: NutritionFacts? = nil
    ) {
        self.id = UUID()
        self.createdAt = .now
        self.updatedAt = .now
        self.name = name
        self.category = category
        self.subcategory = subcategory
        self.quantity = quantity
        self.unit = unit
        self.isPerishable = isPerishable
        self.expiryDate = expiryDate
        self.expiryConfidence = expiryConfidence
        self.expiryUserConfirmed = false
        self.notes = notes
        self.recognizedText = recognizedText
        self.tags = tags
        self.location = location
        self.photoFilenames = photoFilenames
        self.scheduledNotificationIDs = []
        self.expiredNotificationSent = false
        self.priceAmount = priceAmount
        self.priceCurrency = priceCurrency
        self.priceDetectedAutomatically = priceDetectedAutomatically
        self.barcodePayload = barcodePayload
        self.barcodeLookupSource = barcodeLookupSource

        if let nutrition, nutrition.calories >= 0 || nutrition.proteinGrams >= 0 || nutrition.carbsGrams >= 0 {
            self.nutritionServingSize = nutrition.servingSize.isEmpty ? nil : nutrition.servingSize
            self.nutritionCalories = nutrition.calories >= 0 ? nutrition.calories : nil
            self.nutritionProteinGrams = nutrition.proteinGrams >= 0 ? nutrition.proteinGrams : nil
            self.nutritionCarbsGrams = nutrition.carbsGrams >= 0 ? nutrition.carbsGrams : nil
            self.nutritionSugarGrams = nutrition.sugarGrams >= 0 ? nutrition.sugarGrams : nil
            self.nutritionFatGrams = nutrition.fatGrams >= 0 ? nutrition.fatGrams : nil
            self.nutritionFiberGrams = nutrition.fiberGrams >= 0 ? nutrition.fiberGrams : nil
            self.nutritionSodiumMilligrams = nutrition.sodiumMilligrams >= 0 ? nutrition.sodiumMilligrams : nil
        }
    }
}

// MARK: - Derived state

extension StashItem {

    enum ExpiryStatus: String {
        case notPerishable
        case fresh
        case expiringSoon   // within warning window
        case expired

        var label: String {
            switch self {
            case .notPerishable: return "N/A"
            case .fresh: return "Fresh"
            case .expiringSoon: return "Expiring Soon"
            case .expired: return "Expired"
            }
        }

        var tint: Color {
            switch self {
            case .notPerishable: return .secondary
            case .fresh: return .green
            case .expiringSoon: return .orange
            case .expired: return .red
            }
        }

        var systemImage: String {
            switch self {
            case .notPerishable: return "shippingbox"
            case .fresh: return "checkmark.circle"
            case .expiringSoon: return "exclamationmark.triangle"
            case .expired: return "xmark.octagon"
            }
        }
    }

    /// Days before expiry we start warning the user.
    static var warningWindowDays: Int { StashSettings.currentWarningWindowDays }

    var expiryStatus: ExpiryStatus {
        guard isPerishable, let expiryDate else { return .notPerishable }
        let now = Date.now
        if expiryDate < now { return .expired }
        let warningThreshold = Calendar.current.date(
            byAdding: .day,
            value: Self.warningWindowDays,
            to: now
        ) ?? now
        return expiryDate <= warningThreshold ? .expiringSoon : .fresh
    }

    var daysUntilExpiry: Int? {
        guard let expiryDate else { return nil }
        let comps = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: .now),
            to: Calendar.current.startOfDay(for: expiryDate)
        )
        return comps.day
    }

    /// Text combined for on-device semantic / keyword search.
    var searchableText: String {
        ([name, category, subcategory, notes, recognizedText, location?.name]
            .compactMap { $0 } + tags)
            .joined(separator: " ")
    }

    /// Formatted price string, e.g. "₹120.00" or "$4.99", using the stored
    /// currency code. Nil if no price has been recorded.
    var formattedPrice: String? {
        guard let priceAmount, let priceCurrency else { return nil }
        return Self.currencyFormatter(for: priceCurrency)
            .string(from: NSNumber(value: priceAmount))
    }

    /// Cached formatters keyed by currency code — creating a NumberFormatter
    /// per access is relatively expensive when rows bind this in lists.
    private static let currencyFormatterCache = FormatterCache()

    private static func currencyFormatter(for currencyCode: String) -> NumberFormatter {
        let key = currencyCode as NSString
        if let cached = currencyFormatterCache.cache.object(forKey: key) {
            return cached
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        currencyFormatterCache.cache.setObject(formatter, forKey: key)
        return formatter
    }

    /// Whether this item has any recorded nutrition information.
    var hasNutrition: Bool {
        nutritionCalories != nil || nutritionProteinGrams != nil || nutritionCarbsGrams != nil
    }

    static func needingAttention(in items: [StashItem]) -> [StashItem] {
        items
            .filter { $0.expiryStatus == .expiringSoon || $0.expiryStatus == .expired }
            .sorted { lhs, rhs in
                (lhs.expiryDate ?? .distantFuture) < (rhs.expiryDate ?? .distantFuture)
            }
    }

    /// Decrement by one unit. Quantity 0 stays as an empty row so widgets
    /// and the assistant can still refer to it; the user deletes explicitly.
    @MainActor
    @discardableResult
    func consumeOneUnit(in context: ModelContext) -> Int {
        quantity = max(0, quantity - 1)
        updatedAt = .now
        try? context.save()
        return quantity
    }

    @MainActor
    func snoozeExpiry(days: Int = 1, in context: ModelContext) {
        let base = expiryDate ?? .now
        expiryDate = Calendar.current.date(byAdding: .day, value: days, to: base) ?? base
        expiryUserConfirmed = true
        isPerishable = true
        updatedAt = .now
        try? context.save()
    }

    var expiryCaption: String {
        guard isPerishable, let days = daysUntilExpiry else { return "" }
        if days < 0 { return "Expired \(-days)d ago" }
        if days == 0 { return "Expires today" }
        if days == 1 { return "Expires tomorrow" }
        return "\(days)d left"
    }
}
