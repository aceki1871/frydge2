//
//  PackSizeRules.swift
//  FrydgeRecipes
//
//  Rounds a raw ingredient shortfall up to an amount you can actually buy —
//  eggs come in packs of 6 or 12, butter in 250 g blocks, milk in 1 L bottles.
//  Falls back to nil (caller keeps the raw amount) for unknown ingredients or
//  incomparable units, so it never makes a quantity wrong, only more buyable.
//

import Foundation

enum PackSizeRules {

    private enum Dimension { case weight, volume, count }

    private struct Rule {
        let keywords: [String]
        let exclude: [String]
        let dimension: Dimension
        /// Purchasable pack sizes in the base unit (g / ml / each), ascending.
        let sizes: [Double]
    }

    /// NZ supermarket pack sizes (Woolworths / New World / Pak'nSave ranges,
    /// checked Aug 2026). Order matters: specific rules (coconut milk,
    /// cornflour, sour cream) sit above the generic ones they'd otherwise
    /// fall into (milk, flour, cream).
    private static let rules: [Rule] = [
        // Cartons of 6/10/12/18, trays of 20/30 (Zeagold standard formats).
        Rule(keywords: ["egg"], exclude: ["eggplant"], dimension: .count, sizes: [6, 10, 12, 18, 20, 30]),

        // Dairy & fridge
        // 165 ml and 400 ml cans.
        Rule(keywords: ["coconut milk", "coconut cream"], exclude: [], dimension: .volume, sizes: [165, 400]),
        // Highlander cans.
        Rule(keywords: ["condensed milk"], exclude: [], dimension: .weight, sizes: [395]),
        // Pottles (sold by weight in NZ).
        Rule(keywords: ["sour cream"], exclude: [], dimension: .weight, sizes: [250, 500]),
        // Pic's-style jars.
        Rule(keywords: ["peanut butter", "almond butter", "cashew butter"], exclude: [], dimension: .weight, sizes: [195, 380, 1000]),
        // 250 g (Lewis Road premium), 400 g (Westgold), 500 g (Anchor/Mainland/own-brand standard).
        Rule(keywords: ["butter"], exclude: ["nut butter", "seed butter", "sunflower", "buttermilk", "butternut"], dimension: .weight, sizes: [250, 400, 500]),
        // Mainland-style blocks; also covers cream cheese tubs (250 g).
        Rule(keywords: ["cheese"], exclude: [], dimension: .weight, sizes: [250, 500, 700, 1000]),
        // 1/2/3 L bottles; plant milks land on the 1 L carton.
        Rule(keywords: ["milk"], exclude: ["powder", "buttermilk", "condensed", "evaporated"], dimension: .volume, sizes: [1000, 2000, 3000]),
        // Anchor fresh cream bottles.
        Rule(keywords: ["cream"], exclude: ["ice", "creamed"], dimension: .volume, sizes: [300, 500]),
        Rule(keywords: ["yoghurt", "yogurt"], exclude: [], dimension: .weight, sizes: [500, 1000]),

        // Baking
        // Edmonds Fielder's box.
        Rule(keywords: ["cornflour", "corn flour"], exclude: [], dimension: .weight, sizes: [300]),
        // Edmonds/Champion bags — no 1 kg flour in NZ. GF flour blends come in
        // odd sizes, so let those fall through unrounded.
        Rule(keywords: ["flour"], exclude: ["gluten free", "gluten-free"], dimension: .weight, sizes: [1500, 5000]),
        // Chelsea: 500 g (caster/brown/icing), 1.5 kg and 3 kg (white).
        Rule(keywords: ["sugar"], exclude: [], dimension: .weight, sizes: [500, 1500, 3000]),
        // Chelsea 540 g easy-pour bottle, 1 kg tin.
        Rule(keywords: ["golden syrup"], exclude: [], dimension: .weight, sizes: [540, 1000]),
        Rule(keywords: ["honey"], exclude: [], dimension: .weight, sizes: [500]),
        // Craig's-style jars.
        Rule(keywords: ["jam"], exclude: [], dimension: .weight, sizes: [375]),
        // Harraways bags.
        Rule(keywords: ["oats", "oatmeal"], exclude: [], dimension: .weight, sizes: [800]),
        // 180 g (Cadbury) and 250 g (Whittaker's) blocks.
        Rule(keywords: ["chocolate"], exclude: [], dimension: .weight, sizes: [180, 250]),

        // Cans & pantry
        Rule(keywords: ["tinned tomato", "canned tomato", "chopped tomato", "crushed tomato", "diced tomato"], exclude: [], dimension: .weight, sizes: [400]),
        // Wattie's cans.
        Rule(keywords: ["baked bean"], exclude: [], dimension: .weight, sizes: [420]),
        Rule(keywords: ["tinned chickpea", "canned chickpea", "tinned bean", "canned bean", "tinned lentil", "canned lentil", "cannellini", "kidney bean", "black bean", "butter bean"], exclude: [], dimension: .weight, sizes: [400]),
        // Dried lentil/split-pea bags.
        Rule(keywords: ["lentil"], exclude: [], dimension: .weight, sizes: [500]),
        // Wattie's frozen bags ("chickpeas" contains "peas", hence the exclusion).
        Rule(keywords: ["peas", "sweetcorn", "frozen corn", "mixed vege"], exclude: ["chickpea"], dimension: .weight, sizes: [500, 1000]),
        // Campbell's Real Stock tetra packs.
        Rule(keywords: ["stock"], exclude: ["cube"], dimension: .volume, sizes: [250, 500, 1000]),
        Rule(keywords: ["rice"], exclude: [], dimension: .weight, sizes: [1000, 5000]),
        Rule(keywords: ["pasta", "spaghetti", "penne", "macaroni", "fettuccine"], exclude: ["sauce"], dimension: .weight, sizes: [500]),
        Rule(keywords: ["bacon"], exclude: [], dimension: .weight, sizes: [250, 700, 1000]),
        // Prepacked trays.
        Rule(keywords: ["mince"], exclude: ["mincemeat"], dimension: .weight, sizes: [500, 1000]),
        // Wattie's sachets.
        Rule(keywords: ["tomato paste"], exclude: [], dimension: .weight, sizes: [100]),
        Rule(keywords: ["salt"], exclude: ["salted"], dimension: .weight, sizes: [500]),

        // Oils & sauces
        Rule(keywords: ["olive oil"], exclude: [], dimension: .volume, sizes: [500, 750, 1000]),
        Rule(keywords: ["vegetable oil", "canola oil", "sunflower oil", "rice bran oil"], exclude: [], dimension: .volume, sizes: [750, 1000, 2000]),
        Rule(keywords: ["soy sauce"], exclude: [], dimension: .volume, sizes: [250, 500]),
        // Generic "oil" lines — after the specific oils; small specialty
        // bottles (sesame, truffle) and solid coconut oil stay unrounded.
        Rule(keywords: ["oil"], exclude: ["coconut", "sesame", "truffle", "spray", "boil"], dimension: .volume, sizes: [500, 750, 1000, 2000])
    ]

