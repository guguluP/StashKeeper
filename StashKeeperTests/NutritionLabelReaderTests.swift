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

    @Test func priceLineDoesNotBecomeNutrition() {
        let read = NutritionLabelReader.read([
            "MRP Rs 20.00 inclusive of all taxes",
            "Best before 12 months from manufacture",
        ])
        #expect(read == nil)
    }
}
