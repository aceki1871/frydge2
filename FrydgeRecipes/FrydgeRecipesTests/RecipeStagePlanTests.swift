//
//  RecipeStagePlanTests.swift
//  FrydgeRecipesTests
//
//  Stage assignment (which ingredient goes in at which step) and the
//  amount-aware fridge coverage that the detail page, list rows and cook
//  flow now share.
//

import Foundation
import Testing
@testable import FrydgeRecipes

struct RecipeStagePlanTests {

    private let ingredients = [
        "Butter 250g",
        "Caster sugar 200g",
        "Eggs 3",
        "Plain flour 300g",
        "Vanilla extract 1 tsp"
    ]

    @Test func explicitStepTagsWinAndCarryTheSavedQuantity() {
        let steps = [
            RecipeStep(text: "Cream together until pale.", ingredientRefs: ["butter", "caster sugar"]),
            RecipeStep(text: "Beat in one at a time.", ingredientRefs: ["eggs"]),
            RecipeStep(text: "Fold through gently.", ingredientRefs: ["plain flour"])
        ]
        let plan = RecipeStagePlan.build(ingredients: ingredients, steps: steps)

        #expect(plan.stages.count == 3)
        #expect(plan.stages[0].ingredientLines == ["Butter 250g", "Caster sugar 200g"])
        #expect(plan.stages[1].ingredientLines == ["Eggs 3"])
        #expect(plan.stages[2].ingredientLines == ["Plain flour 300g"])
        #expect(plan.unassigned == ["Vanilla extract 1 tsp"])
        #expect(plan.stageNumber(for: "Eggs 3") == 2)
        #expect(plan.stageNumber(for: "Vanilla extract 1 tsp") == nil)
    }

    @Test func untaggedStepsAreInferredFromWording() {
        let steps = [
            RecipeStep(text: "Melt the butter in a pan and stir in the sugar."),
            RecipeStep(text: "Whisk the eggs with the vanilla, then add to the pan."),
            RecipeStep(text: "Sift in the flour and fold until just combined."),
            RecipeStep(text: "Bake for 25 minutes.", timerSeconds: 1500)
        ]
        let plan = RecipeStagePlan.build(ingredients: ingredients, steps: steps)

        #expect(plan.stageNumber(for: "Butter 250g") == 1)
        #expect(plan.stageNumber(for: "Caster sugar 200g") == 1)
        #expect(plan.stageNumber(for: "Eggs 3") == 2)
        #expect(plan.stageNumber(for: "Vanilla extract 1 tsp") == 2)
        #expect(plan.stageNumber(for: "Plain flour 300g") == 3)
        #expect(plan.stages[3].ingredientLines.isEmpty)
        #expect(plan.unassigned.isEmpty)
        #expect(plan.hasAnyAssignments)
    }

    @Test func anIngredientIsOnlyAssignedToItsFirstStage() {
        let steps = [
            RecipeStep(text: "Melt the butter."),
            RecipeStep(text: "Brush more butter over the top.")
        ]
        let plan = RecipeStagePlan.build(ingredients: ["Butter 250g"], steps: steps)
        #expect(plan.stages[0].ingredientLines == ["Butter 250g"])
        #expect(plan.stages[1].ingredientLines.isEmpty)
    }

    @Test func noStepsLeavesEverythingUnassigned() {
        let plan = RecipeStagePlan.build(ingredients: ingredients, steps: [])
        #expect(plan.stages.isEmpty)
        #expect(plan.unassigned == ingredients)
        #expect(!plan.hasAnyAssignments)
    }

    @Test func duplicateLinesAreTrackedIndependently() {
        let steps = [
            RecipeStep(text: "Stir the sugar into the butter."),
            RecipeStep(text: "Sprinkle the remaining sugar on top.")
        ]
        let plan = RecipeStagePlan.build(ingredients: ["Sugar 100g", "Sugar 50g", "Butter 50g"], steps: steps)
        #expect(plan.stages[0].ingredientLines.contains("Sugar 100g"))
        #expect(plan.stages[0].ingredientLines.contains("Butter 50g"))
        #expect(plan.stages[1].ingredientLines == ["Sugar 50g"])
    }
}

struct RecipeReadinessAmountTests {

