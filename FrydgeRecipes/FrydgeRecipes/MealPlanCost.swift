//
//  MealPlanCost.swift
//  FrydgeRecipes
//
//  Prices a week of planned meals from the same live offer feed the recipe
//  screen uses (cheapest at the preferred store, else cheapest anywhere), so
//  the planner can show a cost per recipe, per day and for the week, price
//  the "Review & add" lines, and compare the lot against the grocery budget.
//
//  Costs are pack-price estimates — a recipe that uses a splash of milk is
//  "charged" a bottle — which is why every figure is shown with "≈".
//

import SwiftUI

@MainActor
final class MealPlanCostModel: ObservableObject {

    /// Best known offer for one ingredient.
    struct LinePrice: Equatable {
        let price: Double
        let currencyCode: String
        let store: String
    }

    /// Cost of a set of ingredient lines with how complete the pricing is.
    struct Cost: Equatable {
        let total: Double
        let pricedCount: Int
        let lineCount: Int
        let currencyCode: String

        static let empty = Cost(total: 0, pricedCount: 0, lineCount: 0, currencyCode: "NZD")

        var hasAnyPrice: Bool { pricedCount > 0 }
        var isComplete: Bool { lineCount > 0 && pricedCount == lineCount }

        /// "≈ $42" or "≈ $42+" when some lines are still unpriced.
        var text: String {
            let base = GroceryBudget.money(total, currencyCode: currencyCode)
            return isComplete ? "≈ \(base)" : "≈ \(base)+"
        }
    }

    @Published private(set) var pricesByKey: [String: LinePrice] = [:]
    @Published private(set) var isLoading = false

    private var offersByKey: [String: [StockAvailability.StoreOffer]] = [:]
    private var requestedKeys: Set<String> = []
    private var inFlight = 0

    // MARK: - Keys

    /// Normalised ingredient name used to share one lookup across recipes
    /// ("200 g butter, softened" and "Butter 50g" both price the same product).
    nonisolated static func key(for ingredientLine: String) -> String {
        let parsed = RecipeIngredientParser.parse(ingredientLine)
        let name = RecipeReadiness.cleanedName(parsed.name.isEmpty ? ingredientLine : parsed.name)
        return name
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Loading

    /// Fetches offers for any ingredient not priced yet. Safe to call on every
    /// plan change: already-requested ingredients are skipped.
    func refresh(ingredientLines: [String]) {
        let keys = Set(ingredientLines.map(Self.key(for:)))
            .filter { !$0.isEmpty }
            .subtracting(requestedKeys)
        guard !keys.isEmpty else {
            rebuild()
            return
        }
        requestedKeys.formUnion(keys)
        inFlight += 1
        isLoading = true

        Task { [weak self] in
            // A week of recipes is 40–80 lines; fetch a handful at a time so the
            // price feed isn't hit with everything at once.
            let ordered = Array(keys)
            var fetched: [(String, [StockAvailability.StoreOffer])] = []
            for chunk in stride(from: 0, to: ordered.count, by: 6).map({ Array(ordered[$0..<min($0 + 6, ordered.count)]) }) {
                let batch = await withTaskGroup(of: (String, [StockAvailability.StoreOffer]).self) { group in
                    for key in chunk {
                        group.addTask {
                            let offers = await StockAvailability.fetchPricedOffersOnly(for: key)
                                .filter { $0.isProbablyMatch && $0.price != nil }
                            return (key, offers)
                        }
                    }
                    var out: [(String, [StockAvailability.StoreOffer])] = []
                    for await entry in group { out.append(entry) }
                    return out
                }
                fetched.append(contentsOf: batch)
                if Task.isCancelled { break }
            }

            guard let self else { return }
            for (key, offers) in fetched where !offers.isEmpty {
                self.offersByKey[key] = offers
            }
            self.inFlight -= 1
            self.isLoading = self.inFlight > 0
            self.rebuild()
        }
    }

    /// Re-picks the best offer per ingredient for the current preferred store.
    /// Pure state → state, so switching store is instant.
    func rebuild() {
        let preferred = PreferredStore.name
        var prices: [String: LinePrice] = [:]
        for (key, offers) in offersByKey {
            guard let best = PreferredStore.bestOffer(from: offers, preferred: preferred),
                  let price = best.price else { continue }
            prices[key] = LinePrice(price: price, currencyCode: best.currencyCode, store: best.store)
        }
        pricesByKey = prices
    }

    // MARK: - Costs

    var currencyCode: String {
        pricesByKey.values.first?.currencyCode ?? Locale.current.currency?.identifier ?? "NZD"
    }

    /// Cost of a list of raw ingredient lines (a recipe).
    func cost(ofLines lines: [String]) -> Cost {
        var total = 0.0
        var priced = 0
        var count = 0
        var currency = currencyCode
        for line in lines {
            let key = Self.key(for: line)
            guard !key.isEmpty else { continue }
            count += 1
            if let match = pricesByKey[key] {
                total += match.price
                priced += 1
                currency = match.currencyCode
            }
        }
        return Cost(total: total, pricedCount: priced, lineCount: count, currencyCode: currency)
    }

    func cost(of plan: PlannedRecipe) -> Cost {
        cost(ofLines: plan.ingredients)
    }

    /// Cost of several recipes added together (a day, or the week).
    func cost(of plans: [PlannedRecipe]) -> Cost {
        plans.reduce(Cost.empty) { partial, plan in
            let next = cost(of: plan)
            return Cost(
                total: partial.total + next.total,
                pricedCount: partial.pricedCount + next.pricedCount,
                lineCount: partial.lineCount + next.lineCount,
                currencyCode: next.hasAnyPrice ? next.currencyCode : partial.currencyCode
            )
        }
    }

    /// Price for one merged needs line (already a bare ingredient name).
    func price(for line: MealPlanNeeds.Line) -> Double? {
        pricesByKey[Self.key(for: line.name)]?.price
    }

    /// What the "to buy" lines would cost — the budget-relevant number, since
    /// it's merged across recipes and reduced by what the frydge already holds.
    func cost(ofNeeds lines: [MealPlanNeeds.Line]) -> Cost {
        var total = 0.0
        var priced = 0
        for line in lines {
            if let price = price(for: line) {
                total += price
                priced += 1
            }
        }
        return Cost(total: total, pricedCount: priced, lineCount: lines.count, currencyCode: currencyCode)
    }

    /// "$3.55 a serve" for a planned recipe, when both a cost and a serves
    /// count are known.
    func perServeText(for plan: PlannedRecipe) -> String? {
        let recipeCost = cost(of: plan)
        guard recipeCost.hasAnyPrice,
              let serves = Int(plan.serves.filter(\.isNumber)), serves > 0 else { return nil }
        return "\(GroceryBudget.money(recipeCost.total / Double(serves), currencyCode: recipeCost.currencyCode)) a serve"
    }
}
