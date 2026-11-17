//
//  RecipeReadiness.swift
//  FrydgeRecipes
//
//  Answers two questions for a recipe the moment it is scanned or imported:
//  "can I make this from what's in the frydge?" and "roughly what will it cost?".
//  Fridge matching goes through the shared IngredientMatcher so the snap card,
//  recipe rows, the detail page and cook-time deductions all agree. Pricing
//  layers instant receipt-observed prices under live store offers so a number
//  appears immediately and refines as lookups land.
//
//  Coverage is presence *and* amount: an ingredient only counts as covered
//  when a matching fridge item exists and, where both the recipe line and the
//  fridge item carry a parseable quantity in compatible units, the remaining
//  amount meets the (serves-scaled) requirement. When either side can't be
//  parsed, presence alone decides — the previous behaviour.
//

import Foundation

// MARK: - Readiness (fridge coverage)

enum RecipeReadiness {

    enum Availability: Equatable {
        /// Matched a fridge item by name.
        case inFridge(itemName: String)
        /// Water, salt, pepper: assumed on hand and never priced.
        case staple
        /// Not in the fridge but already on the shopping list.
        case onShoppingList
        case missing
    }

    /// How much more is needed when the fridge has some but not enough.
    struct Shortfall: Equatable {
        let quantity: Double
        /// Unit as written on the recipe line ("" for counts).
        let unit: String
    }

    struct IngredientStatus: Identifiable, Equatable {
        let id: UUID
        /// The line as it will be saved on the recipe, e.g. "Butter 250g".
        let displayLine: String
        /// Bare ingredient name used for matching and price lookups.
        let name: String
        let quantity: String?
        let unit: String?
        let availability: Availability
        /// Set when the item is in the fridge but there isn't enough of it.
        let shortfall: Shortfall?

        var isCovered: Bool {
            switch availability {
            case .inFridge: return shortfall == nil
            case .staple: return true
            case .onShoppingList, .missing: return false
            }
        }

        var isInFridge: Bool {
            if case .inFridge = availability { return true }
            return false
        }

        var isStaple: Bool { availability == .staple }
        var isMissing: Bool { !isCovered }
        /// In the fridge, just not enough of it.
        var isShort: Bool { isInFridge && shortfall != nil }
    }

    /// Counts are computed once here rather than on every view refresh.
    struct Summary: Equatable {
        let statuses: [IngredientStatus]
        let missing: [IngredientStatus]
        let haveCount: Int
        /// Lines that are in the fridge but short on amount (a subset of `missing`).
        let shortCount: Int

        init(statuses: [IngredientStatus]) {
            self.statuses = statuses
            self.missing = statuses.filter(\.isMissing)
            self.haveCount = statuses.count - missing.count
            self.shortCount = statuses.filter(\.isShort).count
        }

        var total: Int { statuses.count }
        var canMakeNow: Bool { !statuses.isEmpty && missing.isEmpty }

        var headline: String {
            if statuses.isEmpty { return "No ingredients found" }
            if canMakeNow { return "You can make this now" }
            let n = missing.count
            return "Missing \(n) ingredient\(n == 1 ? "" : "s")"
        }

        var detail: String {
            guard !statuses.isEmpty else { return "" }
            if shortCount > 0 {
                return "You have \(haveCount) of \(total) ingredients in your frydge (\(shortCount) short on amount)"
            }
            return "You have \(haveCount) of \(total) ingredients in your frydge"
        }

        /// First status for a given recipe line (lines can legitimately repeat).
        func status(for line: String) -> IngredientStatus? {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return statuses.first { $0.displayLine == trimmed }
        }
    }

    /// Ingredients nobody keeps in the fridge list but every kitchen has.
    private static let stapleNames: Set<String> = [
        "water", "cold water", "warm water", "hot water", "boiling water", "ice", "ice cubes",
        "salt", "sea salt", "table salt", "flaky salt", "pepper", "black pepper", "white pepper",
        "ground pepper", "salt and pepper", "salt & pepper", "seasoning"
    ]