    /// The smallest purchasable amount covering `needed`, in the base unit for
    /// the ingredient's dimension (g / ml / each). Nil when no rule matches or
    /// the unit can't be compared against pack sizes (e.g. "2 tbsp butter").
    static func purchaseQuantity(name: String, needed: Double, unit: String) -> (quantity: Double, unit: String)? {
        guard needed > 0 else { return nil }
        let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rule = rules.first(where: { matches($0, name: key) }) else { return nil }
        guard let base = baseAmount(needed, unit: unit, dimension: rule.dimension) else { return nil }
        return (roundUp(base, sizes: rule.sizes), baseUnit(for: rule.dimension))
    }

    /// Convenience for callers holding display strings: the purchasable amount
    /// tidied for display (1000 g → "1 kg"). Nil when no rule applies.
    static func purchaseDisplay(name: String, needed: Double, unit: String) -> (quantity: String, unit: String)? {
        guard let buy = purchaseQuantity(name: name, needed: needed, unit: unit) else { return nil }
        return FridgeUnits.display(quantity: trimmed(buy.quantity), unit: buy.unit)
    }

    /// The smallest pack the shops sell for a food, tidied for display
    /// ("1 L" milk, "250 g" butter, "6" eggs). Nil when no rule matches.
    /// Gives list items that were added by name alone — and so carry no
    /// amount — a pack size to show, like the label on the packet.
    static func defaultPackDisplay(name: String) -> (quantity: String, unit: String)? {
        let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rule = rules.first(where: { matches($0, name: key) }),
              let smallest = rule.sizes.first else { return nil }
        return FridgeUnits.display(quantity: trimmed(smallest), unit: baseUnit(for: rule.dimension))
    }

    // MARK: - Matching

    private static func matches(_ rule: Rule, name: String) -> Bool {
        guard !rule.exclude.contains(where: name.contains) else { return false }
        return rule.keywords.contains(where: name.contains)
    }

    // MARK: - Units

    private static func baseAmount(_ value: Double, unit: String, dimension: Dimension) -> Double? {
        let u = unit.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch dimension {
        case .weight:
            switch u {
            case "g": return value
            case "kg": return value * 1000
            default: return nil
            }
        case .volume:
            switch u {
            case "ml": return value
            case "l": return value * 1000
            default: return nil
            }
        case .count:
            switch u {
            case "", "ea", "x", "pcs", "pc": return value
            default: return nil
            }
        }
    }

    private static func baseUnit(for dimension: Dimension) -> String {
        switch dimension {
        case .weight: return "g"
        case .volume: return "ml"
        case .count: return ""
        }
    }

    // MARK: - Rounding

    /// Smallest combination of packs covering `need`: a single pack when one
    /// fits, otherwise fill with the largest pack and top up recursively
    /// (need 700 g of butter → 500 g + 250 g, need 8 eggs → a 12 pack).
    private static func roundUp(_ need: Double, sizes: [Double]) -> Double {
        guard let largest = sizes.last, largest > 0 else { return need }
        if let fit = sizes.first(where: { $0 + 0.0001 >= need }) { return fit }
        let fullPacks = (need / largest).rounded(.down)
        let remainder = need - fullPacks * largest
        let covered = fullPacks * largest
        return remainder <= 0.0001 ? covered : covered + roundUp(remainder, sizes: sizes)
    }

    private static func trimmed(_ v: Double) -> String {
        if v.rounded() == v { return String(Int(v)) }
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
