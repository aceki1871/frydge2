//
//  RecipeImportOCRParser.swift
//  FrydgeRecipes
//
//  Created by Josh on 13/01/2026.
//

import Foundation

enum RecipeImportOCRParser {

    static func makeDraft(from text: String) -> RecipeImportManager.RecipeImportDraft? {
        let cleaned = normalize(text)
        let lines = cleaned
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return nil }

        let name = guessTitle(from: lines) ?? "Imported Recipe"
        let segments = segment(lines: lines)
        let ingredients = segments.ingredients.map {
            RecipeImportManager.parseIngredientLine(stripListMarker($0))
        }
        let instructions = numberedInstructions(segments.instructions)

        if ingredients.isEmpty && instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }

        return .init(
            sourceURL: nil,
            name: name,
            ingredients: ingredients,
            instructions: instructions,
            imageURL: nil
        )
    }

    private static func normalize(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "•", with: "\n- ")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
    }

    private static func guessTitle(from lines: [String]) -> String? {
        for line in lines.prefix(8) {
            let trimmed = stripListMarker(line)
            let lower = normalizedHeader(trimmed)
            if isIngredientsHeader(lower) || isInstructionsHeader(lower) { continue }
            if looksLikeIngredient(trimmed) { continue }
            if trimmed.count >= 4 && trimmed.count <= 80 { return trimmed }
        }
        return nil
    }

    private struct Segments {
        var ingredients: [String]
        var instructions: [String]
    }

    /// Splits the scanned lines into an ingredient block and a method block.
    ///
    /// Recipe-book pages fall into three layouts, in priority order:
    /// 1. An explicit "Method"/"Instructions" header — split cleanly on it.
    /// 2. Only an "Ingredients" header — ingredients follow it, method is inferred after.
    /// 3. No headers at all — infer the boundary where the quantified ingredient list
    ///    gives way to the first prose sentence (the classic title → list → steps layout).
    private static func segment(lines: [String]) -> Segments {
        let headers = lines.map { normalizedHeader($0) }
        let ingredientHeaderIndex = headers.firstIndex(where: isIngredientsHeader)
        let instructionHeaderIndex = headers.firstIndex(where: isInstructionsHeader)

        // Where the ingredient block begins: right after an "Ingredients" header,
        // otherwise the line after the title.
        let bodyStart = ingredientHeaderIndex.map { $0 + 1 } ?? 1
        guard bodyStart <= lines.count else { return Segments(ingredients: [], instructions: []) }

        // Layout 1/2: explicit method header — everything before it is ingredients.
        if let instructionHeaderIndex, instructionHeaderIndex >= bodyStart {
            let ingredientChunk = Array(lines[bodyStart..<instructionHeaderIndex])
            let instructionChunk = instructionHeaderIndex + 1 < lines.count
                ? Array(lines[(instructionHeaderIndex + 1)...])
                : []
            return Segments(
                ingredients: filterIngredients(ingredientChunk),
                instructions: instructionChunk.filter { !isSectionHeader($0) }
            )
        }

        // Layout 3: no method header — infer where the list ends and the method begins.
        return inferHeaderlessSplit(Array(lines[bodyStart...]))
    }

    /// Walks the body collecting ingredient-like lines until the first clear prose
    /// sentence appears; that sentence and everything after it become the method.
    private static func inferHeaderlessSplit(_ body: [String]) -> Segments {
        var sawIngredient = false
        var splitIndex = body.count
        for (i, line) in body.enumerated() {
            if isSectionHeader(line) { continue }
            if looksLikeIngredient(line) {
                sawIngredient = true
                continue
            }
            if sawIngredient && looksLikeInstructionStep(line) {
                splitIndex = i
                break
            }
        }

        let ingredients = filterIngredients(Array(body[0..<splitIndex]))
        let instructions = Array(body[splitIndex...]).filter { !isSectionHeader($0) }
        return Segments(ingredients: ingredients, instructions: instructions)
    }

    /// Keeps the plausibly-ingredient lines from a bounded region, falling back to the
    /// raw (non-header) lines if the strict filter removes everything.
    private static func filterIngredients(_ chunk: [String]) -> [String] {
        let cleaned = chunk.filter { !isSectionHeader($0) }
        let plausible = cleaned.filter(looksLikeIngredient)
        return plausible.isEmpty ? Array(cleaned.prefix(40)) : plausible
    }

    private static func numberedInstructions(_ rawLines: [String]) -> String {
        let steps = rawLines
            .map(stripListMarker)
            .filter { !$0.isEmpty && !isSectionHeader($0) }
            .prefix(40)

        return steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    /// A method step reads as a sentence: several words, or a shorter clause that ends
    /// in terminal punctuation. This deliberately excludes short unquantified ingredient
    /// lines such as "Salt and pepper to taste".
    private static func looksLikeInstructionStep(_ s: String) -> Bool {
        let trimmed = stripListMarker(s)
        let wordCount = trimmed.split(separator: " ").count
        if wordCount >= 6 { return true }
        if wordCount >= 4 && (trimmed.hasSuffix(".") || trimmed.hasSuffix("!")) { return true }
        return false
    }

    private static func looksLikeIngredient(_ s: String) -> Bool {
        let trimmed = stripListMarker(s)
        guard trimmed.count >= 2 else { return false }
        if trimmed.first?.isNumber == true { return true }

        let lower = " \(trimmed.lowercased()) "
        let units = [" g ", " kg", " ml", " litre", " liter", " tbsp", " tsp", " cup", " cups", " oz", " lb", " can ", " cans ", " clove", " cloves"]
        if units.contains(where: { lower.contains($0) }) { return true }
        if s.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-") { return true }
        return false
    }

    private static func stripListMarker(_ s: String) -> String {
        s
            .replacingOccurrences(of: #"^\s*[-*]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*\d+\s*[\.)]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedHeader(_ s: String) -> String {
        stripListMarker(s)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " :.-"))
    }

    private static func isSectionHeader(_ s: String) -> Bool {
        let header = normalizedHeader(s)
        return isIngredientsHeader(header) || isInstructionsHeader(header)
    }

    private static func isIngredientsHeader(_ s: String) -> Bool {
        s.hasPrefix("ingredient")   // catches "ingredients (serves 4)", "ingredient list"
            || s == "what you need" || s == "you will need" || s == "you'll need"
    }

    private static func isInstructionsHeader(_ s: String) -> Bool {
        s.hasPrefix("method")       // "method", "method:"
            || s.hasPrefix("instruction") || s.hasPrefix("direction")
            || s == "steps" || s == "step" || s == "preparation" || s == "how to make"
    }
}
