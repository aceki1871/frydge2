//
//  RecipeDraft.swift
//  FrydgeRecipes
//
//  Created by Josh on 07/01/2026.
//


//  RecipeDraft.swift
//  FrydgeRecipes
//
//  Created by Josh on 07/01/2026.
//

import Foundation
import UIKit

/// Local, unsaved recipe data used by the "multi-window" creation flow.
/// This is intentionally NOT tied to CloudKit until the final "Save" step.
struct RecipeDraft: Equatable {
    var name: String
    var image: UIImage?
    var ingredients: [String]
    var steps: [RecipeStep]

    init(
        name: String = "",
        image: UIImage? = nil,
        ingredients: [String] = [],
        steps: [RecipeStep] = []
    ) {
        self.name = name
        self.image = image
        self.ingredients = ingredients
        self.steps = steps
    }

    var canProceedFromName: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSave: Bool {
        canProceedFromName && !ingredients.isEmpty && !steps.isEmpty
    }
}