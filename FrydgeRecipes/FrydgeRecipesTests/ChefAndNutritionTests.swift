//
//  ChefAndNutritionTests.swift
//  FrydgeRecipes Tests
//
//  Built-in typical nutrition (GenericNutrition.swift) and the Chef technique
//  library (ChefTechniques.swift).
//

import Testing
import Foundation
@testable import FrydgeRecipes

@Suite("Typical nutrition fallback")
struct GenericNutritionTests {

    @Test("Everyday whole foods always have the four macro boxes")
    func wholeFoodsCovered() {
        for name in ["Eggs", "Free Range Eggs 12pk", "Carrots", "Snapper fillet", "Anchor Butter 500g",
                     "Chicken breast", "Brown onions", "Basmati rice 1kg", "Tasty cheese", "Bananas"] {
            let facts = GenericNutrition.facts(for: name)
            #expect(facts != nil, "no typical values for \(name)")
            #expect(facts?.hasNutrition == true, "\(name) has no macros")
            #expect(facts?.source == .typical)
        }
    }

    @Test("Specific foods fall back to their family")
    func familyFallback() {
        // Not in the table itself, but a child of "cheese" / "fish" in the lexicon.
        #expect(GenericNutrition.entry(for: "Gouda") != nil)
        #expect(GenericNutrition.entry(for: "Kahawai") != nil)
    }

    @Test("Unknown names return nothing rather than guessing")
    func unknownIsNil() {
        #expect(GenericNutrition.entry(for: "Dishwasher tablets") == nil)
        #expect(GenericNutrition.facts(for: "") == nil)
    }

    @Test("Gaps are filled without overwriting real numbers")
    func fillingGaps() {
        // A product record with brand and salt but none of the four macros.
        var partial = ProductNutritionFacts()
        partial.source = .productsDB
        partial.brand = "Anchor"
        partial.salt = 1.2
        let filled = GenericNutrition.fillingGaps(in: partial, for: "Anchor Butter 500g")
        #expect(filled.salt == 1.2)            // kept
        #expect(filled.energyKcal != nil)      // filled
        #expect(filled.fat != nil)
        #expect(filled.protein != nil)
        #expect(filled.brand == "Anchor")
        #expect(filled.source == .typical)     // no real macros were present
    }

    @Test("A record that already has macros keeps its source")
    func keepsSourceWhenNumbersPresent() {
        var real = ProductNutritionFacts()
        real.source = .productsDB
        real.energyKcal = 100; real.fat = 1; real.carbs = 2; real.protein = 3
        let filled = GenericNutrition.fillingGaps(in: real, for: "milk")
        #expect(filled.source == .productsDB)
        #expect(filled.energyKcal == 100)
    }
}

@Suite("Chef techniques")
struct ChefTechniqueTests {

    @Test("Library has unique ids and complete content")
    func libraryIntegrity() {
        let ids = ChefTechniqueLibrary.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for t in ChefTechniqueLibrary.all {
            #expect(!t.steps.isEmpty, "\(t.id) has no steps")
            #expect(!t.title.isEmpty)
        }
    }

    @Test("Cracking eggs surfaces the egg technique")
    func crackEgg() {
        let hits = ChefTechniqueLibrary.relevant(toText: "Crack the eggs into a bowl and whisk.", ingredients: ["3 eggs"])
        #expect(hits.first?.id == "crack-egg")
    }

    @Test("Slicing fish surfaces the fillet-slicing technique, not egg or onion ones")
    func sliceFish() {
        let hits = ChefTechniqueLibrary.relevant(toText: "Slice the snapper into 3 cm pieces.", ingredients: ["400g snapper fillet"], action: .slice)
        #expect(hits.contains { $0.id == "slice-fish" })
        #expect(!hits.contains { $0.id == "crack-egg" })
        #expect(!hits.contains { $0.id == "dice-onion" })
    }

    @Test("Dicing an onion ranks the onion technique above general knife grip")
    func diceOnion() {
        let hits = ChefTechniqueLibrary.relevant(toText: "Finely dice the onion.", ingredients: ["1 onion"], action: .dice)
        let onion = hits.firstIndex { $0.id == "dice-onion" }
        let grip = hits.firstIndex { $0.id == "knife-grip" }
        #expect(onion != nil)
        #expect(grip != nil)
        if let onion, let grip { #expect(onion < grip) }
    }

    @Test("A step with nothing to teach returns nothing")
    func nothingRelevant() {
        let hits = ChefTechniqueLibrary.relevant(toText: "Serve immediately.", ingredients: [])
        #expect(hits.isEmpty)
    }

    @Test("Fridge foods get their prep techniques")
    func foodPrep() {
        #expect(ChefTechniqueLibrary.relevant(toFood: "Free Range Eggs 12pk").contains { $0.id == "crack-egg" })
        #expect(ChefTechniqueLibrary.relevant(toFood: "Fresh Tarakihi Fillets").contains { $0.id == "slice-fish" })
        #expect(ChefTechniqueLibrary.relevant(toFood: "Mainland Tasty Cheese").isEmpty)
    }

    @Test("Search finds techniques by food or verb")
    func search() {
        #expect(ChefTechniqueLibrary.search("fillet").contains { $0.id == "fillet-fish" })
        #expect(ChefTechniqueLibrary.search("garlic").contains { $0.id == "mince-garlic" })
        #expect(ChefTechniqueLibrary.search("").count == ChefTechniqueLibrary.all.count)
    }
}
