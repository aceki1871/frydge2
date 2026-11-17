//
//  FrydgeIntelligenceTests.swift
//  FrydgeRecipes Tests
//
//  Covers the deterministic logic around every Apple Intelligence feature —
//  draft mapping, substitution validation, and clamping — without depending
//  on the on-device model actually being available in the test environment.
//

import Testing
import Foundation
@testable import FrydgeRecipes

// Serialized: both tests mutate the shared FrydgeIntelligence.enabledKey in
// UserDefaults, so they can't safely run concurrently.
@Suite("Apple Intelligence availability", .serialized)
struct FrydgeIntelligenceAvailabilityTests {

    @Test("Turning the toggle off always makes the feature unavailable")
    func toggleOffDisables() {
        let key = FrydgeIntelligence.enabledKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.set(false, forKey: key)
        #expect(FrydgeIntelligence.isAvailable == false)
    }

    @Test("With no stored preference, availability matches device support")
    func defaultsToDeviceSupport() {
        let key = FrydgeIntelligence.enabledKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
        }

        UserDefaults.standard.removeObject(forKey: key)
        #expect(FrydgeIntelligence.isAvailable == FrydgeIntelligence.isSupportedOnDevice)
    }
}

@Suite("Recipe import AI draft mapping")
struct RecipeImportAIDraftTests {

    @Test("Ingredients and steps map into a usable draft")
    func mapsFields() {
        let draft = RecipeImportAI.draft(
            title: "  Banana Bread  ",
            ingredients: ["2 cups flour", "1 cup sugar"],
            steps: ["Mix dry ingredients", "Bake at 180C for 45 minutes"]
        )
        #expect(draft?.name == "Banana Bread")
        #expect(draft?.ingredients.count == 2)
        #expect(draft?.instructions == "1. Mix dry ingredients\n2. Bake at 180C for 45 minutes")
    }

    @Test("A blank title falls back to a generic name")
    func blankTitleFallsBack() {
        let draft = RecipeImportAI.draft(title: "", ingredients: ["1 egg"], steps: [])
        #expect(draft?.name == "Imported Recipe")
    }

    @Test("No ingredients and no steps produces no draft")
    func emptyProducesNil() {
        let draft = RecipeImportAI.draft(title: "Empty", ingredients: [], steps: [])
        #expect(draft == nil)
    }

    @Test("Blank lines are dropped before numbering steps")
    func blankStepLinesDropped() {
        let draft = RecipeImportAI.draft(title: "T", ingredients: [], steps: ["Step one", "  ", "Step two"])
        #expect(draft?.instructions == "1. Step one\n2. Step two")
    }
}

@Suite("Recipe substitution validation")
struct RecipeSubstitutionValidationTests {

    @Test("A swap naming a real fridge item for a real missing line is kept")
    func validSwapKept() {
        let result = RecipeSubstitutionAI.validate(
            items: [(missing: "sour cream", use: "greek yoghurt", note: "similar tang")],
            missingLines: ["1 cup sour cream"],
            fridgeItemNames: ["Greek Yoghurt", "Milk"]
        )
        #expect(result.count == 1)
        #expect(result.first?.missing == "1 cup sour cream")
        #expect(result.first?.use == "Greek Yoghurt")
    }

    @Test("A swap naming an item that isn't actually in the fridge is dropped")
    func hallucinatedFridgeItemDropped() {
        let result = RecipeSubstitutionAI.validate(
            items: [(missing: "sour cream", use: "creme fraiche", note: "similar tang")],
            missingLines: ["1 cup sour cream"],
            fridgeItemNames: ["Milk", "Butter"]
        )
        #expect(result.isEmpty)
    }

    @Test("A swap for a line that isn't actually missing is dropped")
    func nonMissingLineDropped() {
        let result = RecipeSubstitutionAI.validate(
            items: [(missing: "chicken stock", use: "vegetable stock", note: "close enough")],
            missingLines: ["1 cup sour cream"],
            fridgeItemNames: ["Vegetable Stock"]
        )
        #expect(result.isEmpty)
    }

    @Test("Only one swap is kept per missing line")
    func dedupesPerMissingLine() {
        let result = RecipeSubstitutionAI.validate(
            items: [
                (missing: "sour cream", use: "greek yoghurt", note: "a"),
                (missing: "sour cream", use: "milk", note: "b")
            ],
            missingLines: ["1 cup sour cream"],
            fridgeItemNames: ["Greek Yoghurt", "Milk"]
        )
        #expect(result.count == 1)
    }
}

@Suite("Food storage classifier keyword coverage")
struct FoodStorageClassifierKeywordTests {

    @Test("Recognised names report a keyword match")
    func recognisedNameMatches() {
        #expect(FoodStorageClassifier.hasKeywordMatch(for: "Chicken Breast"))
        #expect(FoodStorageClassifier.hasKeywordMatch(for: "Frozen Peas"))
        #expect(FoodStorageClassifier.hasKeywordMatch(for: "Rice"))
    }

    @Test("An unrecognised name reports no keyword match")
    func unrecognisedNameHasNoMatch() {
        #expect(!FoodStorageClassifier.hasKeywordMatch(for: "Dragonfruit Kombucha Blend"))
    }
}

@Suite("AI numeric clamping")
struct AIClampingTests {

    @Test("Leftover keep-days are clamped to 1...5")
    func leftoverDaysClamped() {
        #expect(LeftoverKeepDaysAI.clampDays(0) == 1)
        #expect(LeftoverKeepDaysAI.clampDays(3) == 3)
        #expect(LeftoverKeepDaysAI.clampDays(30) == 5)
    }

    @Test("Shelf-life days are clamped to 1...365")
    func shelfLifeDaysClamped() {
        #expect(FoodStorageAI.clampShelfLifeDays(0) == 1)
        #expect(FoodStorageAI.clampShelfLifeDays(90) == 90)
        #expect(FoodStorageAI.clampShelfLifeDays(10000) == 365)
    }
}
