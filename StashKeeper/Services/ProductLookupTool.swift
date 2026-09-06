//
//  ProductLookupTool.swift
//  StashKeeper
//
//  A Foundation Models Tool that lets the model actively resolve a barcode
//  against online product databases mid-reasoning, rather than only ever
//  seeing lookup results that were pre-fetched by Swift code before the
//  model ran. This matters most in the assistant chat: a user can type or
//  paste a barcode/UPC number directly ("what is 8901030826829?") without
//  ever having gone through the photo capture flow, and the model can now
//  decide on its own to call this tool to answer instead of guessing or
//  saying it doesn't know.
//
//  Network-backed (via ProductLookupService, the app's only network
//  dependency), so this tool can fail or return nothing — always handled
//  gracefully, matching the "never invent facts" instruction given to
//  every session that holds this tool.
//

import Foundation
import FoundationModels

nonisolated private struct ProductLookupToolResult: Codable, Sendable {
    let found: Bool
    let name: String?
    let brand: String?
    let category: String?
    let nutritionSummary: String?
    let source: String?
    let note: String
}

/// Foundation Models Tool conformance — the model decides when to call
/// this, e.g. when the user mentions a barcode/UPC number, asks "what
/// product is this code", or when confirming a scanned item's identity
/// would benefit from an authoritative lookup rather than a visual guess.
struct ProductLookupTool: Tool {
    let name = "lookupProductByBarcode"
    let description = """
        Looks up a product by its barcode/UPC/EAN number against online
        product databases (Open Food Facts, UPCitemdb, plus a local Indian
        FMCG cache). Use this when the user provides or references a
        barcode number directly, or when you need authoritative grounding
        for a product's real name/brand/category/nutrition beyond what's
        visually apparent. Only pass digits — strip any spaces or
        formatting from the barcode first. Returns "not found" gracefully
        if no database has this code; don't treat that as an error, just
        tell the user honestly that this specific code wasn't found.
        """

    private let lookupService = ProductLookupService()

    @Generable
    struct Arguments {
        @Guide(description: "The barcode/UPC/EAN number, digits only, e.g. '8901030826829'.")
        var barcode: String
    }

    func call(arguments: Arguments) async throws -> String {
        let cleaned = arguments.barcode.filter(\.isNumber)
        guard !cleaned.isEmpty else {
            return Self.encode(ProductLookupToolResult(
                found: false, name: nil, brand: nil, category: nil,
                nutritionSummary: nil, source: nil,
                note: "No valid barcode digits were provided."
            ))
        }

        guard let product = await lookupService.lookup(barcode: cleaned) else {
            return Self.encode(ProductLookupToolResult(
                found: false, name: nil, brand: nil, category: nil,
                nutritionSummary: nil, source: nil,
                note: "No product database has this barcode on file. Tell the user honestly rather than guessing a product identity."
            ))
        }

        return Self.encode(ProductLookupToolResult(
            found: true,
            name: product.name,
            brand: product.brand,
            category: product.category,
            nutritionSummary: product.rawNutritionText,
            source: product.source,
            note: "Grounded result from \(product.source). Treat as authoritative for name/brand/category."
        ))
    }

    private static func encode(_ result: ProductLookupToolResult) -> String {
        let encoder = JSONEncoder()
        let data = (try? encoder.encode(result)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "Lookup unavailable."
    }
}
