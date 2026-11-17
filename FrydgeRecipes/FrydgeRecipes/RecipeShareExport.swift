//
//  RecipeShareExport.swift
//  FrydgeRecipes
//
//  Created by Josh on 09/01/2026.
//


import Foundation
import UniformTypeIdentifiers

/// What you share out of the app.
/// IMPORTANT: serves is forced to "1" for exports by design.
struct RecipeShareExport: Codable {
    var id: String
    var name: String
    var serves: String
    var ingredients: [String]
    var pan: String
    var dietaryTags: [String]
    var steps: [RecipeStep]
    var imageURL: String?

    init(from recipe: CloudRecipe) {
        self.id = recipe.id
        self.name = recipe.name
        self.serves = "1" // ✅ force export default
        self.ingredients = recipe.ingredients
        self.pan = recipe.pan
        self.dietaryTags = recipe.dietaryTags
        self.steps = recipe.steps
        self.imageURL = recipe.imageSourceURL
    }
}

enum RecipeExportWriter {
    static func writeExportFile(for recipe: CloudRecipe) throws -> URL {
        let payload = RecipeShareExport(from: recipe)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)

        let safeName = recipe.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")

        let filename = "\(safeName.isEmpty ? "Recipe" : safeName).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        try data.write(to: url, options: [.atomic])
        return url
    }
}
