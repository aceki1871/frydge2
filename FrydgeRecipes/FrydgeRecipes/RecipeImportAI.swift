//
//  RecipeImportAI.swift
//  FrydgeRecipes
//
//  Uses Apple's on-device Foundation Models to split messy recipe text (OCR,
//  pasted web text, or a spoken video transcript) into a title, ingredients,
//  and steps. Falls back to RecipeImportOCRParser's regex splitter when the
//  model is unavailable or produces nothing usable.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@available(iOS 26.0, *)
@Generable(description: "A recipe extracted from raw, possibly messy text")
private struct ImportedRecipe {
    @Guide(description: "The recipe title, copied or lightly cleaned from the text. Empty string if no title is present.")
    var title: String

    @Guide(description: "Each ingredient as its own line, copied faithfully from the text, e.g. '2 cups flour'. Never invent an ingredient that isn't in the text.")
    var ingredients: [String]

    @Guide(description: "Each cooking step as its own line, copied or lightly cleaned from the text. Never invent a step that isn't in the text.")
    var steps: [String]
}

enum RecipeImportAI {

    /// Caps input length to fit the on-device model's context window.
    private static let maxInputCharacters = 6000

    /// Attempts an AI-assisted split of raw recipe text. Returns nil if Apple
    /// Intelligence is unavailable/disabled, the input is empty, or the model
    /// produced nothing usable — callers should fall back to
    /// `RecipeImportOCRParser.makeDraft(from:)` in that case.
    static func makeDraft(from text: String) async -> RecipeImportManager.RecipeImportDraft? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let result = await FrydgeIntelligence.generate(
            ImportedRecipe.self,
            instructions: """
                You extract a recipe from raw text that may come from OCR, a pasted web page, or a spoken video transcript.
                Copy the title, ingredients, and steps faithfully from the text, cleaning up obvious transcription noise.
                Never invent an ingredient or step that isn't supported by the text.
                If no title is present, return an empty string for it.
                """,
            prompt: "Recipe text:\n\(String(trimmed.prefix(maxInputCharacters)))",
            logTag: "RecipeImportAI"
        ) else { return nil }

        return draft(title: result.title, ingredients: result.ingredients, steps: result.steps)
    }

    /// Pure mapping from extracted fields to an import draft, kept separate
    /// from the model call so it can be unit tested directly.
    static func draft(title: String, ingredients: [String], steps: [String]) -> RecipeImportManager.RecipeImportDraft? {
        let parsedIngredients = ingredients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { RecipeImportManager.parseIngredientLine($0) }

        let instructions = steps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        guard !parsedIngredients.isEmpty || !instructions.isEmpty else { return nil }

        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(
            sourceURL: nil,
            name: name.isEmpty ? "Imported Recipe" : name,
            ingredients: parsedIngredients,
            instructions: instructions,
            imageURL: nil
        )
    }
}
