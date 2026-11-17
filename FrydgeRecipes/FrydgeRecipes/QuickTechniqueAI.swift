//
//  QuickTechniqueAI.swift
//  FrydgeRecipes
//
//  On-demand fallback for ChefTechniquesView when the bundled technique
//  library has nothing relevant for the current step. Uses Apple's
//  on-device Foundation Models to generate a short explanation instead.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Public output type

struct QuickTechnique: Equatable {
    let title: String
    let steps: [String]
    let tip: String
}

// MARK: - Generable intermediate

@available(iOS 26.0, *)
@Generable(description: "A short cooking technique explanation for one recipe step")
private struct AIQuickTechnique {
    @Guide(description: "A short technique title, e.g. 'Deglazing a pan'")
    var title: String

    @Guide(description: "Up to 4 short, practical steps", .count(1...4))
    var steps: [String]

    @Guide(description: "One practical tip, max 20 words")
    var tip: String
}

// MARK: - Service

enum QuickTechniqueAI {
    static func technique(for stepText: String) async -> QuickTechnique? {
        let trimmedStep = stepText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStep.isEmpty else { return nil }

        guard let result = await FrydgeIntelligence.generate(
            AIQuickTechnique.self,
            instructions: """
                You are a chef explaining one cooking technique to a home cook for a single recipe step.
                Keep steps short and practical. Give exactly one useful, specific tip.
                """,
            prompt: "Recipe step: \(trimmedStep)",
            logTag: "QuickTechniqueAI"
        ) else { return nil }

        let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let steps = result.steps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !title.isEmpty, !steps.isEmpty else { return nil }

        return QuickTechnique(title: title, steps: steps, tip: result.tip.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
