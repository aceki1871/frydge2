//
//  NutritionScoreResult.swift
//  FrydgeRecipes
//
//  Created by Josh on 12/04/2026.
//


//
//  Nutrition.swift
//  FrydgeRecipes
//

import Foundation

struct NutritionScoreResult: Equatable {
    let score: Int                  // 1...10
    let summaryRows: [(String, String)]

    static func == (lhs: NutritionScoreResult, rhs: NutritionScoreResult) -> Bool {
        lhs.score == rhs.score
            && lhs.summaryRows.count == rhs.summaryRows.count
            && zip(lhs.summaryRows, rhs.summaryRows).allSatisfy { left, right in
                left.0 == right.0 && left.1 == right.1
            }
    }
}

enum NutritionEngine {

    static func score(for nutriments: Any?) -> Int? {
        guard let nutriments else { return nil }

        let energy = firstValue(in: nutriments, keys: ["energyKcal100g", "energyKcal"])
        let sugars = firstValue(in: nutriments, keys: ["sugars100g", "sugars"])
        let saturatedFat = firstValue(in: nutriments, keys: ["saturatedFat100g", "saturatedFat"])
        let sodium = firstValue(in: nutriments, keys: ["sodium100g", "sodium"])
        let protein = firstValue(in: nutriments, keys: ["proteins100g", "proteins"])
        let fiber = firstValue(in: nutriments, keys: ["fiber100g", "fiber"])

        var score = 5.0

        if let energy {
            if energy <= 120 {
                score += 1.5
            } else if energy <= 220 {
                score += 0.5
            } else if energy >= 400 {
                score -= 1.5
            }
        }

        if let sugars {
            if sugars <= 5 {
                score += 1.5
            } else if sugars <= 10 {
                score += 0.5
            } else if sugars >= 15 {
                score -= 1.5
            }
        }

        if let saturatedFat {
            if saturatedFat <= 1.5 {
                score += 1.0
            } else if saturatedFat >= 5 {
                score -= 1.5
            }
        }

        if let sodium {
            if sodium <= 0.12 {
                score += 1.0
            } else if sodium >= 0.4 {
                score -= 1.5
            }
        }

        if let protein {
            if protein >= 8 {
                score += 1.0
            } else if protein >= 4 {
                score += 0.5
            }
        }

        if let fiber {
            if fiber >= 6 {
                score += 1.0
            } else if fiber >= 3 {
                score += 0.5
            }
        }

        let rounded = Int(score.rounded())
        return min(10, max(1, rounded))
    }

    static func summaryRows(for nutriments: Any?) -> [(String, String)] {
        guard let nutriments else { return [] }

        var rows: [(String, String)] = []

        if let v = format(firstValue(in: nutriments, keys: ["energyKcal100g", "energyKcal"]), suffix: " kcal") {
            rows.append(("Energy", v))
        }
        if let v = format(firstValue(in: nutriments, keys: ["proteins100g", "proteins"]), suffix: "g") {
            rows.append(("Protein", v))
        }
        if let v = format(firstValue(in: nutriments, keys: ["carbohydrates100g", "carbohydrates"]), suffix: "g") {
            rows.append(("Carbs", v))
        }
        if let v = format(firstValue(in: nutriments, keys: ["sugars100g", "sugars"]), suffix: "g") {
            rows.append(("Sugars", v))
        }
        if let v = format(firstValue(in: nutriments, keys: ["fat100g", "fat"]), suffix: "g") {
            rows.append(("Fat", v))
        }
        if let v = format(firstValue(in: nutriments, keys: ["saturatedFat100g", "saturatedFat"]), suffix: "g") {
            rows.append(("Sat Fat", v))
        }
        if let v = format(firstValue(in: nutriments, keys: ["fiber100g", "fiber"]), suffix: "g") {
            rows.append(("Fibre", v))
        }
        if let v = format(firstValue(in: nutriments, keys: ["sodium100g", "sodium"]), suffix: "g") {
            rows.append(("Sodium", v))
        }

        return rows
    }

    static func result(for nutriments: Any?) -> NutritionScoreResult? {
        guard let score = score(for: nutriments) else { return nil }
        return NutritionScoreResult(
            score: score,
            summaryRows: summaryRows(for: nutriments)
        )
    }

    static func tone(for score: Int) -> NutritionTone {
        switch score {
        case 1...3:
            return .poor
        case 4...6:
            return .okay
        default:
            return .good
        }
    }

    private static func firstValue(in source: Any, keys: [String]) -> Double? {
        for key in keys {
            if let value = value(for: key, in: source) {
                return value
            }
        }
        return nil
    }

    private static func value(for key: String, in source: Any) -> Double? {
        let mirror = Mirror(reflecting: source)

        for child in mirror.children {
            guard let label = child.label, label == key else { continue }
            return double(from: child.value)
        }

        if let superclass = mirror.superclassMirror {
            for child in superclass.children {
                guard let label = child.label, label == key else { continue }
                return double(from: child.value)
            }
        }

        return nil
    }

    private static func double(from value: Any) -> Double? {
        let mirror = Mirror(reflecting: value)

        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return nil }
            return double(from: child.value)
        }

        switch value {
        case let v as Double:
            return v
        case let v as Float:
            return Double(v)
        case let v as Int:
            return Double(v)
        case let v as Int64:
            return Double(v)
        case let v as NSNumber:
            return v.doubleValue
        case let v as String:
            return Double(v)
        default:
            return nil
        }
    }

    private static func format(_ value: Double?, suffix: String) -> String? {
        guard let value else { return nil }

        if value.rounded(.towardZero) == value {
            return "\(Int(value))\(suffix)"
        }

        return String(format: "%.1f%@", value, suffix)
    }
}

enum NutritionTone {
    case poor
    case okay
    case good
}
