//
//  LeftoverKeepDaysAI.swift
//  FrydgeRecipes
//
//  Uses Apple's on-device Foundation Models to suggest how many days a
//  cooked dish keeps in the fridge, to prefill LeftoverReminderSheet's
//  "days until expiry" stepper (currently a flat 3-day default for everything).
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@available(iOS 26.0, *)
@Generable(description: "How many days a cooked dish safely keeps in the fridge")
private struct AIKeepDays {
    @Guide(description: "Days the dish keeps in the fridge, typically 1 to 5", .range(1...5))
    var days: Int
}

enum LeftoverKeepDaysAI {
    /// Returns a suggested keep-days value clamped to 1...5, or nil if
    /// unavailable/unparseable. Callers should treat this as a prefill, never
    /// overwriting a value the user has already set.
    static func suggestDays(for dishName: String) async -> Int? {
        let trimmed = dishName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let result = await FrydgeIntelligence.generate(
            AIKeepDays.self,
            instructions: """
                You are a food safety-minded chef. Given a dish name, estimate how many days
                it safely keeps as a fridge leftover before it should be thrown out.
                Be conservative — favour shorter estimates for dishes with seafood, egg, or dairy.
                """,
            prompt: "Dish: \(trimmed)",
            logTag: "LeftoverKeepDaysAI"
        ) else { return nil }

        return clampDays(result.days)
    }

    /// Clamps a raw model answer to a sane keep-days range. Separated out so
    /// it's unit-testable without the model.
    static func clampDays(_ days: Int) -> Int {
        min(5, max(1, days))
    }
}
