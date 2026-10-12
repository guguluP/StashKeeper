//
//  NutritionLabelReader.swift
//  StashKeeper
//
//  Create ML word tagger for the nutrition panel and the ingredient list.
//  The model labels each word (energy, protein, value, ingredient, and so
//  on). This file turns those labels into the nutrition fields the item
//  already stores, plus the ingredient text. A line of price, tax, or
//  legal print is trained as "other" and does not become a nutrient.
//

import Foundation
import NaturalLanguage

enum NutritionBasis: String, Sendable, Equatable {
    /// The column Indian packs are required to print. This is the default.
    case per100Grams
    /// The serving column, used only when the review screen asks for it.
    case perServing
}

struct NutritionLabelRead: Sendable, Equatable {
    var nutrition: NutritionFacts
    var ingredients: String
    /// How many of the seven stored nutrient fields were filled.
    var nutrientCount: Int
    var basis: NutritionBasis = .per100Grams
    /// The other printed column, when the panel has both.
    var alternate: NutritionFacts? = nil
}

enum NutritionLabelReader {

    private static let scheme = NLTagScheme(rawValue: "NutritionLabel")
    private static let model: NLModel? = {
        let bundle = Bundle(for: NutritionLabelBundleToken.self)
        guard let url = bundle.url(forResource: "NutritionLabelTagger", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "NutritionLabelTagger", withExtension: "mlmodelc") else {
            return nil
        }
        return try? NLModel(contentsOf: url)
    }()

    /// A nutrient row with two amounts is a per-100 g column beside a
    /// per-serving column. The word tagger keeps one number and can keep
    /// the wrong one, so the caller leaves those panels to Apple Intelligence.
    static func containsTwoValueColumns(_ lines: [String]) -> Bool {
        let numberPattern = /\d+(?:[.,]\d+)?/
        let nutrientWords = [
            "energy", "calor", "protein", "fat", "carb", "sugar", "fibre", "fiber", "sodium",
            "ऊर्जा", "कैलोरी", "प्रोटीन", "वसा", "कार्बोहाइड्रेट", "शर्करा", "फाइबर", "सोडियम"
        ]
        return lines.contains { line in
            let lower = line.lowercased()
            guard nutrientWords.contains(where: { lower.contains($0) }) else { return false }
            return line.matches(of: numberPattern).count >= 2
        }
    }

    /// Reads every OCR line. A printed panel is parsed directly so a
    /// per-100 g column is kept beside a per-serving column. The word
    /// tagger runs only when that parse finds nothing. Returns nil when
    /// the panel yielded neither two nutrients nor an ingredient list.
    static func read(_ lines: [String], basis: NutritionBasis = .per100Grams) -> NutritionLabelRead? {
        if let printed = readPrintedPanel(lines, basis: basis) {
            return printed
        }
        guard basis == .per100Grams, model != nil else { return nil }
        return readTagged(lines)
    }

