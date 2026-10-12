//
//  PackageLabelReader.swift
//  StashKeeper
//
//  When a barcode is on the package but Open Food Facts and UPCitemdb have
//  no row for it — the usual case for Indian chocolates and groceries —
//  the name still has to come from the wrapper. This reads the large
//  printed lines on device and ignores MRP, weights, and the barcode digits.
//

import Foundation
import CoreGraphics

nonisolated enum PackageLabelReader {
    static let packageSource = "Read from the package"

    /// GS1 company prefixes that tell us the barcode is local even when
    /// no product database has heard of it.
    static func originNote(for barcode: String) -> String? {
        let digits = barcode.filter(\.isNumber)
        guard digits.count >= 3 else { return nil }
        let prefix = String(digits.prefix(3))
        if prefix == "890" {
            return "GS1 prefix 890: Indian barcode. Product databases often have no entry. Name it from the words printed on the pack."
        }
        return nil
    }

    /// Region OCR plus the full-image read. A tight object box on a
    /// chocolate bar often misses the brand, which the full-image pass still has.
    static func lines(region: [OCRLine], regionBox: CGRect, global: [OCRLine]) -> [OCRLine] {
        let usefulRegion = region.filter { !isNoise($0.text, barcode: nil) }
        var combined = region
        if usefulRegion.count < 2 {
            combined.append(contentsOf: global)
        } else {
            combined.append(contentsOf: global.filter {
                regionBox.intersects($0.boundingBox) || regionBox.contains($0.boundingBox.origin)
            })
        }
        var seen = Set<String>()
        return combined.filter { line in
            let key = line.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { return false }
            return true
        }
    }

    static func product(from lines: [OCRLine], barcode: String?) -> LookedUpProduct? {
        guard let name = displayName(from: lines, barcode: barcode) else { return nil }
        return LookedUpProduct(
            name: name,
            brand: nil,
            category: category(for: name, lines: lines),
            rawNutritionText: nil,
            imageURL: nil,
            source: packageSource,
            wrapperTokens: signature(from: lines)
        )
    }

    /// A catalog title and the words on the wrapper. A learned name stays.
    /// A printed name replaces the catalog title when the wrapper states a
    /// longer product name that still shares a word with the catalog.
    static func merge(catalog: LookedUpProduct, printed: LookedUpProduct) -> LookedUpProduct {
        let name = catalog.source == "Learned on this device"
            ? catalog.name
            : preferredName(catalog: catalog.name, printed: printed.name)
        let usedPrinted = name == printed.name && name != catalog.name
        return LookedUpProduct(
            name: name,
            brand: catalog.brand,
            category: catalog.category ?? printed.category,
            rawNutritionText: catalog.rawNutritionText,
            imageURL: catalog.imageURL,
            source: usedPrinted ? "\(catalog.source) and the package" : catalog.source,
            nutrition: catalog.nutrition,
            ingredients: catalog.ingredients,
            wrapperTokens: printed.wrapperTokens
        )
    }

    static func preferredName(catalog: String, printed: String) -> String {
        let catalogTokens = nameTokens(catalog)
        let printedTokens = nameTokens(printed)
        guard !printedTokens.isEmpty else { return catalog }
        guard !catalogTokens.isEmpty else { return printed }
        if printedTokens.isSubset(of: catalogTokens) { return catalog }
        if catalogTokens.isSubset(of: printedTokens) { return printed }
        let extra = printedTokens.subtracting(catalogTokens)
        if !catalogTokens.intersection(printedTokens).isEmpty, extra.count >= 2 {
            return printed
        }
        return catalog
    }

    /// Distinctive wrapper words used to recognize a pack the household
    /// already confirmed, even when the next photo misses the barcode.
    static func signature(from lines: [OCRLine]) -> [String] {
        let ranked = lines
            .filter { !isNoise($0.text, barcode: nil) }
            .sorted { $0.relativeHeight > $1.relativeHeight }
            .prefix(4)
        return signature(fromTexts: ranked.map(\.text))
    }

    static func signature(fromTexts texts: [String]) -> [String] {
        var tokens: [String] = []
        var seen = Set<String>()
        for text in texts {
            for raw in text.split(whereSeparator: { !$0.isLetter }) {
                let token = String(raw).folding(options: .diacriticInsensitive, locale: .current).lowercased()
                guard token.count >= 4, !genericSignatureTokens.contains(token), seen.insert(token).inserted else { continue }
                tokens.append(token)
                if tokens.count == 4 { return tokens }
            }
        }
        return tokens
    }

    private static let genericSignatureTokens: Set<String> = [
        "milk", "biscuit", "biscuits", "cookie", "cookies", "chocolate", "snack", "snacks",
        "noodle", "noodles", "masala", "cream", "butter", "sugar", "wheat", "flour",
        "pack", "india", "limited", "foods", "food", "fresh", "original", "classic",
        "with", "from", "made", "best", "weight", "grams", "good"
    ]

    private static func nameTokens(_ text: String) -> Set<String> {
        Set(
            text.split(whereSeparator: { !$0.isLetter })
                .map { String($0).lowercased() }
                .filter { $0.count >= 3 }
        )
    }

    static func displayName(from lines: [OCRLine], barcode: String?) -> String? {
        let ranked = lines
            .map { (line: $0, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !isNoise($0.text, barcode: barcode) && $0.text.count >= 2 }
            .sorted { $0.line.relativeHeight > $1.line.relativeHeight }
        guard let headline = ranked.first else { return nil }

        let parts = ranked.prefix(4).filter { candidate in
            candidate.line.relativeHeight >= headline.line.relativeHeight * 0.55
                || (candidate.line.confidence >= 0.75 && candidate.text.count >= 3)
        }.prefix(3)

        let name = parts.map { prettify($0.text) }.joined(separator: " ")
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }
        return trimmed
    }

    static func isNoise(_ text: String, barcode: String?) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let lower = trimmed.lowercased()
        let digits = trimmed.filter(\.isNumber)
        if digits.count >= 8, digits.count + 2 >= trimmed.count { return true }
        if let barcode {
            let code = barcode.filter(\.isNumber)
            if !code.isEmpty, digits == code { return true }
        }

        let markers = [
            "mrp", "fssai", "net wt", "net weight", "net qty", "net quantity",
            "best before", "use by", "expiry", "exp date", "mfg", "pkd", "batch",
            "ingredient", "contains", "allergen", "customer care", "manufactured",
            "marketed by", "www.", "http", "incl. of", "inclusive of", "lic.",
            "license", "store in", "keep in", "refrigerat", "consumer care",
            "for feedback", "e-mail", "email", "rs.", "rs ", "₹"
        ]
        if markers.contains(where: { lower.contains($0) }) { return true }
        if lower == "veg" || lower == "non veg" || lower == "non-veg" { return true }
        return false
    }

    private static func prettify(_ text: String) -> String {
        let letters = text.filter(\.isLetter)
        guard letters.count >= 3, text == text.uppercased() else { return text }
        return text.lowercased().capitalized
    }

    private static func category(for name: String, lines: [OCRLine]) -> String {
        let blob = (name + " " + lines.map(\.text).joined(separator: " ")).lowercased()
        if blob.contains("chocolate") || blob.contains("cocoa") || blob.contains("choco")
            || blob.contains("candy") || blob.contains("wafer")
            || blob.contains("dairy milk") || blob.contains("bournville") {
            return "Pantry & Food"
        }
        if blob.contains("milk") || blob.contains("dahi") || blob.contains("curd")
            || blob.contains("paneer") || blob.contains("butter") || blob.contains("ghee") {
            return "Dairy"
        }
        if blob.contains("biscuit") || blob.contains("cookie") || blob.contains("snack")
            || blob.contains("namkeen") || blob.contains("noodle") {
            return "Pantry & Food"
        }
        return "Pantry & Food"
    }
}
