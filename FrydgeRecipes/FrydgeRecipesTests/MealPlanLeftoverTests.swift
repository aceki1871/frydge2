//
//  MealPlanLeftoverTests.swift
//  FrydgeRecipes Tests
//
//  Leftovers planned as meals: tagged through the recipe ID, carry no
//  ingredients, and never add anything to the shopping list.
//

import Testing
import Foundation
@testable import FrydgeRecipes

@Suite("Meal plan leftovers")
struct MealPlanLeftoverTests {

    private func leftover(
        id: String = "ABC-123",
        name: String = "Lasagne",
        portions: Int = 2,
        expiresInDays: Int = 3
    ) -> PlannableLeftover {
        PlannableLeftover(
            id: id,
            name: name,
            portions: portions,
            expiryDate: Calendar.current.date(byAdding: .day, value: expiresInDays, to: Date()) ?? Date(),
            dietaryTags: ["VEGETARIAN"]
        )
    }

    @Test("Recipe ID round-trips the frydge item ID")
    func recipeIDRoundTrip() {
        let id = PlannedLeftover.recipeID(forItem: "ABC-123")
        #expect(PlannedLeftover.isLeftover(recipeID: id))
        #expect(PlannedLeftover.itemID(from: id) == "ABC-123")
        #expect(!PlannedLeftover.isLeftover(recipeID: "some-recipe"))
        #expect(PlannedLeftover.itemID(from: "some-recipe") == nil)
    }

    @Test("A planned leftover has no ingredients and remembers its portions")
    func plannedRecipeFromLeftover() {
        let plan = PlannedRecipe(dayIndex: 2, leftover: leftover())
        #expect(plan.isLeftover)
        #expect(plan.leftoverItemID == "ABC-123")
        #expect(plan.ingredients.isEmpty)
        #expect(plan.recipeName == "Lasagne")
        #expect(plan.serves == "2")
        #expect(PlannedLeftover.portionsText(plan.serves) == "2 portions")
        #expect(PlannedLeftover.portionsText("1") == "1 portion")
    }

    @Test("Leftover nights add nothing to buy")
    func leftoverAddsNothingToBuy() {
        let plan = PlannedRecipe(dayIndex: 0, leftover: leftover())
        let meal = MealPlanNeeds.Meal(
            recipeName: plan.recipeName, dayIndex: plan.dayIndex,
            ingredients: plan.ingredients, dietaryTags: plan.dietaryTags
        )
        let result = MealPlanNeeds.compute(meals: [meal], stock: [], shoppingListNames: [])
        #expect(result.isEmpty)
    }

    @Test("Days after the use-by are flagged")
    func afterUseBy() {
        let today = Calendar.current.startOfDay(for: Date())
        // Expires today: every day except today is too late.
        let todayIndex = (Calendar.current.component(.weekday, from: today) + 5) % 7
        #expect(!PlannedLeftover.isAfterUseBy(dayIndex: todayIndex, expiry: today, now: today))
        #expect(PlannedLeftover.isAfterUseBy(dayIndex: (todayIndex + 1) % 7, expiry: today, now: today))

        // Expires in a week: no day of the coming week is too late.
        let nextWeek = Calendar.current.date(byAdding: .day, value: 7, to: today) ?? today
        for day in 0..<7 {
            #expect(!PlannedLeftover.isAfterUseBy(dayIndex: day, expiry: nextWeek, now: today))
        }
    }

    @Test("Stored leftover maps portions from its quantity")
    func fromStoredIngredient() {
        let stored = StoredIngredient(
            name: "Chilli",
            quantity: "3",
            unit: "portion",
            expirationDate: Date().addingTimeInterval(86_400),
            location: "Fridge",
            lifecycle: .leftover
        )
        let plannable = PlannableLeftover(stored: stored)
        #expect(plannable.id == stored.id.uuidString)
        #expect(plannable.portions == 3)
        #expect(plannable.portionsText == "3 portions")
        #expect(!plannable.isExpired)
    }

    @Test("Export lists leftovers without ingredients")
    func exportShowsLeftovers() {
        let text = MealPlanExport.text(
            title: "Weekly Meal Plan",
            entries: [
                MealPlanExport.Entry(dayIndex: 1, name: "Lasagne", serves: "2", ingredients: [],
                                     dietaryTags: [], isLeftover: true, costText: nil)
            ],
            weekCostText: nil, toBuyCostText: nil, budgetLine: nil, dueStaples: ["Bin liners"]
        )
        #expect(text.contains("Tuesday:"))
        #expect(text.contains("• Leftovers: Lasagne — 2 portions"))
        #expect(text.contains("• Bin liners"))
    }
}