    private static func readTagged(_ lines: [String]) -> NutritionLabelRead? {
        var servingParts: [String] = []
        var ingredients: [String] = []
        var calories = -1
        var protein = -1.0
        var carbs = -1.0
        var sugar = -1.0
        var fat = -1.0
        var fiber = -1.0
        var sodium = -1.0
        var current: String?
        var pendingEnergy: Double?

        for line in lines {
            let tokens = tokenize(line)
            guard !tokens.isEmpty else { continue }
            let labels = tag(tokens)
            let commaSeparated = line.contains(",") && labels.contains("ingredient") && !labels.contains("value")
            var phrase: [String] = []

            func flushPhrase() {
                let text = phrase.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                phrase.removeAll()
                guard text.count >= 2 else { return }
                let lower = text.lowercased()
                guard lower != "ingredients", lower != "contains" else { return }
                ingredients.append(text)
            }

            for (token, label) in zip(tokens, labels) {
                if label == "ingredient" {
                    if commaSeparated { continue }
                    if token == "," {
                        flushPhrase()
                    } else {
                        phrase.append(token)
                    }
                    continue
                }
                flushPhrase()
                switch label {
                case "energy", "protein", "carb", "sugar", "fat", "fiber", "sodium":
                    current = label
                case "value":
                    if let number = Double(token.replacingOccurrences(of: ",", with: ".")) {
                        if current == "energy" { pendingEnergy = number }
                        assign(
                            current,
                            number,
                            calories: &calories,
                            protein: &protein,
                            carbs: &carbs,
                            sugar: &sugar,
                            fat: &fat,
                            fiber: &fiber,
                            sodium: &sodium
                        )
                    }
                    current = nil
                case "unit":
                    if token.lowercased() == "kj", let pendingEnergy {
                        calories = Int((pendingEnergy / 4.184).rounded())
                    }
                    pendingEnergy = nil
                case "serving":
                    if token.lowercased() != "per" {
                        servingParts.append(token)
                    }
                default:
                    break
                }
            }
            flushPhrase()
            if commaSeparated {
                let body = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? line
                let stripped = body.replacingOccurrences(
                    of: #"^(?i)(ingredients|contains)\b"#,
                    with: "",
                    options: .regularExpression
                )
                ingredients.append(contentsOf: stripped.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { $0.count >= 2 })
            }
        }

        let count = [calories >= 0, protein >= 0, carbs >= 0, sugar >= 0, fat >= 0, fiber >= 0, sodium >= 0]
            .filter { $0 }.count
        guard count >= 2 || ingredients.count >= 2 else { return nil }
        let serving = servingParts.joined(separator: " ")
        return NutritionLabelRead(
            nutrition: NutritionFacts(
                servingSize: serving,
                calories: calories,
                proteinGrams: protein,
                carbsGrams: carbs,
                sugarGrams: sugar,
                fatGrams: fat,
                fiberGrams: fiber,
                sodiumMilligrams: sodium
            ),
            ingredients: ingredients.joined(separator: ", "),
            nutrientCount: count
        )
    }

    // MARK: - Printed panel

    /// Indian labels print per 100 g beside per serving, sometimes with a
    /// % RDA column and sometimes in Hindi. The first value column is per
    /// 100 g unless the header puts the serving column first.
    private static func readPrintedPanel(_ lines: [String], basis: NutritionBasis) -> NutritionLabelRead? {
        let useful = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !useful.isEmpty else { return nil }

        let order = columnOrder(in: useful)
        var sections: [(basis: NutritionBasis?, lines: [String])] = [(nil, [])]
        for line in useful {
            if isPanelNoise(line) { continue }
            if let header = soleBasisHeader(line) {
                sections.append((header, []))
                continue
            }
            sections[sections.count - 1].lines.append(line)
        }

        let headed = sections.filter { $0.basis != nil && !$0.lines.isEmpty }
        let primary: PanelFacts
        let secondary: PanelFacts?
        let ingredients: [String]
        if headed.count >= 1 {
            var byBasis: [NutritionBasis: PanelFacts] = [:]
            var ingredientLines: [String] = []
            for section in headed {
                guard let sectionBasis = section.basis else { continue }
                let parsed = parseRows(section.lines, order: [sectionBasis], requested: sectionBasis)
                byBasis[sectionBasis] = parsed.facts
                ingredientLines.append(contentsOf: parsed.ingredients)
            }
            let other: NutritionBasis = basis == .per100Grams ? .perServing : .per100Grams
            primary = byBasis[basis] ?? PanelFacts()
            secondary = byBasis[other].flatMap { $0.count >= 2 ? $0 : nil }
            ingredients = ingredientLines
        } else {
            let rows = sections.flatMap(\.lines)
            let parsed = parseRows(rows, order: order, requested: basis)
            let other = parseRows(rows, order: order, requested: basis == .per100Grams ? .perServing : .per100Grams)
            primary = parsed.facts
            secondary = other.facts.count >= 2 ? other.facts : nil
            ingredients = parsed.ingredients
        }

        guard primary.count >= 2 || ingredients.count >= 2 else { return nil }
        let serving = servingSizeDescription(in: useful, basis: basis)
        let alternateServing = servingSizeDescription(
            in: useful,
            basis: basis == .per100Grams ? .perServing : .per100Grams
        )
        return NutritionLabelRead(
            nutrition: primary.asFacts(servingSize: serving),
            ingredients: ingredients.joined(separator: ", "),
            nutrientCount: primary.count,
            basis: basis,
            alternate: secondary?.asFacts(servingSize: alternateServing)
        )
    }

