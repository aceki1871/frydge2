//
//  ShopAisle.swift
//  FrydgeRecipes
//
//  One "what could I cook?" order shared by the fridge and the shopping
//  list: the things a meal is built around (meat & fish, then pasta & grains,
//  then fresh produce) sit at the top, dairy and bread follow, and the small
//  supporting items (nuts, sauces, seasoning) fall towards the bottom. Both
//  lists use it by default so an item appears in the same place whichever
//  screen you're on.
//
//  Classification leans on IngredientMatcher's food lexicon (the same
//  taxonomy recipe matching uses), with a few compound-name rules in front
//  of it and a keyword fallback behind it for things the lexicon doesn't
//  know (crisps, toilet paper…).
//

import Foundation

enum ShopAisle: Int, CaseIterable, Comparable {
    case meatAndFish
    case pastaRiceGrains
    case fruitAndVeg
    case dairyAndEggs
    case breadAndBakery
    case frozen
    case drinks
    case snacks
    case tinnedAndJars
    case baking
    case nutsAndSeeds
    case saucesAndCondiments
    case herbsAndSeasoning
    case household
    case other

    static func < (lhs: ShopAisle, rhs: ShopAisle) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .meatAndFish:          return "Meat & fish"
        case .dairyAndEggs:         return "Dairy & eggs"
        case .pastaRiceGrains:      return "Pasta, rice & grains"
        case .breadAndBakery:       return "Bread & bakery"
        case .fruitAndVeg:          return "Fruit & veg"
        case .frozen:               return "Frozen"
        case .drinks:               return "Drinks"
        case .snacks:               return "Snacks"
        case .tinnedAndJars:        return "Tins & jars"
        case .baking:               return "Baking"
        case .nutsAndSeeds:         return "Nuts & seeds"
        case .saucesAndCondiments:  return "Sauces & condiments"
        case .herbsAndSeasoning:    return "Herbs & seasoning"
        case .household:            return "Household"
        case .other:                return "Other"
        }
    }

    // MARK: - Classification

    /// Which aisle an item belongs to. Compound names that the broader rules
    /// would misread are checked first ("chicken salt" is seasoning, "peanut
    /// butter" a condiment, "rice crackers" a snack), then the shared food
    /// lexicon, then a keyword fallback.
    static func classify(_ name: String) -> ShopAisle {
        // Memoised: the shopping list sorts by aisle on every redraw, and each
        // comparison classified both names through dozens of regexes. With
        // the list redrawing as each price lands, that was millions of regex
        // evaluations on the main thread per visit.
        if let cached = classifyMemo.get(name) { return cached }
        let computed = computeClassification(name)
        classifyMemo.set(name, computed)
        return computed
    }

    private static let classifyMemo = LockedMemo<ShopAisle>()

    private static func computeClassification(_ name: String) -> ShopAisle {
        let lower = name
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        guard !lower.isEmpty else { return .other }

        if let pinned = firstMatch(in: lower, rules: pinnedRules) {
            return pinned
        }
        if let category = IngredientMatcher.category(for: name), let aisle = aisle(for: category) {
            return aisle
        }
        if let fallback = firstMatch(in: lower, rules: fallbackRules) {
            return fallback
        }
        return .other
    }

    /// Shared comparator: aisle first, then A–Z within an aisle.
    static func precedes(_ a: String, _ b: String) -> Bool {
        let aa = classify(a), ab = classify(b)
        if aa != ab { return aa < ab }
        return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
    }

    /// Maps the recipe-matching taxonomy onto shop aisles.
    private static func aisle(for category: FoodCategory) -> ShopAisle? {
        switch category {
        case .meat, .poultry, .seafood:   return .meatAndFish
        case .dairy, .egg:                return .dairyAndEggs
        case .grain:                      return .pastaRiceGrains
        case .bakery:                     return .breadAndBakery
        case .vegetable, .fruit:          return .fruitAndVeg
        case .frozen:                     return .frozen
        case .beverage:                   return .drinks
        case .sweet:                      return .snacks
        case .legume, .pantry:            return .tinnedAndJars
        case .baking:                     return .baking
        case .nut, .seed:                 return .nutsAndSeeds
        case .condiment, .oil:            return .saucesAndCondiments
        case .herb, .spice:               return .herbsAndSeasoning
        }
    }

    // MARK: - Keyword rules

    private struct Rule {
        let aisle: ShopAisle
        let regex: NSRegularExpression
    }

    private static func firstMatch(in lower: String, rules: [Rule]) -> ShopAisle? {
        let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
        for rule in rules where rule.regex.firstMatch(in: lower, options: [], range: range) != nil {
            return rule.aisle
        }
        return nil
    }

    /// Whole-word match on any keyword, tolerating a simple plural.
    private static func rule(_ aisle: ShopAisle, _ keywords: [String]) -> Rule? {
        let alternatives = keywords
            .map { NSRegularExpression.escapedPattern(for: $0.lowercased()) }
            .joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: #"\b(?:"# + alternatives + #")(?:s|es)?\b"#) else {
            return nil
        }
        return Rule(aisle: aisle, regex: regex)
    }

    /// Checked before the lexicon: compounds whose last word would otherwise
    /// drag them into the wrong aisle, plus non-food.
    private static let pinnedRules: [Rule] = [
        rule(.household, ["toilet paper", "toilet roll", "paper towel", "dishwash", "dishwasher", "detergent", "soap", "shampoo", "conditioner", "bin liner", "rubbish bag", "foil", "cling film", "glad wrap", "baking paper", "sponge", "bleach", "toothpaste", "nappy", "nappies", "tissue", "deodorant", "razor", "batteries", "battery", "cleaner"]),
        rule(.herbsAndSeasoning, ["chicken salt", "celery salt", "garlic salt", "sea salt", "rock salt", "table salt", "stock cube", "seasoning", "garlic powder", "onion powder", "ginger powder", "chilli flake", "chili flake", "chilli powder", "chili powder", "curry powder", "mixed herb", "five spice", "garam masala"]),
        rule(.saucesAndCondiments, ["peanut butter", "almond butter", "fish sauce", "oyster sauce", "soy sauce", "hot sauce", "sweet chilli", "tomato paste", "curry paste", "tomato sauce", "pasta sauce", "chicken stock", "beef stock", "vegetable stock", "liquid stock", "olive oil", "vegetable oil", "coconut oil", "sesame oil", "canola oil", "cooking oil"]),
        rule(.pastaRiceGrains, ["egg noodle", "rice noodle"]),
        rule(.dairyAndEggs, ["almond milk", "oat milk", "soy milk", "soya milk", "rice milk", "chocolate milk", "cream cheese"]),
        rule(.tinnedAndJars, ["coconut milk", "coconut cream", "tinned", "canned", "tin of", "can of", "baked bean", "kidney bean", "black bean", "cannellini", "butter bean", "sun-dried tomato", "sundried tomato"]),
        rule(.fruitAndVeg, ["bell pepper", "capsicum", "spring onion", "green bean", "sweet potato", "sweetcorn", "sweet corn", "fresh chilli", "fresh chili", "salad mix", "coleslaw"]),
        rule(.frozen, ["ice cream", "icecream", "ice block", "fish finger", "fish cake", "hash brown", "frozen", "hot chip"]),
        rule(.drinks, ["hot chocolate", "energy drink", "sparkling water", "soda water"]),
        rule(.snacks, ["rice cracker", "rice cake", "corn chip", "muesli bar", "granola bar", "cheese cracker", "chocolate bar", "crisp", "chip", "popcorn", "pretzel", "nacho", "lolly", "lollies"]),
        rule(.baking, ["baking powder", "baking soda", "bicarb", "cake mix", "pancake mix", "condensed milk", "evaporated milk", "choc chip", "chocolate chip", "icing sugar", "breadcrumb"]),
    ].compactMap { $0 }

    /// Checked after the lexicon, for everyday words it may not carry.
    private static let fallbackRules: [Rule] = [
        rule(.herbsAndSeasoning, ["salt", "pepper", "peppercorn", "spice", "herb", "cumin", "paprika", "turmeric", "cinnamon", "nutmeg", "oregano", "basil", "thyme", "rosemary", "parsley", "coriander", "dill", "mint", "bay leaf", "bay leaves", "bouillon", "vanilla", "cayenne", "clove", "cardamom", "star anise", "sumac", "zaatar", "za'atar", "allspice", "msg"]),
        rule(.saucesAndCondiments, ["sauce", "ketchup", "mayo", "mayonnaise", "mustard", "relish", "chutney", "pickle", "vinegar", "oil", "dressing", "tamari", "miso", "pesto", "hummus", "dip", "jam", "marmalade", "honey", "syrup", "nutella", "spread", "marmite", "vegemite", "gravy", "stock", "paste", "tahini", "salsa", "aioli", "sriracha", "worcestershire"]),
        rule(.baking, ["flour", "sugar", "yeast", "cocoa", "cornflour", "cornstarch", "icing", "custard powder", "gelatine", "gelatin", "food colouring", "sprinkle", "essence"]),
        rule(.nutsAndSeeds, ["almond", "cashew", "peanut", "walnut", "pecan", "pistachio", "macadamia", "hazelnut", "brazil nut", "pine nut", "mixed nut", "nut", "seed", "chia", "flaxseed", "linseed", "sesame", "sunflower", "pumpkin seed"]),
        rule(.tinnedAndJars, ["chickpea", "lentil", "tomato puree", "passata", "soup", "olive", "caper", "anchovy", "anchovies", "sardine"]),
        rule(.drinks, ["water", "juice", "soda", "cola", "coke", "lemonade", "beer", "wine", "cider", "vodka", "gin", "whisky", "whiskey", "rum", "coffee", "tea", "kombucha", "sparkling", "tonic", "cordial", "smoothie", "milkshake", "drink"]),
        rule(.snacks, ["cracker", "biscuit", "cookie", "chocolate", "candy", "sweet", "bar", "wafer", "jelly", "marshmallow", "liquorice"]),
        rule(.dairyAndEggs, ["milk", "cheese", "cheddar", "mozzarella", "parmesan", "feta", "brie", "camembert", "halloumi", "yoghurt", "yogurt", "butter", "cream", "sour cream", "creme fraiche", "egg", "margarine", "ghee", "paneer", "cottage cheese", "ricotta", "mascarpone", "custard"]),
        rule(.breadAndBakery, ["bread", "loaf", "loaves", "bagel", "bun", "roll", "wrap", "tortilla", "pita", "naan", "croissant", "muffin", "crumpet", "baguette", "sourdough", "brioche", "cake", "pastry", "pastries", "scone", "doughnut", "donut", "waffle", "pancake", "ciabatta", "focaccia"]),
        rule(.pastaRiceGrains, ["pasta", "spaghetti", "penne", "fusilli", "macaroni", "lasagne", "lasagna", "linguine", "fettuccine", "tagliatelle", "noodle", "rice", "quinoa", "couscous", "oat", "oatmeal", "porridge", "cereal", "muesli", "granola", "barley", "bulgur", "polenta", "gnocchi", "risotto", "weetbix", "weet-bix", "cornflake", "orzo", "ravioli", "tortellini"]),
        rule(.meatAndFish, ["chicken", "beef", "pork", "lamb", "mince", "steak", "sausage", "bacon", "ham", "salami", "prosciutto", "chorizo", "turkey", "duck", "venison", "fish", "salmon", "tuna", "cod", "snapper", "hoki", "tarakihi", "kahawai", "trevally", "gurnard", "mackerel", "prawn", "shrimp", "mussel", "squid", "calamari", "scallop", "crab", "lobster", "tofu", "tempeh", "meatball", "schnitzel", "rib", "wing", "thigh", "breast", "drumstick", "fillet", "roast", "brisket", "rump", "sirloin", "scotch fillet", "patty", "patties", "burger", "meat", "seafood", "kebab"]),
        rule(.fruitAndVeg, ["apple", "banana", "orange", "lemon", "lime", "grape", "berry", "berries", "strawberry", "strawberries", "blueberry", "blueberries", "raspberry", "raspberries", "kiwi", "kiwifruit", "mango", "pineapple", "melon", "watermelon", "peach", "pear", "plum", "cherry", "cherries", "avocado", "tomato", "tomatoes", "potato", "potatoes", "kumara", "onion", "garlic", "ginger", "carrot", "broccoli", "cauliflower", "cabbage", "lettuce", "spinach", "kale", "silverbeet", "cucumber", "zucchini", "courgette", "eggplant", "aubergine", "pumpkin", "squash", "celery", "leek", "mushroom", "corn", "bean", "pea", "asparagus", "beetroot", "radish", "fennel", "salad", "sprout", "mandarin", "feijoa", "passionfruit", "fig", "date", "apricot", "nectarine", "grapefruit", "coconut", "rhubarb", "parsnip", "swede", "turnip", "yam", "chilli", "chili", "lemongrass", "bok choy", "pak choi", "fruit", "veg", "vegetable"]),
    ].compactMap { $0 }
}

/// Small lock-protected string-keyed memo for pure, deterministic name
/// derivations (aisle, short label). Bounded so a long session can't grow it
/// without limit; clearing is harmless because everything recomputes lazily.
final class LockedMemo<Value>: @unchecked Sendable {
    private var storage: [String: Value] = [:]
    private let lock = NSLock()
    private let limit: Int

    init(limit: Int = 4_000) { self.limit = limit }

    func get(_ key: String) -> Value? {
        lock.withLock { storage[key] }
    }

    func set(_ key: String, _ value: Value) {
        lock.withLock {
            if storage.count >= limit { storage.removeAll(keepingCapacity: true) }
            storage[key] = value
        }
    }
}
