//
//  RecipeIngredientParserTests.swift
//  FrydgeRecipes Tests
//
//  Free-text recipe line → name / quantity / unit (RecipeIngredientParser.swift).
//

import Testing
import Foundation
@testable import FrydgeRecipes

@Suite("Recipe ingredient parser")
struct RecipeIngredientParserTests {

    @Test("Leading amounts still parse")
    func leadingAmounts() {
        let a = RecipeIngredientParser.parse("2 cups flour")
        #expect(a.name == "flour" && a.quantity == "2" && a.unit == "cups")

        let b = RecipeIngredientParser.parse("500g butter")
        #expect(b.name == "butter" && b.quantity == "500" && b.unit == "g")

        let c = RecipeIngredientParser.parse("2 x eggs")
        #expect(c.name == "eggs" && c.quantity == "2" && c.unit == "")
    }

    @Test("Trailing count moves out of the name")
    func trailingCount() {
        // Regression: "Onion 2" landed on the shopping list as "Onion 2 x1".
        let a = RecipeIngredientParser.parse("Onion 2")
        #expect(a.name == "Onion" && a.quantity == "2" && a.unit == "")

        let b = RecipeIngredientParser.parse("Onion x2")
        #expect(b.name == "Onion" && b.quantity == "2" && b.unit == "")

        let c = RecipeIngredientParser.parse("Icing sugar 500 g")
        #expect(c.name == "Icing sugar" && c.quantity == "500" && c.unit == "g")

        let d = RecipeIngredientParser.parse("Salt 1/2 tsp")
        #expect(d.name == "Salt" && d.quantity == "1/2" && d.unit == "tsp")
    }

    @Test("Lines without a recognisable amount are left whole")
    func noAmount() {
        let a = RecipeIngredientParser.parse("Fresh basil")
        #expect(a.name == "Fresh basil" && a.quantity == "1" && a.unit == "")

        // "drops" isn't a unit we size, so the line stays intact rather than half-parsed.
        let b = RecipeIngredientParser.parse("Pink food colouring 3 drops")
        #expect(b.name == "Pink food colouring 3 drops" && b.quantity == "1")

        // A bare number is never split into an empty name.
        let c = RecipeIngredientParser.parse("2")
        #expect(c.name == "2" && c.quantity == "1")
    }

    @Test("splitTrailingCount only strips a bare count")
    func splitTrailingCount() {
        let split = RecipeIngredientParser.splitTrailingCount("Onion 2")
        #expect(split?.name == "Onion" && split?.quantity == "2")

        #expect(RecipeIngredientParser.splitTrailingCount("Onion") == nil)
        // Has a unit: already structured, leave it for the pack-size rules.
        #expect(RecipeIngredientParser.splitTrailingCount("Butter 500 g") == nil)
        #expect(RecipeIngredientParser.splitTrailingCount("2") == nil)
    }
}