    private struct PanelFacts {
        var calories = -1
        var protein = -1.0
        var carbs = -1.0
        var sugar = -1.0
        var fat = -1.0
        var fiber = -1.0
        var sodium = -1.0

        var count: Int {
            [calories >= 0, protein >= 0, carbs >= 0, sugar >= 0, fat >= 0, fiber >= 0, sodium >= 0]
                .filter { $0 }.count
        }

        func asFacts(servingSize: String) -> NutritionFacts {
            NutritionFacts(
                servingSize: servingSize,
                calories: calories,
                proteinGrams: protein,
                carbsGrams: carbs,
                sugarGrams: sugar,
                fatGrams: fat,
                fiberGrams: fiber,
                sodiumMilligrams: sodium
            )
        }
    }

    private enum NutrientKind {
        case energy, protein, carb, sugar, fat, fiber, sodium
    }

    private struct PrintedAmount {
        var value: Double
        enum Unit { case kcal, kj, grams, milligrams, percent, unknown }
        var unit: Unit
    }

    private static func parseRows(
        _ lines: [String],
        order: [NutritionBasis],
        requested: NutritionBasis
    ) -> (facts: PanelFacts, ingredients: [String]) {
        var facts = PanelFacts()
        var ingredients: [String] = []
        for line in lines {
            if let ingredientLine = ingredientBody(line) {
                ingredients.append(contentsOf: ingredientLine)
                continue
            }
            guard let kind = nutrientKind(line) else { continue }
            let columns = valueColumns(in: line)
            guard let index = order.firstIndex(of: requested), index < columns.count else {
                if columns.count == 1, order.first == requested || order.isEmpty {
                    apply(kind, columns[0], to: &facts)
                }
                continue
            }
            apply(kind, columns[index], to: &facts)
        }
        return (facts, ingredients)
    }

    /// A single amount belongs to the only declared column. Two amounts
    /// follow the header order. A kJ figure beside kcal is one column.
    private static func valueColumns(in line: String) -> [PrintedAmount] {
        var columns: [PrintedAmount] = []
        var pendingKJ: Double?
        for amount in amounts(in: line) {
            if amount.unit == .percent { continue }
            if amount.value == 100, amount.unit == .grams, isBasisMention(line) { continue }
            if amount.unit == .kj {
                pendingKJ = amount.value
                continue
            }
            if amount.unit == .kcal {
                columns.append(PrintedAmount(value: amount.value, unit: .kcal))
                pendingKJ = nil
                continue
            }
            if let pendingKJ {
                columns.append(PrintedAmount(value: pendingKJ / 4.184, unit: .kcal))
            }
            pendingKJ = nil
            columns.append(amount)
        }
        if let pendingKJ {
            columns.append(PrintedAmount(value: pendingKJ / 4.184, unit: .kcal))
        }
        return columns
    }

    private static func amounts(in line: String) -> [PrintedAmount] {
        let pattern = /(?i)(\d+(?:[.,]\d+)?)\s*(kcal|kj|cals?|mg|g|%|ग्राम|मिग्रा)?/
        return line.matches(of: pattern).compactMap { match in
            let raw = String(match.1)
            let normalized: String
            if raw.contains(","), let fraction = raw.split(separator: ",").last, fraction.count <= 2 {
                normalized = raw.replacingOccurrences(of: ",", with: ".")
            } else {
                normalized = raw.replacingOccurrences(of: ",", with: "")
            }
            guard let value = Double(normalized) else { return nil }
            let unitText = match.2.map { String($0).lowercased() } ?? ""
            let unit: PrintedAmount.Unit
            switch unitText {
            case "kcal", "cal", "cals": unit = .kcal
            case "kj": unit = .kj
            case "mg", "मिग्रा": unit = .milligrams
            case "g", "ग्राम": unit = .grams
            case "%": unit = .percent
            default: unit = .unknown
            }
            return PrintedAmount(value: value, unit: unit)
        }
    }

