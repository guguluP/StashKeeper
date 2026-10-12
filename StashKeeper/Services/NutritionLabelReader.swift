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

struct NutritionLabelRead: Sendable, Equatable {
    var nutrition: NutritionFacts
    var ingredients: String
    /// How many of the seven stored nutrient fields were filled.
    var nutrientCount: Int
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

    /// Reads every OCR line. Returns nil when the panel yielded neither
    /// two nutrients nor an ingredient list.
    static func read(_ lines: [String]) -> NutritionLabelRead? {
        guard model != nil else { return nil }
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

    private static func tokenize(_ line: String) -> [String] {
        line.replacingOccurrences(of: ",", with: " , ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
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
