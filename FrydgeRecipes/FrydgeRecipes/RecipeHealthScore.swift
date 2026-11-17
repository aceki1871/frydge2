//
//  RecipeHealthScore.swift
//  FrydgeRecipes
//
//  A deliberately simple 1–10 health score for recipes, derived from the
//  ingredient lines the app already snapshots (no nutrition API needed, works
//  offline and for user-typed recipes). Wholefoods push the score up, refined
//  sugar/fat-heavy ingredients pull it down. It's a rough guide, not dietetics.
//

import SwiftUI

enum RecipeHealthScore {

    struct Rating {
        let score: Int      // 1...10
        let label: String   // "Healthy" / "Balanced" / "Treat"
        let color: Color
    }

    /// Ingredients that lift the score when they appear in a line.
    private static let healthyKeywords: [String] = [
        "spinach", "kale", "broccoli", "cauliflower", "carrot", "tomato",
        "capsicum", "pepper", "courgette", "zucchini", "pumpkin", "kumara",
        "sweet potato", "cabbage", "lettuce", "salad", "cucumber", "celery",
        "mushroom", "onion", "leek", "pea", "green bean", "beans", "lentil",
        "chickpea", "quinoa", "brown rice", "wholemeal", "wholegrain", "oat",
        "barley", "avocado", "apple", "banana", "berry", "berries", "orange",
        "lemon", "lime", "kiwifruit", "mango", "salmon", "tuna", "fish",
        "chicken breast", "turkey", "tofu", "egg", "yoghurt", "yogurt",
        "olive oil", "nut", "almond", "walnut", "seed", "ginger", "garlic",
        "herb", "broth", "stock"
    ]

    /// Ingredients that drag the score down.
    private static let indulgentKeywords: [String] = [
        "sugar", "brown sugar", "icing", "golden syrup", "maple syrup",
        "honey", "caramel", "chocolate", "cocoa", "condensed milk", "cream",
        "double cream", "sour cream", "butter", "lard", "shortening",
        "margarine", "bacon", "sausage", "salami", "chorizo", "pastry",
        "puff pastry", "white bread", "mayonnaise", "deep fry", "deep-fried",
        "fried", "crisps", "chips", "soft drink", "cola", "lolly", "candy",
        "marshmallow", "sprinkles", "nutella", "custard", "ice cream"
    ]

    /// Scores a recipe from its snapshot data. `dietaryTags` gives a small
    /// nudge (VEGAN/VEGETARIAN recipes trend wholefood-heavy).
    static func rating(ingredients: [String], dietaryTags: [String] = []) -> Rating {
        let lines = ingredients
            .map { $0.lowercased() }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var healthy = 0
        var indulgent = 0
        for line in lines {
            if healthyKeywords.contains(where: { line.contains($0) }) { healthy += 1 }
            if indulgentKeywords.contains(where: { line.contains($0) }) { indulgent += 1 }
        }

        // Start neutral; shift by the balance of good vs indulgent lines.
        let total = max(lines.count, 1)
        let balance = Double(healthy - indulgent) / Double(total)   // -1 ... +1
        var score = Int((5.5 + balance * 4.5).rounded())

        let tags = Set(dietaryTags.map { $0.uppercased() })
        if !tags.isDisjoint(with: ["VEGAN", "VEGETARIAN", "V", "VG"]) { score += 1 }

        score = min(max(score, 1), 10)

        switch score {
        case 8...: return Rating(score: score, label: "Healthy", color: .green)
        case 5...: return Rating(score: score, label: "Balanced", color: .orange)
        default:   return Rating(score: score, label: "Treat", color: .red)
        }
    }
}

/// Compact capsule badge, e.g. "♥ 7/10 Balanced".
struct HealthScoreBadge: View {
    let rating: RecipeHealthScore.Rating
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "heart.fill")
                .font(.system(size: 9))
            Text(compact ? "\(rating.score)/10" : "\(rating.score)/10 \(rating.label)")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(rating.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(rating.color.opacity(0.14), in: Capsule())
        .accessibilityLabel("Health score \(rating.score) out of 10, \(rating.label)")
    }
}
