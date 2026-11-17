//
//  DefaultRecipePack.swift
//  FrydgeRecipes
//
//  Bundled default recipe pack utilities. This file does not load recipes at
//  startup by itself; RecipeListModel must opt in by calling merged(into:).
//

import Foundation

enum DefaultRecipePack {

    static let recipes: [CloudRecipe] = {
        guard let url = Bundle.main.url(forResource: "DefaultRecipes", withExtension: "json")
                ?? Bundle.main.url(forResource: "DefaultRecipes ", withExtension: "json") else {
            assertionFailure("DefaultRecipes.json not found in app bundle.")
            return []
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([CloudRecipe].self, from: data)
        } catch {
            assertionFailure("Failed to decode DefaultRecipes.json: \(error)")
            return []
        }
    }()

    private static let packIDs: Set<String> = Set(recipes.map(\.id))

    static func merged(into existing: [CloudRecipe]) -> [CloudRecipe] {
        let packByID = Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) })
        let existingIDs = Set(existing.map(\.id))

        // Keep the live CloudKit version (has imageAsset, timestamps, etc.)
        // but patch in the bundled imageSourceURL/imageCredit when CloudKit has none —
        // the bundled JSON carries Wikimedia image URLs that CloudKit records may lack.
        let updatedExisting = existing.map { recipe -> CloudRecipe in
            guard let bundled = packByID[recipe.id] else { return recipe }
            let needsURL = recipe.imageSourceURL == nil || recipe.imageSourceURL?.isEmpty == true
            guard needsURL, let bundledURL = bundled.imageSourceURL, !bundledURL.isEmpty else {
                return recipe
            }
            var patched = recipe
            patched.imageSourceURL = bundledURL
            patched.imageCredit = bundled.imageCredit
            return patched
        }

        let missing = recipes.filter { !existingIDs.contains($0.id) }
        return updatedExisting + missing
    }

    static func isDefault(_ recipe: CloudRecipe) -> Bool {
        packIDs.contains(recipe.id)
    }

    /// Same check for callers that only hold the recipe id (thumbnail rows).
    static func isDefault(id: String) -> Bool {
        packIDs.contains(id)
    }
}
