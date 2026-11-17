//
//  RecipePresentationTests.swift
//  FrydgeRecipes Tests
//
//  Display-name tidying and preferred-store offer selection
//  (RecipePresentation.swift).
//

import Testing
import Foundation
@testable import FrydgeRecipes

@Suite("Recipe presentation")
struct RecipePresentationTests {

    @Test("Shouted and all-lowercase names are title-cased, mixed case is left alone")
    func displayNameCasing() {
        #expect(RecipeNameFormatter.display("CHICKEN AND LEEK PIE") == "Chicken and Leek Pie")
        #expect(RecipeNameFormatter.display("beef stir-fry with noodles") == "Beef Stir-Fry with Noodles")
        #expect(RecipeNameFormatter.display("Mum's Pav") == "Mum's Pav")
        #expect(RecipeNameFormatter.display("BBQ Ribs") == "BBQ Ribs")
    }

    @Test("Whitespace, trailing punctuation and import labels are stripped")
    func displayNameNoise() {
        #expect(RecipeNameFormatter.display("  Pad   Thai . ") == "Pad Thai")
        #expect(RecipeNameFormatter.display("Recipe: Lemon Chicken") == "Lemon Chicken")
        #expect(RecipeNameFormatter.display("How to make Pancakes -") == "Pancakes")
        #expect(RecipeNameFormatter.display("") == "")
    }

    @Test("Preferred store wins when it stocks the item, else the cheapest anywhere")
    func preferredStoreSelection() {
        func offer(_ store: String, _ price: Double) -> StockAvailability.StoreOffer {
            StockAvailability.StoreOffer(
                store: store, productURL: URL(string: "https://example.com/\(store)")!,
                currencyCode: "NZD", price: price, promoText: nil, isProbablyMatch: true,
                storeCoordinate: nil, distanceMeters: nil, productTitle: nil, imageURL: nil, detailsText: nil
            )
        }
        let offers = [offer("Pak'nSave Sylvia Park", 3.20), offer("New World", 3.90), offer("New World Mt Roskill", 3.70)]

        #expect(PreferredStore.bestOffer(from: offers, preferred: nil)?.store == "Pak'nSave Sylvia Park")
        #expect(PreferredStore.bestOffer(from: offers, preferred: "New World")?.price == 3.70)
        #expect(PreferredStore.bestOffer(from: offers, preferred: "Woolworths")?.store == "Pak'nSave Sylvia Park")
        #expect(PreferredStore.bestOffer(from: [], preferred: "New World") == nil)
    }

    @Test("Store brands are recognised with or without a branch")
    func storeBrand() {
        #expect(PreferredStore.brand(of: "New World Mt Roskill") == "New World")
        #expect(PreferredStore.brand(of: "Pak’nSave Sylvia Park") == "Pak’nSave")
        #expect(PreferredStore.brand(of: "Woolworths") == "Woolworths")
        #expect(PreferredStore.matches("New World Mt Roskill", preferred: "New World"))
        #expect(!PreferredStore.matches("New World", preferred: "Woolworths"))
    }
}