    private static func apply(_ kind: NutrientKind, _ amount: PrintedAmount, to facts: inout PanelFacts) {
        switch kind {
        case .energy:
            let kcal: Double?
            switch amount.unit {
            case .kcal: kcal = amount.value
            case .kj: kcal = amount.value / 4.184
            default: kcal = nil
            }
            if let kcal, facts.calories < 0 {
                facts.calories = Int(kcal.rounded())
            }
        case .protein where amount.unit != .kcal && amount.unit != .kj && amount.unit != .milligrams:
            if facts.protein < 0 { facts.protein = amount.value }
        case .carb where amount.unit != .kcal && amount.unit != .kj && amount.unit != .milligrams:
            if facts.carbs < 0 { facts.carbs = amount.value }
        case .sugar where amount.unit != .kcal && amount.unit != .kj && amount.unit != .milligrams:
            if facts.sugar < 0 { facts.sugar = amount.value }
        case .fat where amount.unit != .kcal && amount.unit != .kj && amount.unit != .milligrams:
            if facts.fat < 0 { facts.fat = amount.value }
        case .fiber where amount.unit != .kcal && amount.unit != .kj && amount.unit != .milligrams:
            if facts.fiber < 0 { facts.fiber = amount.value }
        case .sodium:
            if facts.sodium >= 0 { return }
            switch amount.unit {
            case .milligrams: facts.sodium = amount.value
            case .grams where amount.value < 50: facts.sodium = amount.value * 1000
            case .unknown where amount.value >= 20: facts.sodium = amount.value
            default: break
            }
        default:
            break
        }
    }

    private static func nutrientKind(_ line: String) -> NutrientKind? {
        let lower = line.lowercased()
        if lower.contains("saturat") || lower.contains("संतृप्त") || lower.contains("trans") || lower.contains("ट्रांस") {
            return nil
        }
        if lower.contains("salt") || lower.contains("नमक") || lower.contains("cholesterol") { return nil }
        if lower.contains("sugar") || lower.contains("शर्करा") || lower.contains("शक्कर") { return .sugar }
        if lower.contains("fibre") || lower.contains("fiber") || lower.contains("फाइबर") || lower.contains("रेशा") {
            return .fiber
        }
        if lower.contains("protein") || lower.contains("प्रोटीन") { return .protein }
        if lower.contains("fat") || lower.contains("वसा") { return .fat }
        if lower.contains("carb") || lower.contains("कार्बोहाइड्रेट") || lower.contains("कार्बोहाईड्रेट") {
            return .carb
        }
        if lower.contains("sodium") || lower.contains("सोडियम") { return .sodium }
        if lower.contains("energy") || lower.contains("calor") || lower.contains("ऊर्जा") || lower.contains("उर्जा") || lower.contains("कैलोरी") {
            return .energy
        }
        return nil
    }

    private static func columnOrder(in lines: [String]) -> [NutritionBasis] {
        for line in lines where nutrientKind(line) == nil {
            let lower = line.lowercased()
            let hundred = lower.range(of: "100")
            let serving = lower.range(of: "serv") ?? lower.range(of: "सर्व")
            if let hundred, let serving {
                return hundred.lowerBound < serving.lowerBound
                    ? [.per100Grams, .perServing]
                    : [.perServing, .per100Grams]
            }
        }
        return [.per100Grams, .perServing]
    }

