//
//  MealPlanNeeds.swift
//  FrydgeRecipes
//
//  Turns a set of planned recipes into a household shopping picture: every
//  ingredient line is parsed, merged across recipes (two recipes wanting 200 g
//  and 300 g of mince become 500 g), then compared against what the frydge
//  already holds and what is already on the shopping list.
//
//  Pure and nonisolated so it can be unit-tested and reused by both the
//  personal planner and the shared household plan.
//

import Foundation

enum MealPlanNeeds {

    // MARK: - Inputs

    /// A recipe on the plan. Only what the calculator needs.
    struct Meal {
        let recipeName: String
        let dayIndex: Int
        let ingredients: [String]
        let dietaryTags: [String]
    }

    /// Something sitting in the frydge (shared or personal).
    struct StockItem {
        let name: String
        let quantity: String
        let unit: String
        /// 0…100, how much has already been used.
        let quantityUsed: Double
        let isExpired: Bool
    }

    // MARK: - Outputs

    enum Status: Hashable {
        /// Fully covered by what's in the frydge.
        case inFrydge
        /// Some in the frydge but not enough; `shortfall` is what to buy.
        case partial(shortfall: String, unit: String)
        /// Already sitting on the chosen shopping list.
        case onList
        /// Nothing in the frydge or on the list.
        case toBuy
    }

    struct Line: Identifiable, Hashable {
        /// Normalised ingredient name; stable across recomputes.
        var id: String { key }
        let key: String
        let name: String
        /// Total amount the week's recipes call for (already merged).
        let quantity: String
        let unit: String
        let recipeNames: [String]
        let dietaryTags: Set<String>
        let status: Status

        /// Amount that should go on the shopping list: the shortfall when the
        /// frydge has some, otherwise the full requirement.
        var purchaseQuantity: String {
            if case .partial(let shortfall, _) = status { return shortfall }
            return quantity
        }
        var purchaseUnit: String {
            if case .partial(_, let unit) = status { return unit }
            return unit
        }
    }

    struct Result {
        let inFrydge: [Line]
        let toBuy: [Line]        // includes .partial lines
        let onList: [Line]

        var isEmpty: Bool { inFrydge.isEmpty && toBuy.isEmpty && onList.isEmpty }
    }

    // MARK: - Compute

    static func compute(meals: [Meal], stock: [StockItem], shoppingListNames: [String]) -> Result {
        let merged = mergeIngredients(from: meals)
        let usableStock = stock.filter { !$0.isExpired }

        var inFrydge: [Line] = []
        var toBuy: [Line] = []
        var onList: [Line] = []

        // Index once; each merged ingredient is then a few dictionary probes.
        let stockIndex = IngredientMatcher.Index(names: usableStock.map(\.name))
        let listIndex = IngredientMatcher.Index(names: shoppingListNames)

        for agg in merged {
            let aggTokens = IngredientMatcher.tokens(agg.name)
            let matches = stockIndex.allMatches(aggTokens).map { usableStock[$0] }

            if !matches.isEmpty {
                switch coverage(of: agg, by: matches) {
                case .covered:
                    inFrydge.append(agg.line(status: .inFrydge))
                    continue
                case .short(let shortfall, let unit):
                    toBuy.append(agg.line(status: .partial(shortfall: shortfall, unit: unit)))
                    continue
                case .none:
                    break // fall through to list / buy
                }
            }

            if listIndex.matches(aggTokens) {
                onList.append(agg.line(status: .onList))
            } else {
                toBuy.append(agg.line(status: .toBuy))
            }
        }

        return Result(inFrydge: inFrydge, toBuy: toBuy, onList: onList)
    }

    // MARK: - Merging

    private struct Aggregate {
        let key: String
        let name: String
        var quantity: String
        var unit: String
        var recipeNames: [String]
        var dietaryTags: Set<String>

        func line(status: Status) -> Line {
            Line(key: key, name: name, quantity: quantity, unit: unit,
                 recipeNames: recipeNames, dietaryTags: dietaryTags, status: status)
        }
    }

