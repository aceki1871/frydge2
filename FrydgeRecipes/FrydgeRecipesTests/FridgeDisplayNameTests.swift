//
//  FridgeDisplayNameTests.swift
//  FrydgeRecipesTests
//
//  Short one-line names for fridge rows and the "≈ … left" amount text.
//

import Testing
@testable import FrydgeRecipes

struct FridgeDisplayNameTests {

    @Test func longScannedProductNameCollapsesToTheFoodWord() {
        #expect(FridgeDisplayName.short(for: "Heinz Seriously Good Mayonnaise Original Mayo 400g") == "Mayo")
        #expect(FridgeDisplayName.short(for: "Anchor Pure New Zealand Butter Salted 500g") == "Butter")
        #expect(FridgeDisplayName.short(for: "Mainland Tasty Aged Cheddar Cheese 1kg") == "Cheddar")
    }

    @Test func shortNamesAreLeftAsTyped() {
        #expect(FridgeDisplayName.short(for: "Milk") == "Milk")
        #expect(FridgeDisplayName.short(for: "Free Range Eggs") == "Free Range Eggs")
        #expect(FridgeDisplayName.short(for: "Butter 500g") == "Butter")
    }

    @Test func packSizesAreStripped() {
        #expect(FridgeDisplayName.short(for: "Eggs 12pk") == "Eggs")
        #expect(FridgeDisplayName.short(for: "Milk 2L") == "Milk")
        #expect(FridgeDisplayName.short(for: "Yoghurt 6 x 100g") == "Yoghurt")
    }

    @Test func unknownLongNamesKeepTheirLastWords() {
        let short = FridgeDisplayName.short(for: "Grandma Ethel's Famous Secret Dressing Thing")
        #expect(short.count <= 17)
        #expect(!short.isEmpty)
    }

    @Test func remainingAmountUsesTheItemsUnit() {
        #expect(FridgeDisplayName.remainingAmount(quantity: "500", unit: "g", quantityUsed: 60) == "≈ 200 g left")
        #expect(FridgeDisplayName.remainingAmount(quantity: "2", unit: "L", quantityUsed: 50) == "≈ 1 L left")
        #expect(FridgeDisplayName.remainingAmount(quantity: "12", unit: "ea", quantityUsed: 25) == "≈ 9 left")
    }

    @Test func remainingAmountIsNilWhenUntouchedUsedUpOrUnparseable() {
        #expect(FridgeDisplayName.remainingAmount(quantity: "500", unit: "g", quantityUsed: 0) == nil)
        #expect(FridgeDisplayName.remainingAmount(quantity: "500", unit: "g", quantityUsed: 100) == nil)
        #expect(FridgeDisplayName.remainingAmount(quantity: "some", unit: "", quantityUsed: 40) == nil)
    }
}