    /// Prep words that don't change what the ingredient *is*.
    private static let prepWordsRegex = try? NSRegularExpression(
        pattern: #"\b(to taste|for serving|to serve|optional|finely|roughly|chopped|diced|sliced|minced|grated|fresh|large|small|medium)\b"#,
        options: [.caseInsensitive]
    )
    private static let multiSpaceRegex = try? NSRegularExpression(pattern: #"\s{2,}"#)

    // MARK: Public entry points

    /// Evaluates parsed import ingredients (the snap / URL import path).
    static func evaluate(
        ingredients: [RecipeImportManager.ImportedIngredient],
        fridgeItems: [StoredIngredient],
        shoppingListNames: [String]
    ) -> Summary {
        let entries = ingredients.map { ing in
            Entry(name: ing.name, quantity: ing.quantity, unit: ing.unit, line: ing.asAppIngredientLine())
        }
        return evaluate(entries: entries, fridgeItems: fridgeItems, shoppingListNames: shoppingListNames, scale: 1)
    }

    /// Evaluates raw saved recipe lines such as "500g butter" or "Butter 500g".
    /// `scale` multiplies the recipe's quantities (serves chosen ÷ serves authored).
    static func evaluate(
        lines: [String],
        fridgeItems: [StoredIngredient],
        shoppingListNames: [String],
        scale: Double = 1
    ) -> Summary {
        evaluate(entries: entries(from: lines), fridgeItems: fridgeItems, shoppingListNames: shoppingListNames, scale: scale)
    }

    /// Evaluates raw recipe lines against prebuilt indexes. Use this when
    /// scoring many recipes against the same fridge (recipe list rows,
    /// "recipes using this") so the fridge is indexed once, not per recipe.
    /// Pass `fridgeItems` in the same order as `fridgeIndex.names` to get
    /// amount-aware coverage; omit it for presence-only matching.
    static func evaluate(
        lines: [String],
        fridgeIndex: IngredientMatcher.Index,
        fridgeItems: [StoredIngredient]? = nil,
        shoppingIndex: IngredientMatcher.Index = emptyIndex,
        scale: Double = 1
    ) -> Summary {
        evaluate(entries: entries(from: lines), fridge: fridgeIndex, fridgeItems: fridgeItems, shopping: shoppingIndex, scale: scale)
    }

    /// Fridge items that can go into a recipe: not leftovers (cooked dishes,
    /// not raw ingredients) and not fully used up. Same order as `fridgeIndex(for:)`.
    static func matchableItems(in fridgeItems: [StoredIngredient]) -> [StoredIngredient] {
        fridgeItems.filter { $0.lifecycle == .fridge && $0.quantityUsed < 100 }
    }

    /// Index over the matchable fridge items.
    static func fridgeIndex(for fridgeItems: [StoredIngredient]) -> IngredientMatcher.Index {
        IngredientMatcher.Index(names: matchableItems(in: fridgeItems).map(\.name))
    }

    static let emptyIndex = IngredientMatcher.Index(names: [])

    // MARK: Internals

    private struct Entry {
        let name: String
        let quantity: String?
        let unit: String?
        let line: String
    }

    private static func entries(from lines: [String]) -> [Entry] {
        lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { line in
                let parsed = RecipeIngredientParser.parse(line)
                return Entry(name: parsed.name.isEmpty ? line : parsed.name, quantity: parsed.quantity, unit: parsed.unit, line: line)
            }
    }

    private static func evaluate(
        entries: [Entry],
        fridgeItems: [StoredIngredient],
        shoppingListNames: [String],
        scale: Double
    ) -> Summary {
        // Index the fridge and shopping list once; each ingredient then costs a
        // few dictionary probes instead of a scan over every fridge item.
        let matchable = matchableItems(in: fridgeItems)
        return evaluate(
            entries: entries,
            fridge: IngredientMatcher.Index(names: matchable.map(\.name)),
            fridgeItems: matchable,
            shopping: IngredientMatcher.Index(names: shoppingListNames),
            scale: scale
        )
    }

    private static func evaluate(
        entries: [Entry],
        fridge: IngredientMatcher.Index,
        fridgeItems: [StoredIngredient]?,
        shopping: IngredientMatcher.Index,
        scale: Double
    ) -> Summary {
        let statuses: [IngredientStatus] = entries.map { entry in
            let cleanName = cleanedName(entry.name)
            let availability: Availability
            var shortfall: Shortfall? = nil

            if isStaple(cleanName) {
                availability = .staple
            } else {
                let tokens = IngredientMatcher.tokens(cleanName)
                if let position = fridge.firstMatch(tokens) {
                    availability = .inFridge(itemName: fridge.names[position])
                    if let items = fridgeItems, position < items.count {
                        shortfall = Self.shortfall(required: entry, scale: scale, item: items[position])
                    }
                } else if shopping.matches(tokens) {
                    availability = .onShoppingList
                } else {
                    availability = .missing
                }
            }

            return IngredientStatus(
                id: UUID(),
                displayLine: entry.line,
                name: cleanName,
                quantity: entry.quantity,
                unit: entry.unit,
                availability: availability,
                shortfall: shortfall
            )
        }

        return Summary(statuses: statuses)
    }

    // MARK: Amounts

    /// Nil when the fridge has enough, or when either side can't be compared.
    private static func shortfall(required entry: Entry, scale: Double, item: StoredIngredient) -> Shortfall? {
        guard let requiredBase = parseAmount(entry.quantity) else { return nil }
        let required = max(0, requiredBase * max(0, scale))
        guard required > 0 else { return nil }

        // Only compare measured amounts in the same family (g/kg, ml/l, cups,
        // spoons). Bare counts are skipped on purpose: a fridge "Eggs 1" is
        // usually one carton, not one egg, so comparing it to "2 eggs" would
        // flag false shortfalls. Those fall back to presence.
        guard let (requiredUnit, requiredFactor) = measuredUnit(entry.unit),
              let (itemUnit, itemFactor) = measuredUnit(item.unit),
              requiredUnit == itemUnit else { return nil }

        guard let total = parseAmount(item.quantity) else { return nil }
        let remainingRatio = max(0, min(1, 1 - (item.quantityUsed / 100)))
        let availableBase = total * itemFactor * remainingRatio
        let requiredBaseUnits = required * requiredFactor

        guard availableBase + 0.00001 < requiredBaseUnits else { return nil }
        // Report the shortfall in the recipe's own unit.
        let shortfallInRecipeUnit = (requiredBaseUnits - availableBase) / requiredFactor
        return Shortfall(quantity: shortfallInRecipeUnit, unit: (entry.unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// "2", "2.5", "2,5", "1/2" → Double. Nil for anything else.
    static func parseAmount(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.contains("/") {
            let parts = t.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count == 2,
                  let num = Double(parts[0].replacingOccurrences(of: ",", with: ".")),
                  let den = Double(parts[1].replacingOccurrences(of: ",", with: ".")),
                  den != 0 else { return nil }
            return num / den
        }
        return Double(t.replacingOccurrences(of: ",", with: "."))
    }

    /// Measured units only, folded to a family and a factor into that family's
    /// base unit: ("g", 1) for grams, ("g", 1000) for kilograms, ("ml", 1000)
    /// for litres. Nil for counts and unknown words, which are never compared.
    static func measuredUnit(_ raw: String?) -> (family: String, factor: Double)? {
        let u = (raw ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        switch u {
        case "g", "grams", "gram", "gms", "gm": return ("g", 1)
        case "kg", "kilogram", "kilograms", "kgs": return ("g", 1000)
        case "mg": return ("g", 0.001)
        case "ml", "millilitre", "millilitres", "milliliter", "milliliters", "mls": return ("ml", 1)
        case "l", "litre", "litres", "liter", "liters", "ltr": return ("ml", 1000)
        case "cup", "cups": return ("cup", 1)
        case "tbsp", "tablespoon", "tablespoons", "tbs": return ("tbsp", 1)
        case "tsp", "teaspoon", "teaspoons": return ("tsp", 1)
        case "oz", "ounce", "ounces": return ("g", 28.35)
        case "lb", "lbs", "pound", "pounds": return ("g", 453.6)
        default: return nil
        }
    }

    /// Strips prep notes so "butter, softened" and "onion (finely diced)" match
    /// the plain fridge item names.
    static func cleanedName(_ raw: String) -> String {
        var s = raw
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
        if let comma = s.firstIndex(of: ",") { s = String(s[..<comma]) }
        if let prepWordsRegex {
            s = prepWordsRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        if let multiSpaceRegex {
            s = multiSpaceRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return trimmed.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
    }

    private static func isStaple(_ name: String) -> Bool {
        let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if stapleNames.contains(lower) { return true }
        if lower.hasPrefix("pinch of ") || lower.hasPrefix("a pinch of ") { return true }
        return lower.contains("salt") && lower.contains("pepper")
    }
}

// MARK: - Cost estimate

/// Prices a recipe's ingredients. Receipt-observed prices show instantly, then
/// each line is refined with the cheapest matching local store offer.
@MainActor
final class RecipeCostEstimator: ObservableObject {

    enum Source: Equatable {
        case receipt
        case store
    }

    struct LinePrice: Equatable, Sendable {
        let price: Double
        let currencyCode: String
        let source: Source
        /// Store name when known.
        let label: String?
    }

    struct Totals: Equatable {
        let full: Double
        let toBuy: Double
        let currencyCode: String
        let pricedCount: Int
        let priceableCount: Int

        var isPartial: Bool { pricedCount < priceableCount }
        var hasAnyPrice: Bool { pricedCount > 0 }
    }

    @Published private(set) var prices: [UUID: LinePrice] = [:]
    @Published private(set) var isLoading = false

    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
        isLoading = false
    }

    /// Starts (or restarts) pricing for the given ingredient statuses.
    func estimate(_ statuses: [RecipeReadiness.IngredientStatus]) {
        task?.cancel()

        let priceable = statuses.filter { !$0.isStaple }
        guard !priceable.isEmpty else {
            prices = [:]
            isLoading = false
            return
        }

        // Phase 1: instant — what the user actually paid recently. Built in a
        // local and published once so the card doesn't re-render per line.
        let fallbackCurrency = Locale.current.currency?.identifier ?? "NZD"
        let observed = ObservedPriceStore.shared
        var initial: [UUID: LinePrice] = [:]
        for status in priceable {
            if let recent = observed.latest(for: status.name) {
                initial[status.id] = LinePrice(
                    price: recent.price,
                    currencyCode: fallbackCurrency,
                    source: .receipt,
                    label: recent.store
                )
            }
        }
        prices = initial

        // Phase 2: live store offers, cheapest probable match per line.
        isLoading = true
        let queries = priceable.map { (id: $0.id, name: $0.name) }
        task = Task { [weak self] in
            await withTaskGroup(of: (UUID, LinePrice?).self) { group in
                for query in queries {
                    group.addTask {
                        let offers = await StockAvailability.fetchPricedOffersOnly(for: query.name)
                        let best = offers
                            .filter { $0.isProbablyMatch }
                            .compactMap { offer -> LinePrice? in
                                guard let price = offer.price, price > 0 else { return nil }
                                return LinePrice(price: price, currencyCode: offer.currencyCode, source: .store, label: offer.store)
                            }
                            .min { $0.price < $1.price }
                        return (query.id, best)
                    }
                }

                for await (id, price) in group {
                    guard !Task.isCancelled, let price else { continue }
                    self?.prices[id] = price
                }
            }

            guard !Task.isCancelled else { return }
            self?.isLoading = false
        }
    }

    func totals(for statuses: [RecipeReadiness.IngredientStatus]) -> Totals {
        var full = 0.0
        var toBuy = 0.0
        var priced = 0
        var priceable = 0
        var currency: String? = nil

        for status in statuses where !status.isStaple {
            priceable += 1
            guard let line = prices[status.id] else { continue }
            priced += 1
            full += line.price
            if status.isMissing { toBuy += line.price }
            if currency == nil { currency = line.currencyCode }
        }

        return Totals(
            full: full,
            toBuy: toBuy,
            currencyCode: currency ?? Locale.current.currency?.identifier ?? "NZD",
            pricedCount: priced,
            priceableCount: priceable
        )
    }

    /// Formatters are reused per currency; building one per row per render is
    /// the single most expensive thing a price list can do.
    private static var formatters: [String: NumberFormatter] = [:]

    static func format(_ value: Double, currencyCode: String) -> String {
        let formatter: NumberFormatter
        if let cached = formatters[currencyCode] {
            formatter = cached
        } else {
            formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currencyCode
            formatter.maximumFractionDigits = 2
            formatter.minimumFractionDigits = 2
            formatters[currencyCode] = formatter
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%@ %.2f", currencyCode, value)
    }
}
