//
//  RecipePhotoSearchTests.swift
//  FrydgeRecipesTests
//
//  Pins the query shaping and relevance gates for the by-name photo lookup
//  that stands between a recipe card and its emoji placeholder. No network.
//

import Testing
@testable import FrydgeRecipes

struct RecipePhotoSearchTests {

    // MARK: - Search terms

    @Test func stripsCookDescriptorsAndKeepsTheDish() {
        let terms = RecipePhotoSearch.searchTerms(for: "Quick & Easy Weeknight Chicken Stir-Fry")
        #expect(terms.first == "Chicken Stir-Fry")
        #expect(terms.contains("Stir-Fry"))
    }

    @Test func dropsPossessivesParentheticalsAndSubtitles() {
        #expect(RecipePhotoSearch.searchTerms(for: "Mum's Lasagne (freezer friendly)").first == "Lasagne")
        #expect(RecipePhotoSearch.searchTerms(for: "Pad Thai - the real deal").first == "Pad Thai")
        #expect(RecipePhotoSearch.searchTerms(for: "5-Minute Overnight Oats").first == "Overnight Oats")
    }

    @Test func fallsBackToTrailingWordsInOrder() {
        let terms = RecipePhotoSearch.searchTerms(for: "Thai Green Chicken Curry")
        #expect(terms == ["Thai Green Chicken Curry", "Chicken Curry", "Curry"])
    }

    @Test func neverReturnsDuplicatesOrEmptyTerms() {
        #expect(RecipePhotoSearch.searchTerms(for: "Pavlova") == ["Pavlova"])
        #expect(RecipePhotoSearch.searchTerms(for: "   ").isEmpty)
        // Everything filtered out: fall back to the raw name rather than nothing.
        #expect(RecipePhotoSearch.searchTerms(for: "Easy Quick Recipe") == ["Easy Quick Recipe"])
    }

    // MARK: - Relevance gates

    @Test func hitMustShareAWordWithTheQuery() {
        #expect(RecipePhotoSearch.sharesWord("Green curry Thai dish", with: "Thai Green Chicken Curry"))
        #expect(!RecipePhotoSearch.sharesWord("Waterloo railway station", with: "Chicken Curry"))
    }

    @Test func hitMustReadAsFood() {
        #expect(RecipePhotoSearch.looksLikeFood("Lasagne Italian pasta dish"))
        #expect(!RecipePhotoSearch.looksLikeFood("Anchor nautical device"))
    }
}
