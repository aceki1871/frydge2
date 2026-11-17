//
//  DietaryRestrictionsTests.swift
//  FrydgeRecipes Tests
//
//  The can't / won't eat matcher behind the Profile → Dietary rules
//  (DietaryRestrictions.swift).
//

import Testing
import Foundation
@testable import FrydgeRecipes

@Suite("Dietary restrictions")
struct DietaryRestrictionsTests {

    private func rule(_ term: String, _ severity: DietaryRestriction.Severity = .cannot) -> DietaryRestriction {
        DietaryRestriction(term: term, severity: severity)
    }

    private func flags(
        _ name: String,
        ingredients: String? = nil,
        rules: [DietaryRestriction],
        implied: [(term: String, impliedBy: String)] = []
    ) -> [DietaryFlag] {
        DietaryRestrictionMatcher.flags(name: name, ingredientsText: ingredients, restrictions: rules, impliedTerms: implied)
    }

    @Test("A whole-word match on the product name is flagged, plurals included")
    func nameWholeWord() {
        let rules = [rule("peanut")]
        #expect(flags("Salted Peanuts 200g", rules: rules).first?.evidence == .name)
        #expect(flags("Peanut Butter", rules: rules).count == 1)
        #expect(flags("Pine nuts", rules: rules).isEmpty)
    }

    @Test("A food family rule catches specific foods through the shared matcher")
    func nameFamily() {
        let rules = [rule("cheese", .avoid)]
        let found = flags("Mainland Tasty Cheddar", rules: rules)
        #expect(found.count == 1)
        #expect(found.first?.severity == .avoid)
        #expect(found.first?.evidence == .name)
    }

    @Test("Ingredients lists are searched by whole word and the matching entry is quoted")
    func ingredientsSnippet() {
        let rules = [rule("milk")]
        let text = "Sugar, cocoa butter, skimmed MILK powder (12%), emulsifier (soy lecithin), vanilla"
        let found = flags("Chocolate Bar", ingredients: text, rules: rules)
        #expect(found.count == 1)
        #expect(found.first?.evidence == .ingredients(snippet: "skimmed MILK powder"))
        #expect(found.first?.headline == "Lists skimmed MILK powder in its ingredients")
    }

    @Test("E-numbers match however the label writes them")
    func additiveCodes() {
        let rules = [rule("E621", .avoid)]
        #expect(!flags("Instant Noodles", ingredients: "Noodles, flavour enhancer (621), salt", rules: rules).isEmpty)
        #expect(!flags("Instant Noodles", ingredients: "Noodles, flavour enhancer (E 621), salt", rules: rules).isEmpty)
        #expect(!flags("Instant Noodles", ingredients: "Noodles, e621, salt", rules: rules).isEmpty)
        #expect(flags("Instant Noodles", ingredients: "Noodles, E6210, salt", rules: rules).isEmpty)
        // A code is a whole word only: "621ml" is a volume, not an additive.
        #expect(flags("Beef Stock 621ml", rules: [rule("E621")]).isEmpty)
    }

    @Test("Multi-word terms match as a phrase, with punctuation and case folded")
    func phrases() {
        let rules = [rule("palm oil", .avoid), rule("cow's milk")]
        #expect(!flags("Spread", ingredients: "Vegetable oils (Palm-Oil, rapeseed), water", rules: rules).isEmpty)
        #expect(flags("Spread", ingredients: "Vegetable oils (sunflower), palm kernel extract, oil", rules: rules).isEmpty)
        #expect(!flags("Yoghurt", ingredients: "COWS MILK, cultures", rules: rules).isEmpty)
    }

    @Test("Blocking flags come first and each term is reported once")
    func orderingAndDedupe() {
        let rules = [rule("soy", .avoid), rule("peanut", .cannot), rule("Peanut", .avoid)]
        let found = flags("Satay Sauce", ingredients: "Peanuts, soy sauce, chilli", rules: rules)
        #expect(found.map(\.term) == ["peanut", "soy"])
        #expect(found[0].isBlocking)
        #expect(!found[1].isBlocking)
    }

    @Test("Profile tags imply 'prefer not to' terms, but a typed rule wins")
    func impliedTerms() {
        let implied = [(term: "milk", impliedBy: "Dairy-free")]
        let soft = flags("Whole Milk 2L", rules: [], implied: implied)
        #expect(soft.count == 1)
        #expect(soft.first?.severity == .avoid)
        #expect(soft.first?.reason == "Dairy-free preference")

        let hard = flags("Whole Milk 2L", rules: [rule("milk")], implied: implied)
        #expect(hard.count == 1)
        #expect(hard.first?.isBlocking == true)
        #expect(hard.first?.impliedBy == nil)
    }

    @Test("Nothing to check means nothing flagged")
    func empty() {
        #expect(flags("Peanuts", rules: []).isEmpty)
        #expect(flags("", rules: [rule("peanut")]).isEmpty)
        #expect(flags("   ", ingredients: "peanuts", rules: [rule("peanut")]).isEmpty == false)
    }

    @Test("Restrictions round-trip through JSON")
    func codable() throws {
        let original = [rule("peanuts"), DietaryRestriction(term: "palm oil", severity: .avoid, note: "orangutans")]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([DietaryRestriction].self, from: data)
        #expect(decoded == original)
    }
}
