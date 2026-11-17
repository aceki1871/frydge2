//
//  RecipeMatchTests.swift
//  FrydgeRecipes Tests
//
//  The single recipe ↔ fridge match used by the recipes list, recipe detail
//  and item detail sheet (RecipeMatch.swift).
//

import Testing
import Foundation
@testable import FrydgeRecipes

@Suite("Recipe match")
@MainActor
struct RecipeMatchTests {

    private func item(_ name: String, used: Double = 0, lifecycle: StoredIngredient.ItemLifecycle = .fridge) -> StoredIngredient {
        StoredIngredient(
            name: name,
            quantity: "1",
            unit: "ea",
            expirationDate: Date().addingTimeInterval(86_400 * 7),
            location: "Fridge",
            lifecycle: lifecycle,
            quantityUsed: used
        )
    }

    private func recipe(_ name: String, _ ingredients: [String]) -> CloudRecipe {
        CloudRecipe(name: name, ingredients: ingredients, pan: "")
    }

    private func manager(with items: [StoredIngredient]) -> FrydgeManager {
        let manager = FrydgeManager()
        manager.storedIngredients = items
        return manager
    }

    @Test("Percent is covered lines over total, staples count as covered")
    func percentAndStaples() {
        let manager = manager(with: [item("Beef mince"), item("Onions")])
        let match = manager.recipeMatch(forIngredientLines: ["500g beef mince", "1 onion", "2 carrots", "salt"])
        #expect(match.total == 4)
        #expect(match.haveCount == 3)
        #expect(match.missing == ["2 carrots"])
        #expect(match.percentText == "75%")
        #expect(!match.isComplete)
    }

    @Test("Everything in the fridge is a complete match")
    func complete() {
        let manager = manager(with: [item("Eggs"), item("Butter")])
        let match = manager.recipeMatch(forIngredientLines: ["2 eggs", "50g butter"])
        #expect(match.isComplete)
        #expect(match.percent == 1)
    }

    @Test("Used-up items and leftovers don't count")
    func excludesUsedUpAndLeftovers() {
        let manager = manager(with: [item("Milk", used: 100), item("Lasagne", lifecycle: .leftover)])
        let match = manager.recipeMatch(forIngredientLines: ["1 cup milk", "lasagne sheets"])
        #expect(match.haveCount == 0)
        #expect(match.missing.count == 2)
        #expect(manager.matchedFridgeItem(for: "1 cup milk") == nil)
    }

    @Test("Synonyms match through the shared matcher, not substrings")
    func synonyms() {
        let manager = manager(with: [item("Capsicum"), item("Spring onions")])
        #expect(manager.hasIngredient("1 red bell pepper"))
        #expect(manager.hasIngredient("2 scallions, sliced"))
        #expect(!manager.hasIngredient("pepper"))   // plain "pepper" is not the capsicum
    }

    @Test("Cooking deducts only matched items: rice never touches ice, pork mince never touches beef mince")
    func markIngredientsUsedIsFoodAware() {
        let manager = manager(with: [item("Ice"), item("Rice"), item("Beef mince"), item("Butter")])
        manager.markIngredientsUsed(["1 cup basmati rice", "500g pork mince", "50g butter", "butter, melted"], percentage: 50)
        func used(_ name: String) -> Double? { manager.storedIngredients.first { $0.name == name }?.quantityUsed }
        #expect(used("Rice") == 50)
        #expect(used("Ice") == 0)
        #expect(used("Beef mince") == 0)
        #expect(used("Butter") == 50)   // two butter lines, deducted once
    }

    @Test("The fridge index is reused until the fridge changes")
    func fridgeIndexIsCached() {
        let manager = manager(with: [item("Eggs"), item("Butter")])
        _ = manager.recipeMatch(forIngredientLines: ["2 eggs"])
        #expect(manager.matchIndexCache?.names == ["Eggs", "Butter"])
        _ = manager.recipeMatch(forIngredientLines: ["50g butter"])
        #expect(manager.matchIndexCache?.names == ["Eggs", "Butter"])
        manager.storedIngredients.append(item("Milk"))
        #expect(manager.hasIngredient("1 cup milk"))
        #expect(manager.matchIndexCache?.names == ["Eggs", "Butter", "Milk"])
        #expect(manager.matchedFridgeItem(for: "1 cup milk")?.name == "Milk")
    }

    @Test("Recipes using an item are ranked by fridge match")
    func recipesUsingRanking() {
        let manager = manager(with: [item("Chicken thighs"), item("Garlic"), item("Lemon")])
        let full = recipe("Lemon chicken", ["500g chicken thighs", "1 lemon", "2 cloves garlic"])
        let half = recipe("Chicken curry", ["500g chicken thighs", "coconut milk", "curry paste", "rice"])
        let none = recipe("Pancakes", ["flour", "milk", "eggs"])

        let ranked = manager.recipesUsing(item("Chicken thighs"), from: [half, none, full])
        #expect(ranked.map(\.recipe.name) == ["Lemon chicken", "Chicken curry"])
        #expect(ranked[0].match.isComplete)
        #expect(ranked[1].match.missing == ["coconut milk", "curry paste", "rice"])
    }

    @Test("Expiry suggestions are the top-matched recipes as a plist-safe payload")
    func expirySuggestionsPayload() {
        let manager = manager(with: [item("Chicken thighs"), item("Garlic"), item("Lemon")])
        let full = recipe("Lemon chicken", ["500g chicken thighs", "1 lemon", "2 cloves garlic"])
        let half = recipe("Chicken curry", ["500g chicken thighs", "coconut milk", "curry paste", "rice"])
        let third = recipe("Chicken soup", ["chicken thighs", "stock", "noodles", "carrot", "celery"])
        let fourth = recipe("Chicken pie", ["chicken thighs", "pastry", "cream", "leek", "peas", "thyme"])
        let none = recipe("Pancakes", ["flour", "milk", "eggs"])

        let payload = manager.expirySuggestions(for: item("Chicken thighs"), from: [none, fourth, half, third, full])
        #expect(payload.count == 3)
        #expect(payload.map { $0["name"] } == ["Lemon chicken", "Chicken curry", "Chicken soup"])
        #expect(payload[0]["id"] == full.id)
        #expect(payload[0]["match"] == "100%")
        #expect(payload[1]["match"] == "25%")
        #expect(payload[0]["imageURL"] == "")   // never nil: the payload must stay a [String: String]
    }

    @Test("No suggestions when nothing uses the item")
    func expirySuggestionsEmpty() {
        let manager = manager(with: [item("Tofu")])
        let payload = manager.expirySuggestions(for: item("Tofu"), from: [recipe("Pancakes", ["flour", "milk", "eggs"])])
        #expect(payload.isEmpty)
        #expect(FrydgeManager.useItUpLine(from: payload) == nil)
    }

    @Test("Use-it-up line reads naturally for one, two and three recipes")
    func useItUpLine() {
        func line(_ names: [String]) -> String? {
            FrydgeManager.useItUpLine(from: names.map { ["id": $0, "name": $0] })
        }
        #expect(line(["Pancakes"]) == "Use it up: Pancakes.")
        #expect(line(["Pancakes", "Omelette"]) == "Use it up: Pancakes or Omelette.")
        #expect(line(["Pancakes", "Omelette", "Custard"]) == "Use it up: Pancakes, Omelette or Custard.")
    }
}
