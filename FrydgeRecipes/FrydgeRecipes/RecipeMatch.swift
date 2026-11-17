//
//  RecipeMatch.swift
//  FrydgeRecipes
//
//  The single source of truth for "how much of this recipe can I make from
//  what's in the frydge?". Every screen that shows a match percentage, a
//  have/missing count or a "Recipes using this" list goes through here, so the
//  recipe list, recipe detail, item detail sheet and fridge suggestions always
//  agree. Matching is token/synonym based (IngredientMatcher via
//  RecipeReadiness) against `storedIngredients` — the legacy `ingredients`
//  string list is no longer consulted.
//

import Foundation

/// Fridge coverage for one recipe.
struct RecipeMatch: Equatable {
    /// Number of ingredient lines on the recipe.
    let total: Int
    /// Lines covered by a fridge item or a pantry staple (salt, water…).
    let haveCount: Int
    /// Ingredient lines (as written on the recipe) that still need buying.
    let missing: [String]

    var percent: Double { total == 0 ? 0 : Double(haveCount) / Double(total) }
    var percentText: String { "\(Int((percent * 100).rounded()))%" }
    var isComplete: Bool { total > 0 && missing.isEmpty }

    static let empty = RecipeMatch(total: 0, haveCount: 0, missing: [])
}

extension FrydgeManager {

    /// Raw ingredients that can still go into a recipe: not leftovers, not used up.
    var matchableFridgeItems: [StoredIngredient] {
        storedIngredients.filter { $0.lifecycle == .fridge && $0.quantityUsed < 100 }
    }

    /// Inverted index over `matchableFridgeItems`, in the same order. Rebuilt
    /// only when the matchable names change, so scoring a whole recipe list
    /// indexes the fridge once instead of once per recipe.
    var fridgeMatchIndex: IngredientMatcher.Index {
        let names = matchableFridgeItems.map(\.name)
        if let cached = matchIndexCache, cached.names == names { return cached.index }
        let index = IngredientMatcher.Index(names: names)
        matchIndexCache = (names, index)
        return index
    }

    /// Coverage of `recipe` by the current fridge contents.
    func recipeMatch(for recipe: CloudRecipe) -> RecipeMatch {
        recipeMatch(forIngredientLines: recipe.ingredients)
    }

    /// Coverage of a list of raw ingredient lines ("500g butter", "2 eggs").
    /// Amount-aware: a line only counts as "have" when the matching fridge
    /// item has enough left for the (serves-scaled) quantity, where both
    /// sides are parseable. `scale` is serves chosen ÷ serves authored.
    func recipeMatch(forIngredientLines lines: [String], scale: Double = 1) -> RecipeMatch {
        let summary = RecipeReadiness.evaluate(
            lines: lines,
            fridgeIndex: fridgeMatchIndex,
            fridgeItems: matchableFridgeItems,
            scale: scale
        )
        return RecipeMatch(
            total: summary.total,
            haveCount: summary.haveCount,
            missing: summary.missing.map(\.displayLine)
        )
    }

    /// Fraction (0…1) of `recipeIngredients` covered by the fridge.
    func matchPercentage(for recipeIngredients: [String]) -> Double {
        recipeMatch(forIngredientLines: recipeIngredients).percent
    }

    /// The fridge item that satisfies a recipe ingredient line, if any.
    /// Uses the same cleaning and token matching as `recipeMatch`, so a line
    /// counted as "have" always resolves to an item here.
    func matchedFridgeItem(for ingredientLine: String) -> StoredIngredient? {
        let tokens = IngredientMatcher.recipeLineTokens(ingredientLine)
        guard !tokens.isEmpty else { return nil }
        let items = matchableFridgeItems
        guard let position = fridgeMatchIndex.firstMatch(tokens), position < items.count else { return nil }
        return items[position]
    }

    /// True when a recipe ingredient line is in the fridge.
    func hasIngredient(_ ingredientLine: String) -> Bool {
        matchedFridgeItem(for: ingredientLine) != nil
    }

    /// Recipes that use `item`, best fridge match first. Used by the item
    /// detail sheet's "Recipes using this" section and the expiry reminder.
    func recipesUsing(_ item: StoredIngredient, from recipes: [CloudRecipe]) -> [(recipe: CloudRecipe, match: RecipeMatch)] {
        let itemTokens = IngredientMatcher.tokens(item.name)
        guard !itemTokens.isEmpty else { return [] }
        return recipes
            // One set intersection per recipe; line tokens are memoised.
            .filter { IngredientMatcher.tokensMatch(IngredientMatcher.recipeTokens($0.ingredients), itemTokens) }
            .map { ($0, recipeMatch(for: $0)) }
            .sorted { a, b in
                if a.match.percent != b.match.percent { return a.match.percent > b.match.percent }
                return a.recipe.name.localizedCaseInsensitiveCompare(b.recipe.name) == .orderedAscending
            }
    }
}

