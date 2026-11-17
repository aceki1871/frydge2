//
//  RecipeSubstitutionAI.swift
//  FrydgeRecipes
//
//  Uses Apple's on-device Foundation Models to suggest swapping a missing
//  recipe ingredient for something already in the fridge. The model's answer
//  is only ever a suggestion UI — every swap is re-checked against the real
//  missing lines and real fridge items before display, so a hallucinated
//  "use X" can never claim an item that isn't actually in the fridge.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Public output type

struct IngredientSubstitution: Identifiable, Equatable {
    let id = UUID()
    /// The missing ingredient line this swap applies to, exactly as it appears in `RecipeMatch.missing`.
    let missing: String
    /// The fridge item name to use instead, exactly as it appears in the fridge.
    let use: String
    /// Short reason for the swap.
    let note: String
}

// MARK: - Generable intermediate

@available(iOS 26.0, *)
@Generable(description: "Ingredient substitutions using only what's already in the fridge")
private struct AISubstitutions {
    @Guide(description: "Up to 4 substitution suggestions, fewer if few good matches exist", .count(0...4))
    var items: [AISwap]

    @Generable
    struct AISwap {
        @Guide(description: "The missing ingredient, copied from the given list of missing ingredients")
        var missing: String

        @Guide(description: "The fridge item to use instead, copied from the given list of fridge items")
        var use: String

        @Guide(description: "Short reason for the swap, max 8 words, e.g. 'similar richness and tang'")
        var note: String
    }
}

// MARK: - Service

enum RecipeSubstitutionAI {

    static func suggest(missingLines: [String], fridgeItemNames: [String]) async -> [IngredientSubstitution] {
        guard !missingLines.isEmpty, !fridgeItemNames.isEmpty else { return [] }

        guard let result = await FrydgeIntelligence.generate(
            AISubstitutions.self,
            instructions: """
                You suggest ingredient substitutions for a home cook using only what's already in their fridge.
                Only suggest a swap when the fridge item is a genuinely reasonable stand-in for the missing ingredient.
                Copy ingredient and fridge item names exactly as given; never invent an item that isn't in the fridge list.
                If no good substitution exists for a missing ingredient, omit it rather than forcing a weak match.
                """,
            prompt: """
                Missing ingredients:
                \(missingLines.joined(separator: "\n"))

                In fridge:
                \(fridgeItemNames.joined(separator: "\n"))
                """,
            logTag: "RecipeSubstitutionAI"
        ) else { return [] }

        return validate(
            items: result.items.map { (missing: $0.missing, use: $0.use, note: $0.note) },
            missingLines: missingLines,
            fridgeItemNames: fridgeItemNames
        )
    }

    /// Re-anchors each AI swap to a real missing line and a real fridge item
    /// using the same token/synonym matching as the rest of the app, dropping
    /// anything that doesn't resolve. Also drops duplicate suggestions for the
    /// same missing line. Kept free of the model call so it's unit-testable.
    static func validate(
        items: [(missing: String, use: String, note: String)],
        missingLines: [String],
        fridgeItemNames: [String]
    ) -> [IngredientSubstitution] {
        var claimedMissing: Set<String> = []
        var result: [IngredientSubstitution] = []
        for item in items {
            // Missing lines are raw recipe ingredient lines (may carry a
            // quantity), so compare with recipeLineTokens on both sides.
            let itemMissingTokens = IngredientMatcher.recipeLineTokens(item.missing)
            guard let missingMatch = missingLines.first(where: {
                !claimedMissing.contains($0) &&
                IngredientMatcher.tokensMatch(IngredientMatcher.recipeLineTokens($0), itemMissingTokens)
            }) else { continue }

            // Fridge item names are already clean names, so plain tokens() applies.
            let itemUseTokens = IngredientMatcher.tokens(item.use)
            guard let fridgeMatch = fridgeItemNames.first(where: {
                IngredientMatcher.tokensMatch(IngredientMatcher.tokens($0), itemUseTokens)
            }) else { continue }

            claimedMissing.insert(missingMatch)
            let note = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(IngredientSubstitution(missing: missingMatch, use: fridgeMatch, note: note))
        }
        return result
    }
}