    private func item(_ name: String, _ quantity: String, _ unit: String, used: Double = 0) -> StoredIngredient {
        StoredIngredient(
            name: name,
            quantity: quantity,
            unit: unit,
            expirationDate: Date().addingTimeInterval(86_400 * 7),
            location: "Fridge",
            quantityUsed: used
        )
    }

    @Test func enoughInFridgeIsCovered() {
        let summary = RecipeReadiness.evaluate(
            lines: ["Butter 250g"],
            fridgeItems: [item("Butter", "500", "g")],
            shoppingListNames: []
        )
        #expect(summary.canMakeNow)
        #expect(summary.statuses[0].isCovered)
        #expect(summary.statuses[0].shortfall == nil)
    }

    @Test func notEnoughInFridgeIsShortNotMissing() {
        let summary = RecipeReadiness.evaluate(
            lines: ["Butter 250g"],
            fridgeItems: [item("Butter", "200", "g")],
            shoppingListNames: []
        )
        let status = summary.statuses[0]
        #expect(status.isInFridge)
        #expect(status.isShort)
        #expect(!status.isCovered)
        #expect(status.shortfall?.quantity == 50)
        #expect(status.shortfall?.unit == "g")
        #expect(summary.shortCount == 1)
        #expect(!summary.canMakeNow)
    }

    @Test func usedPercentageReducesWhatIsAvailable() {
        // 500 g block, 60% used → 200 g left; recipe wants 250 g.
        let summary = RecipeReadiness.evaluate(
            lines: ["Butter 250g"],
            fridgeItems: [item("Butter", "500", "g", used: 60)],
            shoppingListNames: []
        )
        #expect(summary.statuses[0].isShort)
    }

    @Test func servesScalingAppliesToTheRequirement() {
        let fridge = [item("Butter", "300", "g")]
        let single = RecipeReadiness.evaluate(lines: ["Butter 250g"], fridgeItems: fridge, shoppingListNames: [], scale: 1)
        let doubled = RecipeReadiness.evaluate(lines: ["Butter 250g"], fridgeItems: fridge, shoppingListNames: [], scale: 2)
        #expect(single.canMakeNow)
        #expect(!doubled.canMakeNow)
        #expect(doubled.statuses[0].shortfall?.quantity == 200)
    }

    @Test func incompatibleUnitsFallBackToPresence() {
        // Recipe wants cups, fridge tracks grams: can't compare, so presence counts.
        let summary = RecipeReadiness.evaluate(
            lines: ["Flour 2 cups"],
            fridgeItems: [item("Flour", "100", "g")],
            shoppingListNames: []
        )
        #expect(summary.statuses[0].isCovered)
    }

    @Test func unparseableFridgeQuantityFallsBackToPresence() {
        let summary = RecipeReadiness.evaluate(
            lines: ["Eggs 6"],
            fridgeItems: [item("Eggs", "some", "")],
            shoppingListNames: []
        )
        #expect(summary.statuses[0].isCovered)
    }

    @Test func bareCountsAreNotComparedBecauseOneUsuallyMeansOnePack() {
        // "Eggs 1" in the fridge is a carton, not an egg: presence decides.
        let summary = RecipeReadiness.evaluate(
            lines: ["Eggs 6"],
            fridgeItems: [item("Eggs", "1", "ea")],
            shoppingListNames: []
        )
        #expect(summary.statuses[0].isCovered)
        #expect(summary.statuses[0].shortfall == nil)
    }

    @Test func kilogramsAndGramsCompareAcrossTheFamily() {
        let enough = RecipeReadiness.evaluate(
            lines: ["Flour 300g"],
            fridgeItems: [item("Flour", "1", "kg")],
            shoppingListNames: []
        )
        #expect(enough.canMakeNow)

        let short = RecipeReadiness.evaluate(
            lines: ["Flour 1.5kg"],
            fridgeItems: [item("Flour", "800", "g")],
            shoppingListNames: []
        )
        #expect(short.statuses[0].isShort)
        #expect(abs((short.statuses[0].shortfall?.quantity ?? 0) - 0.7) < 0.0001)
        #expect(short.statuses[0].shortfall?.unit == "kg")
    }

    @Test func presenceOnlyIndexPathIsUnchanged() {
        let index = RecipeReadiness.fridgeIndex(for: [item("Butter", "10", "g")])
        let summary = RecipeReadiness.evaluate(lines: ["Butter 250g"], fridgeIndex: index)
        #expect(summary.canMakeNow)
    }
}
