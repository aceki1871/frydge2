//
//  AllergenAndSignalsTests.swift
//  FrydgeRecipes Tests
//
//  Allergen swaps (AllergenAdaptation.swift), the product traffic-light
//  signals (ProductTrafficLights.swift), the "half the bag" container word,
//  and equipment detection from a recipe's method (RecipeEquipment.swift).
//

import Testing
import Foundation
@testable import FrydgeRecipes

@Suite("Allergen swaps")
struct AllergenSwapTests {

    @Test("Peanut lines get a seed swap, peanut butter a seed butter")
    func peanuts() {
        #expect(AllergenSwaps.substitute(for: "peanuts", ingredient: "1/2 cup roasted peanuts")?.contains("pepitas") == true)
        #expect(AllergenSwaps.substitute(for: "peanuts", ingredient: "2 tbsp peanut butter")?.contains("sunflower seed butter") == true)
    }

    @Test("Dairy swaps depend on which dairy it is")
    func dairy() {
        #expect(AllergenSwaps.substitute(for: "milk", ingredient: "1 cup milk")?.contains("oat") == true)
        #expect(AllergenSwaps.substitute(for: "milk", ingredient: "50 g butter")?.contains("olive oil") == true)
        #expect(AllergenSwaps.substitute(for: "cheese", ingredient: "100 g grated cheddar")?.contains("dairy-free cheese") == true)
    }

    @Test("Gluten: soy sauce becomes tamari, pasta becomes gluten-free pasta")
    func gluten() {
        #expect(AllergenSwaps.substitute(for: "gluten", ingredient: "2 tbsp soy sauce") == "tamari (1:1)")
        #expect(AllergenSwaps.substitute(for: "wheat", ingredient: "300 g spaghetti")?.contains("gluten-free pasta") == true)
    }

    @Test("Unknown terms have no swap so the UI says 'leave it out'")
    func unknown() {
        #expect(AllergenSwaps.substitute(for: "saffron", ingredient: "a pinch of saffron") == nil)
    }

    @Test("Verdict headline lists the offending terms")
    func headline() {
        var verdict = RecipeAllergenVerdict()
        verdict.unsafe = [(line: "1 cup peanuts", term: "peanuts")]
        verdict.flagged = [(line: "1 cup milk", term: "milk")]
        #expect(verdict.isUnsafe)
        #expect(verdict.headline == "Contains Peanuts, Milk")
        #expect(RecipeAllergenVerdict().isClean)
    }
}

@Suite("Product traffic lights")
struct ProductSignalTests {

    private func facts() -> ProductNutritionFacts {
        var f = ProductNutritionFacts()
        f.nutriScore = "a"
        f.nova = 4
        f.sugars = 30
        f.salt = 0.1
        f.fibre = 7
        f.ingredientsText = "oats, sugar, salt"
        return f
    }

    @Test("Good, caution and bad signals are produced from the facts")
    func buckets() {
        let signals = ProductSignals.build(facts: facts(), flags: [])
        let good = signals.filter { $0.tone == .good }.map(\.title)
        let bad = signals.filter { $0.tone == .bad }.map(\.title)

        #expect(good.contains("Nutri-Score A"))
        #expect(good.contains("Low in salt"))
        #expect(good.contains("High in fibre"))
        #expect(good.contains("No additives listed"))
        #expect(bad.contains("Ultra-processed"))
        #expect(bad.contains("High in sugar"))
    }

    @Test("A can't-eat flag is the first red signal")
    func blockingFlagFirst() {
        let flag = DietaryFlag(term: "onion", severity: .cannot, evidence: .name, impliedBy: nil)
        let signals = ProductSignals.build(facts: facts(), flags: [flag])
        #expect(signals.first?.tone == .bad)
        #expect(signals.first?.title == "Contains onion")
    }

    @Test("No facts and no flags → no signals")
    func empty() {
        #expect(ProductSignals.build(facts: nil, flags: []).isEmpty)
    }
}

@Suite("Usage chips")
struct UsageChipTests {

    @Test("Container word follows the kind of food")
    func containerWords() {
        #expect(UsageChipPicker.containerWord(for: "Anchor Milk 2L") == "bottle")
        #expect(UsageChipPicker.containerWord(for: "Pic's Peanut Butter") == "jar")
        #expect(UsageChipPicker.containerWord(for: "Free range eggs") == "pack")
        #expect(UsageChipPicker.containerWord(for: "Vogel's bread") == "loaf")
        #expect(UsageChipPicker.containerWord(for: "Corn chips") == "bag")
    }
}

@Suite("Recipe equipment")
struct RecipeEquipmentTests {

    @Test("Equipment is inferred from the method, with the oven temperature as a note")
    func inferredFromSteps() {
        let recipe = CloudRecipe(
            name: "Test bake",
            ingredients: ["2 eggs", "1 cup flour"],
            pan: "",
            instructions: "Preheat the oven to 180°C. Whisk the eggs in a large bowl. Fry the onion in a skillet until soft, then bake for 20 minutes."
        )
        let items = RecipeEquipment.items(for: recipe)
        let names = items.map(\.name)

        #expect(names.contains("Oven"))
        #expect(names.contains("Whisk"))
        #expect(names.contains("Mixing bowl"))
        #expect(names.contains("Frying pan"))
        #expect(items.first { $0.name == "Oven" }?.note?.contains("180") == true)
    }

    @Test("Explicit pan entries come first and aren't duplicated by inference")
    func explicitFirst() {
        let recipe = CloudRecipe(
            name: "Stir fry",
            ingredients: ["chicken"],
            pan: "Wok, Chopping board",
            instructions: "Stir fry the chicken in the wok. Chop the vegetables on a board."
        )
        let items = RecipeEquipment.items(for: recipe)
        #expect(items.first?.name == "Wok")
        #expect(items.first?.isExplicit == true)
        #expect(items.filter { $0.name.lowercased().contains("wok") }.count == 1)
    }
}
