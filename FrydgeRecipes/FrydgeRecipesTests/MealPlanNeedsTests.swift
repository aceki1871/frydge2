//
//  MealPlanNeedsTests.swift
//  FrydgeRecipes Tests
//
//  The household meal plan's "what do we have vs. what do we buy" calculator.
//

import Testing
import Foundation
@testable import FrydgeRecipes

@Suite("Meal plan needs")
struct MealPlanNeedsTests {

    private func meal(_ name: String, day: Int = 0, _ ingredients: [String]) -> MealPlanNeeds.Meal {
        MealPlanNeeds.Meal(recipeName: name, dayIndex: day, ingredients: ingredients, dietaryTags: [])
    }

    private func stock(_ name: String, _ quantity: String, _ unit: String,
                       used: Double = 0, expired: Bool = false) -> MealPlanNeeds.StockItem {
        MealPlanNeeds.StockItem(name: name, quantity: quantity, unit: unit, quantityUsed: used, isExpired: expired)
    }

    @Test("Ingredient fully in the frydge is not bought")
    func coveredByFrydge() {
        let result = MealPlanNeeds.compute(
            meals: [meal("Bolognese", ["500g beef mince", "1 onion"])],
            stock: [stock("Beef mince", "1", "kg"), stock("Onions", "3", "ea")],
            shoppingListNames: []
        )
        #expect(result.inFrydge.map(\.name).sorted() == ["beef mince", "onion"])
        #expect(result.toBuy.isEmpty)
    }

    @Test("Partial stock produces a shortfall in the recipe's dimension")
    func partialCoverage() {
        let result = MealPlanNeeds.compute(
            meals: [meal("Bolognese", ["500g beef mince"])],
            stock: [stock("Beef mince", "200", "g")],
            shoppingListNames: []
        )
        #expect(result.inFrydge.isEmpty)
        #expect(result.toBuy.count == 1)
        let line = result.toBuy[0]
        #expect(line.status == .partial(shortfall: "300", unit: "g"))
        #expect(line.purchaseQuantity == "300")
        #expect(line.purchaseUnit == "g")
    }

    @Test("Amounts merge across recipes before comparing")
    func mergesAcrossRecipes() {
        let result = MealPlanNeeds.compute(
            meals: [
                meal("Bolognese", day: 0, ["300g beef mince"]),
                meal("Tacos", day: 2, ["400g beef mince"])
            ],
            stock: [stock("Mince", "500", "g")],
            shoppingListNames: []
        )
        #expect(result.toBuy.count == 1)
        let line = result.toBuy[0]
        #expect(line.quantity == "700")
        #expect(line.unit == "g")
        #expect(line.recipeNames == ["Bolognese", "Tacos"])
        #expect(line.status == .partial(shortfall: "200", unit: "g"))
    }

    @Test("Used-up portion of a frydge item doesn't count")
    func respectsQuantityUsed() {
        let result = MealPlanNeeds.compute(
            meals: [meal("Omelette", ["4 eggs"])],
            stock: [stock("Eggs", "6", "ea", used: 50)], // 3 left
            shoppingListNames: []
        )
        #expect(result.toBuy.first?.status == .partial(shortfall: "1", unit: "ea"))
    }

    @Test("Expired stock is ignored")
    func ignoresExpired() {
        let result = MealPlanNeeds.compute(
            meals: [meal("Omelette", ["4 eggs"])],
            stock: [stock("Eggs", "12", "ea", expired: true)],
            shoppingListNames: []
        )
        #expect(result.toBuy.first?.status == .toBuy)
    }

    @Test("Items already on the shopping list are separated out")
    func alreadyOnList() {
        let result = MealPlanNeeds.compute(
            meals: [meal("Pasta", ["400g spaghetti", "1 jar passata"])],
            stock: [],
            shoppingListNames: ["Spaghetti"]
        )
        #expect(result.onList.map(\.name) == ["spaghetti"])
        #expect(result.toBuy.map(\.name) == ["jar passata"])
    }

    @Test("Name match with incomparable units counts as covered")
    func incomparableUnitsTrustName() {
        let result = MealPlanNeeds.compute(
            meals: [meal("Curry", ["2 tbsp curry paste"])],
            stock: [stock("Curry paste", "1", "jar")],
            shoppingListNames: []
        )
        #expect(result.inFrydge.count == 1)
    }

    @Test("Summary names the split for the household notification")
    func summaryText() {
        let meals = [meal("Bolognese", ["500g beef mince", "1 onion", "400g spaghetti"])]
        let result = MealPlanNeeds.compute(
            meals: meals,
            stock: [stock("Beef mince", "1", "kg")],
            shoppingListNames: []
        )
        let text = MealPlanNeeds.summary(meals: meals, result: result, listName: "Family list")
        #expect(text.hasPrefix("1 meal planned"))
        #expect(text.contains("In the frydge: beef mince"))
        #expect(text.contains("Added to Family list: onion, spaghetti"))
    }
}