// MARK: - Expiry reminder recipe suggestions

extension FrydgeManager {

    /// userInfo keys on the EXPIRY_REMINDER notification. Mirrored by hand in
    /// ShoppingListNotificationExtension/NotificationViewController.swift (a
    /// separate target), so keep both in sync.
    enum ExpiryNotificationKeys {
        static let itemID = "itemID"
        static let itemEmoji = "itemEmoji"
        static let expiryText = "expiryText"
        static let expiringItems = "expiringItems"
        /// `[[String: String]]` with `id`, `name`, `match`, `imageURL`.
        static let suggestedRecipes = "suggestedRecipes"
        /// "500 g", "2" — the amount in the frydge, for the expanded card.
        static let quantityText = "quantityText"
        /// `FrydgeManager.ExpiryStage` raw value: soon / today / expired.
        static let stage = "stage"
        /// App-group UserDefaults key the content extension writes when a
        /// recipe row is tapped; the app reads it on the default action.
        static let tappedRecipeID = "notificationOpenRecipeID_v1"
        /// Standard-defaults key the app delegate hands the tapped recipe to
        /// the SwiftUI app with, so a cold launch can still pick it up.
        static let pendingOpenRecipeID = "frydge.pendingOpenRecipeID"
    }

    /// The recipe library as last saved by RecipeListModel. Read straight from
    /// its cache so notification scheduling doesn't need a view model.
    nonisolated static func cachedRecipesForSuggestions() -> [CloudRecipe] {
        CachedRecipeLibrary.shared.load()
    }

    /// Up to `limit` recipes that use `item`, as a plist-safe payload for the
    /// expiry notification: best fridge match first, so the top suggestion is
    /// the one the user can most likely cook tonight.
    func expirySuggestions(for item: StoredIngredient, from recipes: [CloudRecipe], limit: Int = 3) -> [[String: String]] {
        Self.expirySuggestions(
            for: item,
            from: recipes,
            fridgeIndex: fridgeMatchIndex,
            fridgeItems: matchableFridgeItems,
            limit: limit
        )
    }

    /// Same result as the instance method, computed against a snapshot of the
    /// fridge so the expiry scheduler can run it off the main actor. Matching
    /// every fridge item against the whole library is the expensive part of
    /// rescheduling reminders and must not block the UI.
    nonisolated static func expirySuggestions(
        for item: StoredIngredient,
        from recipes: [CloudRecipe],
        fridgeIndex: IngredientMatcher.Index,
        fridgeItems: [StoredIngredient],
        limit: Int = 3
    ) -> [[String: String]] {
        let itemTokens = IngredientMatcher.tokens(item.name)
        guard !itemTokens.isEmpty else { return [] }

        let ranked: [(recipe: CloudRecipe, match: RecipeMatch)] = recipes
            .filter { IngredientMatcher.tokensMatch(IngredientMatcher.recipeTokens($0.ingredients), itemTokens) }
            .map { recipe in
                let summary = RecipeReadiness.evaluate(
                    lines: recipe.ingredients,
                    fridgeIndex: fridgeIndex,
                    fridgeItems: fridgeItems
                )
                let match = RecipeMatch(
                    total: summary.total,
                    haveCount: summary.haveCount,
                    missing: summary.missing.map(\.displayLine)
                )
                return (recipe, match)
            }
            .sorted { a, b in
                if a.match.percent != b.match.percent { return a.match.percent > b.match.percent }
                return a.recipe.name.localizedCaseInsensitiveCompare(b.recipe.name) == .orderedAscending
            }

        return ranked.prefix(limit).map { entry in
            [
                "id": entry.recipe.id,
                "name": entry.recipe.name,
                "match": entry.match.percentText,
                "imageURL": entry.recipe.imageSourceURL ?? ""
            ]
        }
    }

    /// "Use it up: Pancakes, French toast or Béchamel." for the collapsed banner.
    nonisolated static func useItUpLine(from suggestions: [[String: String]]) -> String? {
        let names = suggestions.compactMap { $0["name"] }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        let list: String
        if names.count == 1 {
            list = names[0]
        } else {
            list = names.dropLast().joined(separator: ", ") + " or " + names[names.count - 1]
        }
        return "Use it up: \(list)."
    }
}
