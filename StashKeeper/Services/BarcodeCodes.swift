//
//  BarcodeCodes.swift
//  StashKeeper
//
//  A scan is often not the bare GTIN. Indian packs put the same number in
//  an EAN-13, a GS1 Digital Link QR (`/01/0890…`), or an element string
//  `(01)890…`. Catalogs only answer the digit form.
//

import Foundation

nonisolated enum BarcodeCodes {
    /// Codes worth asking a product database about, most specific first.
    static func candidates(from raw: String) -> [String] {
        var codes: [String] = []

        func add(_ value: String) {
            let digits = value.filter(\.isNumber)
            guard (8...14).contains(digits.count), !codes.contains(digits) else { return }
            codes.append(digits)
        }

        if let gtin = firstCapture(#"/01/(\d{8,14})"#, in: raw) {
            add(gtin)
        }
        if let gtin = firstCapture(#"\(01\)(\d{8,14})"#, in: raw) {
            add(gtin)
        }

        let onlyDigits = raw.filter(\.isNumber)
        if (8...14).contains(onlyDigits.count) {
            add(onlyDigits)
        }

        for code in codes {
            if code.count == 14, code.hasPrefix("0") {
                add(String(code.dropFirst()))
            }
            if code.count == 12 {
                add("0" + code)
            }
        }
        return codes
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }
}

nonisolated enum OpenFactsNaming {
    static func compose(
        productName: String?,
        productNameEn: String?,
        productNameHi: String?,
        genericName: String?,
        abbreviatedName: String?,
        brands: String?,
        quantity: String?
    ) -> String? {
        let primary = [productNameEn, productName, productNameHi, abbreviatedName].compactMap { cleaned($0) }
        guard var name = primary.max(by: { $0.count < $1.count }) ?? cleaned(genericName) else { return nil }
        if name == name.lowercased() {
            name = name.localizedCapitalized
        }

        if let brand = cleaned(brands?.split(separator: ",").first.map(String.init)),
           !brand.isEmpty,
           !name.localizedCaseInsensitiveContains(brand) {
            name = "\(brand) \(name)"
        }
        if let quantity = cleaned(quantity),
           !name.localizedCaseInsensitiveContains(quantity) {
            name = "\(name) \(quantity)"
        }
        return name
    }

    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
