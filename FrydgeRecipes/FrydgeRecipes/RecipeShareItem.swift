//
//  RecipeShareItem.swift
//  FrydgeRecipes
//
//  Transferable representation of CloudRecipe for native sharing and drag &
//  drop. Exports the public recipe URL so Messages/Mail render a rich link
//  card from the frydge2.com Open Graph metadata, and the app on the other
//  end can pull the full recipe from the same link.
//

import CoreTransferable
import Foundation

extension CloudRecipe: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.publicRecipeShareURL)
    }

    /// Universal link that opens this recipe in Frydge (or the web preview
    /// for people without the app).
    var publicRecipeShareURL: URL {
        FrydgeRecipeShareService.shareURL(forRecipeID: id)
    }
}
