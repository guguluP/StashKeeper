//
//  ReceiptModels.swift
//  StashKeeper
//
//  Structured output shapes for parsing a photographed supermarket
//  receipt/bill into individual line items, following the same
//  @Generable / @Guide guided-generation pattern ItemAnalysis.swift uses
//  for photo-based item detection. Unlike ItemAnalysis (grounded in a
//  Vision-detected region of a photographed physical object), a receipt
//  line item is grounded in one line of OCR text from a dense printed
//  bill — there's no bounding box on a real object here, just a row in a
//  list, so this intentionally does not reuse RegionAnalysisInput.
//

import Foundation
import FoundationModels

/// One parsed line item from a receipt. Deliberately minimal compared to
/// `ItemAnalysis` — a receipt only ever tells you a name, a quantity, and
/// a price; anything else (category, expiry, nutrition) still has to come
/// from actually looking at the physical item later, which is why this
/// flow hands off to the existing photo-based Add Item pipeline afterward
/// rather than trying to catalog straight from receipt text alone.
@Generable
struct ReceiptLineItem: Equatable {
    @Guide(description: "The product name as it would sensibly appear to a shopper, cleaned up from the receipt's often-abbreviated printed text (e.g. expand 'TOM SC 1KG' to 'Tomatoes 1kg' if confident, but don't invent details that aren't implied by the abbreviation). Title case. If the abbreviation is too cryptic to confidently expand, keep it close to the original printed text rather than guessing wildly.")
    var name: String

    @Guide(description: "Quantity purchased, as a whole number. Default to 1 if the line doesn't show a quantity or shows a weight/volume instead of a count (e.g. '1kg' of loose produce is quantity 1, not 1000).")
    var quantity: Int

    @Guide(description: "Unit price or line total as printed, as a plain numeric string with up to 2 decimals, e.g. '45.00'. Prefer the line's total price over a per-unit price if both are shown. Empty string if no price is legible for this line.")
    var priceAmount: String

    @Guide(description: "One broad category guess for this item, used only to help the user sort through the list — not a final categorization.", .anyOf(itemCategoryOptions))
    var category: String
}

/// Batch result for one photographed receipt.
@Generable
struct ReceiptExtraction: Equatable {
    @Guide(description: "The store/supermarket name as printed at the top of the receipt, if legible. Empty string if not visible or illegible.")
    var storeName: String

    @Guide(description: "The purchase date as printed on the receipt, as an ISO-8601 date string (YYYY-MM-DD) if legible. Empty string if not visible.")
    var purchaseDateISO: String

    @Guide(description: "One entry per distinct purchased item line found on the receipt. Skip subtotal, tax, discount, and total lines — those are not products. Skip loyalty program text, payment method lines, and store contact info.")
    var items: [ReceiptLineItem]

    @Guide(description: "Currency code for all prices on this receipt, e.g. 'INR', 'USD'. Infer from currency symbols/markers present anywhere on the receipt.")
    var currency: String
}

extension ReceiptExtraction {
    var purchaseDate: Date? {
        guard !purchaseDateISO.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: purchaseDateISO)
    }
}

extension ReceiptLineItem {
    var price: Double? {
        guard !priceAmount.isEmpty else { return nil }
        return Double(priceAmount)
    }
}
