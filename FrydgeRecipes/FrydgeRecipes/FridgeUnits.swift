//
//  FridgeUnits.swift
//  FrydgeRecipes
//
//  Small helpers for combining and displaying fridge quantities so that, e.g.,
//  two 500 g steaks read as 1 kg. Weight is normalised in grams, volume in ml.
//

import Foundation

enum FridgeUnits {

    /// Dimension a unit belongs to, so we only ever combine like with like.
    private enum Dimension { case weight, volume, count, unknown }

    private static func dimension(_ unit: String) -> Dimension {
        switch unit.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "g", "kg": return .weight
        case "ml", "l": return .volume
        case "", "ea", "x", "pcs", "pc", "pack", "packs", "can", "cans", "bunch", "bunches":
            return .count
        default: return .unknown
        }
    }

    /// Converts a quantity to its base unit (grams / millilitres / each).
    private static func toBase(_ value: Double, unit: String) -> Double {
        switch unit.lowercased() {
        case "kg": return value * 1000
        case "l":  return value * 1000
        default:   return value
        }
    }

    /// A grouping key so items that could be summed share a bucket
    /// (all weights together, all volumes together, counts together, and each
    /// unknown unit on its own).
    static func groupKey(unit: String) -> String {
        switch dimension(unit) {
        case .weight: return "weight"
        case .volume: return "volume"
        case .count:  return "count"
        case .unknown: return "u:" + unit.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func parse(_ quantity: String) -> Double? {
        Double(quantity.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }

    /// Base-unit value (grams / millilitres / each) with its grouping key, so
    /// callers can do cross-unit arithmetic (kg vs g) on like dimensions.
    static func baseAmount(quantity: String, unit: String) -> (value: Double, groupKey: String)? {
        guard let v = parse(quantity) else { return nil }
        return (toBase(v, unit: unit), groupKey(unit: unit))
    }

    /// Tidy number formatting for display ("1.5", not "1.50").
    static func format(_ v: Double) -> String { trimmed(v) }

    /// Two amounts can be merged when they share a metric dimension, or are the
    /// same literal unit (e.g. "tbsp" + "tbsp").
    static func canCombine(unitA: String, unitB: String) -> Bool {
        let a = dimension(unitA), b = dimension(unitB)
        if a == b && a != .unknown { return true }
        return unitA.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            == unitB.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Combine two amounts, returning the summed quantity + unit already tidied
    /// for display (e.g. 1000 g → "1", "kg").
    static func combine(quantityA: String, unitA: String,
                        quantityB: String, unitB: String) -> (quantity: String, unit: String)? {
        guard let a = parse(quantityA), let b = parse(quantityB) else { return nil }
        let dimA = dimension(unitA), dimB = dimension(unitB)

        if dimA == dimB && dimA != .unknown {
            let totalBase = toBase(a, unit: unitA) + toBase(b, unit: unitB)
            let baseUnit: String
            switch dimA {
            case .weight: baseUnit = "g"
            case .volume: baseUnit = "ml"
            default:      baseUnit = normaliseCountUnit(unitA)
            }
            return displayString(baseQuantity: totalBase, baseUnit: baseUnit)
        }

        // Same literal (non-metric) unit — sum as-is.
        if unitA.lowercased() == unitB.lowercased() {
            return (trimmed(a + b), unitA)
        }
        return nil
    }

    /// Tidy a stored quantity + unit for display: 1000 g → "1 kg", 1500 ml → "1.5 L".
    static func display(quantity: String, unit: String) -> (quantity: String, unit: String) {
        guard let v = parse(quantity) else { return (quantity, unit) }
        switch unit.lowercased() {
        case "g":  return displayString(baseQuantity: v, baseUnit: "g")
        case "kg": return displayString(baseQuantity: v * 1000, baseUnit: "g")
        case "ml": return displayString(baseQuantity: v, baseUnit: "ml")
        case "l":  return displayString(baseQuantity: v * 1000, baseUnit: "ml")
        default:   return (trimmed(v), unit)
        }
    }

    private static func displayString(baseQuantity: Double, baseUnit: String) -> (String, String) {
        switch baseUnit {
        case "g":
            return baseQuantity >= 1000 ? (trimmed(baseQuantity / 1000), "kg") : (trimmed(baseQuantity), "g")
        case "ml":
            return baseQuantity >= 1000 ? (trimmed(baseQuantity / 1000), "L") : (trimmed(baseQuantity), "ml")
        default:
            return (trimmed(baseQuantity), baseUnit)
        }
    }

    private static func normaliseCountUnit(_ unit: String) -> String {
        let u = unit.lowercased()
        return (u.isEmpty || u == "x") ? "ea" : u
    }

    private static func trimmed(_ v: Double) -> String {
        if v.rounded() == v { return String(Int(v)) }
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
