//
//  ProductShorthandTests.swift
//  FrydgeRecipesTests
//
//  Shopping-list rows show a short label derived from the full product name.
//  These pin down that branded snacks keep their product word rather than
//  collapsing to a flavour.
//

import Testing
@testable import FrydgeRecipes

struct ProductShorthandTests {

    @Test func brandedSnackKeepsProductNotFlavour() {
        #expect(ProductShorthand.short(for: "Doritos Chilli Heatwave") == "Doritos")
        #expect(ProductShorthand.short(for: "Doritos Chilli Heatwave 170g") == "Doritos")
    }

    @Test func snackKeywordsAreRecognised() {
        #expect(ProductShorthand.short(for: "Bluebird Original Potato Chips 150g") == "Potato Chips")
        #expect(ProductShorthand.short(for: "Mexicano Corn Chips Chilli") == "Corn Chips")
        #expect(ProductShorthand.short(for: "Brand Popcorn Sweet & Salted 150g") == "Popcorn")
        #expect(ProductShorthand.short(for: "Chocolate Chips") == "Chocolate Chips")
    }

    @Test func flavourPairFallsBackToBrand() {
        #expect(ProductShorthand.short(for: "Bluebird Salt & Vinegar 150g") == "Bluebird")
    }

    @Test func plainIngredientsStillShowTheFood() {
        #expect(ProductShorthand.short(for: "Chilli") == "Chilli")
        #expect(ProductShorthand.short(for: "Red Chilli") == "Chilli")
        #expect(ProductShorthand.short(for: "Chilli Powder") == "Chilli Powder")
        #expect(ProductShorthand.short(for: "Sweet Chilli Sauce") == "Sweet Chilli Sauce")
        #expect(ProductShorthand.short(for: "Lemon Chicken") == "Chicken")
        #expect(ProductShorthand.short(for: "Chocolate Milk") == "Milk")
        #expect(ProductShorthand.short(for: "Milk Chocolate") == "Chocolate")
    }

    @Test func snackEmojiBeatsFlavourEmoji() {
        #expect(FoodEmoji.emoji(for: "Doritos Chilli Heatwave") == "🌽")
        #expect(FoodEmoji.emoji(for: "Chilli") == "🌶️")
    }
}
