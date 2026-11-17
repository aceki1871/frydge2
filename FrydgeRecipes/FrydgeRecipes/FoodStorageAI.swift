//
//  FoodStorageAI.swift
//  FrydgeRecipes
//
//  Backs up FoodStorageClassifier's keyword lists with Apple's on-device
//  Foundation Models for names none of those keywords recognise. Only ever
//  called for names where FoodStorageClassifier.hasKeywordMatch(for:) is
//  false — recognised names keep using the fast, deterministic heuristic.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@available(iOS 26.0, *)
@Generable(description: "Best storage location and fridge shelf life for a grocery item")
private struct AIStorageGuess {
    @Guide(description: "Where this item should be stored", .anyOf(["Fridge", "Freezer", "Pantry"]))
    var location: String

    @Guide(description: "Days this keeps once stored there", .minimum(1), .maximum(365))
    var shelfLifeDays: Int
}

enum FoodStorageAI {
    /// Returns a normalised location and an absolute expiry date computed
    /// from today, or nil if unavailable/unparseable.
    static func refine(name: String) async -> (location: String, expiryDate: Date)? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let result = await FrydgeIntelligence.generate(
            AIStorageGuess.self,
            instructions: """
                You are a food storage expert. Given a grocery item name, say whether it belongs
                in the Fridge, Freezer, or Pantry, and how many days it keeps once stored there.
                Be realistic and slightly conservative for food safety.
                """,
            prompt: "Item: \(trimmed)",
            logTag: "FoodStorageAI"
        ) else { return nil }

        let location = FoodStorageClassifier.normalize(result.location)
        let days = clampShelfLifeDays(result.shelfLifeDays)
        let expiry = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        return (location, expiry)
    }

    /// Clamps a raw model answer to a sane shelf-life range. Separated out so
    /// it's unit-testable without the model.
    static func clampShelfLifeDays(_ days: Int) -> Int {
        min(365, max(1, days))
    }
}
