import Testing
@testable import StashKeeper

@Suite("Nutrition label reader")
@MainActor
struct NutritionLabelReaderTests {

    @Test func readsAPrintedPanel() {
        let read = NutritionLabelReader.read([
            "Per 100 g",
            "Energy 412 kcal",
            "Protein 7.6 g",
            "Total Fat 19.4 g",
            "Carbohydrate 56.1 g",
            "of which Sugars 24.2 g",
            "Dietary Fibre 3.1 g",
            "Sodium 96 mg",
            "Ingredients: Sugar, Wheat flour, Cocoa solids",
        ])
        let facts = read?.nutrition
        #expect(facts?.calories == 412)
        #expect(facts?.proteinGrams == 7.6)
        #expect(facts?.fatGrams == 19.4)
        #expect(facts?.carbsGrams == 56.1)
        #expect(facts?.sugarGrams == 24.2)
        #expect(facts?.fiberGrams == 3.1)
        #expect(facts?.sodiumMilligrams == 96)
        #expect(facts?.servingSize == "100 g")
        #expect(read?.ingredients == "Sugar, Wheat flour, Cocoa solids")
    }

    @Test func twoColumnsKeepPer100g() {
        let lines = [
            "Per 100 g    Per serving",
            "Energy 412 kcal 206 kcal",
            "Protein 7.6 g 3.8 g",
            "Total Fat 19.4 g 9.7 g",
        ]
        #expect(NutritionLabelReader.containsTwoValueColumns(lines))
        let read = NutritionLabelReader.read(lines)
        #expect(read?.nutrition.calories == 412)
        #expect(read?.nutrition.proteinGrams == 7.6)
        #expect(read?.nutrition.fatGrams == 19.4)
        #expect(read?.nutrition.servingSize == "100 g")
        #expect(read?.alternate?.calories == 206)
        #expect(read?.alternate?.proteinGrams == 3.8)
    }

    @Test func servingColumnIsAvailableWhenAsked() {
        let lines = [
            "Per 100 g    Per serving (30 g)",
            "Energy 412 kcal 124 kcal",
            "Protein 7.6 g 2.3 g",
        ]
        let read = NutritionLabelReader.read(lines, basis: .perServing)
        #expect(read?.nutrition.calories == 124)
        #expect(read?.nutrition.proteinGrams == 2.3)
        #expect(read?.nutrition.servingSize == "30 g")
        #expect(read?.alternate?.calories == 412)
    }

    @Test func verticalColumnsAndHindiKeepPer100g() {
        let vertical = NutritionLabelReader.read([
            "Per 100 g",
            "Energy 412 kcal",
            "Protein 7.6 g",
            "Fat 19.4 g",
            "Per serving (30 g)",
            "Energy 124 kcal",
            "Protein 2.3 g",
            "Fat 5.8 g",
        ])
        #expect(vertical?.nutrition.calories == 412)
        #expect(vertical?.nutrition.proteinGrams == 7.6)
        #expect(vertical?.alternate?.calories == 124)
        #expect(vertical?.alternate?.servingSize == "30 g")

        let hindi = NutritionLabelReader.read([
            "प्रति 100 ग्राम    प्रति सर्विंग",
            "ऊर्जा 412 kcal 206 kcal",
            "प्रोटीन 7.6 g 3.8 g",
            "कुल वसा 19.4 g 9.7 g",
            "कार्बोहाइड्रेट 56.1 g 28 g",
            "शर्करा 24.2 g 12.1 g",
            "आहार फाइबर 3.1 g 1.5 g",
            "सोडियम 96 mg 48 mg",
        ])
        #expect(hindi?.nutrition.calories == 412)
        #expect(hindi?.nutrition.proteinGrams == 7.6)
        #expect(hindi?.nutrition.fatGrams == 19.4)
        #expect(hindi?.nutrition.carbsGrams == 56.1)
        #expect(hindi?.nutrition.sugarGrams == 24.2)
        #expect(hindi?.nutrition.fiberGrams == 3.1)
        #expect(hindi?.nutrition.sodiumMilligrams == 96)
        #expect(hindi?.alternate?.calories == 206)
        #expect(hindi?.alternate?.sodiumMilligrams == 48)
    }

    @Test func energyInKilojoulesUsesTheKcalFigure() {
        let read = NutritionLabelReader.read([
            "Energy 1728 kJ / 412 kcal",
            "Protein 7.6 g",
            "Total Fat 19.4 g",
        ])
        #expect(read?.nutrition.calories == 412)
        #expect(read?.nutrition.proteinGrams == 7.6)
    }

    @Test func percentDailyValueIsNotANutrientColumn() {
        let read = NutritionLabelReader.read([
            "Per 100 g    Per serve    % RDA",
            "Energy 412 kcal 206 kcal 10%",
            "Protein 7.6 g 3.8 g 15%",
            "Fat 19.4 g 9.7 g 12%",
        ])
        #expect(read?.nutrition.calories == 412)
        #expect(read?.nutrition.proteinGrams == 7.6)
        #expect(read?.alternate?.calories == 206)
    }

    @Test func priceLineDoesNotBecomeNutrition() {
        let read = NutritionLabelReader.read([
            "MRP Rs 20.00 inclusive of all taxes",
            "Best before 12 months from manufacture",
        ])
        #expect(read == nil)
    }
}
