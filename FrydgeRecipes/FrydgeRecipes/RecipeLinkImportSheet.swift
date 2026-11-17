//
//  RecipeLinkImportSheet.swift
//  FrydgeRecipes
//
//  The weekly planner's "add a recipe from a link" entry point. It is the
//  same import window as everywhere else (link or text, paste, snap, shared
//  links) with the saved recipe handed back to the caller so it can go
//  straight onto a day. The recipe is saved to the library exactly like any
//  other import, so it shows up in Recipes too.
//

import SwiftUI

struct RecipeLinkImportSheet: View {
    var title: String = "Add from Link"
    /// Called once the wizard has saved the recipe.
    var onImported: (CloudRecipe) -> Void

    var body: some View {
        RecipeImportView(title: title, onImported: onImported)
    }
}