    private static func soleBasisHeader(_ line: String) -> NutritionBasis? {
        guard nutrientKind(line) == nil else { return nil }
        let lower = line.lowercased()
        let hundred = isPer100(lower)
        let serving = isPerServing(lower)
        if hundred && !serving { return .per100Grams }
        if serving && !hundred { return .perServing }
        return nil
    }

    private static func isBasisMention(_ line: String) -> Bool {
        let lower = line.lowercased()
        return isPer100(lower) || isPerServing(lower)
    }

    private static func isPer100(_ lower: String) -> Bool {
        lower.contains("100") && (lower.contains("per") || lower.contains("प्रति") || lower.contains("/") || lower.contains("each"))
    }

    private static func isPerServing(_ lower: String) -> Bool {
        lower.contains("serv") || lower.contains("serve") || lower.contains("सर्व") || lower.contains("सर्विंग")
    }

    private static func servingSizeDescription(in lines: [String], basis: NutritionBasis) -> String {
        if basis == .per100Grams { return "100 g" }
        for line in lines {
            let lower = line.lowercased()
            guard let servingAt = lower.range(of: "serv")?.lowerBound ?? lower.range(of: "सर्व")?.lowerBound else { continue }
            let tail = String(line[servingAt...])
            if let match = tail.firstMatch(of: /(\d+(?:[.,]\d+)?)\s*(g|ml|ग्राम)/) {
                let number = String(match.1).replacingOccurrences(of: ",", with: ".")
                if number != "100" {
                    return "\(number) \(match.2)"
                }
            }
        }
        return "1 serving"
    }

    private static func ingredientBody(_ line: String) -> [String]? {
        let lower = line.lowercased()
        let starts = lower.hasPrefix("ingredient") || lower.hasPrefix("contains ")
            || lower.hasPrefix("सामग्री") || lower.hasPrefix("संघटक")
        guard starts else { return nil }
        let body = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? line
        let stripped = body.replacingOccurrences(
            of: #"^(?i)(ingredients|contains)\b"#,
            with: "",
            options: .regularExpression
        )
        let parts = stripped.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { $0.count >= 2 && $0.lowercased() != "ingredients" && $0.lowercased() != "contains" }
        return parts.isEmpty ? nil : parts
    }

    private static func isPanelNoise(_ line: String) -> Bool {
        let lower = line.lowercased()
        let markers = [
            "mrp", "fssai", "best before", "use by", "mfg", "pkd", "batch",
            "customer care", "manufactured", "marketed", "inclusive of all taxes",
            "net wt", "net weight", "net qty", "net quantity"
        ]
        return markers.contains { lower.contains($0) }
    }

    /// Splits words and the punctuation Natural Language treats as its own
    /// tokens, so the tag list lines up with the words.
    private static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in line {
            if character.isWhitespace || character == "," || character == ":" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                if character == "," || character == ":" {
                    tokens.append(String(character))
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func tag(_ tokens: [String]) -> [String] {
        guard let model else { return Array(repeating: "other", count: tokens.count) }
        let tagger = NLTagger(tagSchemes: [scheme])
        tagger.setModels([model], forTagScheme: scheme)
        let text = tokens.joined(separator: " ")
        tagger.string = text
        var labels: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: scheme, options: [.omitWhitespace]) { tag, _ in
            labels.append(tag?.rawValue ?? "other")
            return true
        }
        if labels.count == tokens.count { return labels }
        return Array(repeating: "other", count: tokens.count)
    }

    private static func assign(
        _ field: String?,
        _ number: Double,
        calories: inout Int,
        protein: inout Double,
        carbs: inout Double,
        sugar: inout Double,
        fat: inout Double,
        fiber: inout Double,
        sodium: inout Double
    ) {
        guard let field, number >= 0 else { return }
        switch field {
        case "energy":
            calories = Int(number.rounded())
        case "protein":
            protein = number
        case "carb":
            carbs = number
        case "sugar":
            sugar = number
        case "fat":
            fat = number
        case "fiber":
            fiber = number
        case "sodium":
            sodium = number
        default:
            break
        }
    }
}

private final class NutritionLabelBundleToken {}