    /// Parse every ingredient line and sum like ingredients across recipes.
    private static func mergeIngredients(from meals: [Meal]) -> [Aggregate] {
        var order: [String] = []
        var byKey: [String: Aggregate] = [:]

        for meal in meals.sorted(by: { $0.dayIndex < $1.dayIndex }) {
            let tags = Set(meal.dietaryTags.map { $0.uppercased() })
            for raw in meal.ingredients {
                let parsed = RecipeIngredientParser.parse(raw)
                let name = parsed.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let key = normalisedKey(name)

                if var existing = byKey[key] {
                    if !existing.recipeNames.contains(meal.recipeName) {
                        existing.recipeNames.append(meal.recipeName)
                    }
                    existing.dietaryTags.formUnion(tags)
                    if let combined = FridgeUnits.combine(
                        quantityA: existing.quantity, unitA: existing.unit,
                        quantityB: parsed.quantity, unitB: parsed.unit
                    ) {
                        existing.quantity = combined.quantity
                        existing.unit = combined.unit
                    }
                    // Incompatible units (e.g. "2 cups" + "300 g"): keep the
                    // first amount rather than inventing a conversion.
                    byKey[key] = existing
                } else {
                    order.append(key)
                    byKey[key] = Aggregate(
                        key: key, name: name,
                        quantity: parsed.quantity, unit: parsed.unit,
                        recipeNames: [meal.recipeName], dietaryTags: tags
                    )
                }
            }
        }
        return order.compactMap { byKey[$0] }
    }

    /// Lowercase, strip plurals' trailing "s" and collapse whitespace so
    /// "Eggs" and "egg" merge.
    static func normalisedKey(_ name: String) -> String {
        var s = name.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if s.count > 3, s.hasSuffix("s"), !s.hasSuffix("ss") { s.removeLast() }
        return s
    }

    // MARK: - Coverage

    private enum Coverage {
        case covered
        case short(shortfall: String, unit: String)
        case none
    }

    /// Quantity-aware check when the recipe amount and the stock share a
    /// dimension (g/kg, ml/L, counts). Falls back to "covered" on a name match
    /// when amounts aren't comparable, matching the personal planner's rule.
    private static func coverage(of agg: Aggregate, by matches: [StockItem]) -> Coverage {
        guard let need = FridgeUnits.baseAmount(quantity: agg.quantity, unit: agg.unit) else {
            return .covered
        }

        var available: Double = 0
        var comparable = false
        for item in matches {
            guard let have = FridgeUnits.baseAmount(quantity: item.quantity, unit: item.unit),
                  have.groupKey == need.groupKey else { continue }
            comparable = true
            let remainingFraction = max(0, min(1, 1 - item.quantityUsed / 100))
            available += have.value * remainingFraction
        }

        // Name matched but units aren't comparable (e.g. "1 tbsp" vs "500 g"):
        // trust the name match.
        guard comparable else { return .covered }

        if available + 0.0001 >= need.value { return .covered }
        if available <= 0 { return .none }

        let shortBase = need.value - available
        let baseUnit: String
        switch need.groupKey {
        case "weight": baseUnit = "g"
        case "volume": baseUnit = "ml"
        default: baseUnit = agg.unit.isEmpty ? "ea" : agg.unit
        }
        let display = FridgeUnits.display(quantity: FridgeUnits.format(shortBase), unit: baseUnit)
        return .short(shortfall: display.quantity, unit: display.unit)
    }

    // MARK: - Notification text

    /// Short, notification-friendly summary of a plan update.
    /// Example: "3 meals · In the frydge: mince, onion +2 · Buy: pasta, cheese"
    static func summary(meals: [Meal], result: Result, listName: String) -> String {
        var parts: [String] = []
        parts.append("\(meals.count) meal\(meals.count == 1 ? "" : "s") planned")
        if !result.inFrydge.isEmpty {
            parts.append("In the frydge: " + names(result.inFrydge))
        }
        if !result.toBuy.isEmpty {
            parts.append("Added to \(listName): " + names(result.toBuy))
        } else {
            parts.append("Nothing to buy")
        }
        return parts.joined(separator: " · ")
    }

    private static func names(_ lines: [Line], limit: Int = 4) -> String {
        let shown = lines.prefix(limit).map { $0.name.lowercased() }
        let extra = lines.count - shown.count
        return shown.joined(separator: ", ") + (extra > 0 ? " +\(extra) more" : "")
    }
}
