//
//  GenericNutrition.swift
//  FrydgeRecipes
//
//  Typical per-100 g nutrition for everyday whole foods, keyed by the
//  canonical food tokens `IngredientMatcher` produces. This is the last line
//  of defence for the four macro boxes (energy / protein / fat / carbs): the
//  products DB and Edamam know about packaged goods, but a fridge item called
//  "Eggs", "Carrots" or "Snapper fillet" often comes back empty from both.
//
//  Values are rounded reference figures (USDA FoodData Central / NZ FOODfiles
//  order of magnitude). They are labelled "Typical values" in the UI so they
//  are never mistaken for a scanned label.
//

import Foundation

enum GenericNutrition {

    /// Per-100 g figures. Optional columns are nil when the food has none to
    /// speak of (e.g. salt in fruit) rather than zero, so the UI hides them.
    struct Entry: Equatable, Sendable {
        let kcal: Double
        let protein: Double
        let fat: Double
        let carbs: Double
        var saturatedFat: Double? = nil
        var sugars: Double? = nil
        var fibre: Double? = nil
        var salt: Double? = nil
    }

    // MARK: - Lookup

    /// Typical facts for a food name, or nil when nothing in the name is a
    /// known whole food. Specifics fall back to their family (cheddar → cheese,
    /// snapper → fish), and mixed names prefer the most specific token.
    static func entry(for name: String) -> Entry? {
        let tokens = IngredientMatcher.tokens(name)
        guard !tokens.isEmpty else { return nil }

        // Specific tokens first (those that have a parent), then generic ones.
        let ordered = tokens.sorted { a, b in
            let pa = IngredientMatcher.entry(for: a)?.parent != nil
            let pb = IngredientMatcher.entry(for: b)?.parent != nil
            if pa != pb { return pa }
            return a < b
        }
        for token in ordered {
            if let hit = table[token] { return hit }
        }
        // Families: "cheddar" → "cheese", "beefmince" → "mince".
        for token in ordered {
            for family in IngredientMatcher.ancestors(of: [token]).sorted() {
                if let hit = table[family] { return hit }
            }
        }
        return nil
    }

    /// Same as `entry(for:)` but as the shared facts model.
    static func facts(for name: String) -> ProductNutritionFacts? {
        guard let e = entry(for: name) else { return nil }
        var facts = ProductNutritionFacts()
        facts.source = .typical
        facts.energyKcal = e.kcal
        facts.protein = e.protein
        facts.fat = e.fat
        facts.carbs = e.carbs
        facts.saturatedFat = e.saturatedFat
        facts.sugars = e.sugars
        facts.fibre = e.fibre
        facts.salt = e.salt
        return facts
    }

    /// Fills only the macro columns that `facts` is missing. Used when a
    /// product record exists (brand, ratings, ingredients) but its nutrition
    /// columns are blank.
    static func fillingGaps(in facts: ProductNutritionFacts, for name: String) -> ProductNutritionFacts {
        guard let e = entry(for: name) else { return facts }
        var out = facts
        var usedTypical = false
        func fill(_ keyPath: WritableKeyPath<ProductNutritionFacts, Double?>, _ value: Double?) {
            guard out[keyPath: keyPath] == nil, let value else { return }
            out[keyPath: keyPath] = value
            usedTypical = true
        }
        fill(\.energyKcal, e.kcal)
        fill(\.protein, e.protein)
        fill(\.fat, e.fat)
        fill(\.carbs, e.carbs)
        fill(\.saturatedFat, e.saturatedFat)
        fill(\.sugars, e.sugars)
        fill(\.fibre, e.fibre)
        fill(\.salt, e.salt)
        if usedTypical && !facts.hasNutrition { out.source = .typical }
        return out
    }

    // MARK: - Table

    /// Keys are canonical matcher tokens (lowercase, singular, compounds
    /// collapsed), so "Free Range Eggs 12pk" → "egg" → this row.
    static let table: [String: Entry] = {
        var t: [String: Entry] = [:]
        func add(_ keys: String, _ e: Entry) {
            for k in keys.split(separator: " ") { t[String(k)] = e }
        }

        // Eggs & dairy
        add("egg", Entry(kcal: 143, protein: 12.6, fat: 9.5, carbs: 0.7, saturatedFat: 3.1, sugars: 0.4, salt: 0.35))
        add("milk", Entry(kcal: 64, protein: 3.4, fat: 3.6, carbs: 4.8, saturatedFat: 2.3, sugars: 4.8, salt: 0.1))
        add("almondmilk oatmilk soymilk ricemilk", Entry(kcal: 45, protein: 1.2, fat: 1.8, carbs: 6.0, sugars: 3.5, salt: 0.1))
        add("cream", Entry(kcal: 340, protein: 2.1, fat: 36, carbs: 2.8, saturatedFat: 23, sugars: 2.8, salt: 0.1))
        add("sourcream cremefraiche", Entry(kcal: 198, protein: 2.4, fat: 19, carbs: 4.6, saturatedFat: 12, sugars: 3.5, salt: 0.1))
        add("yoghurt coconutyoghurt", Entry(kcal: 61, protein: 3.5, fat: 3.3, carbs: 4.7, saturatedFat: 2.1, sugars: 4.7, salt: 0.1))
        add("butter ghee", Entry(kcal: 717, protein: 0.9, fat: 81, carbs: 0.1, saturatedFat: 51, salt: 1.5))
        add("cheese cheddar swisscheese gouda havarti", Entry(kcal: 403, protein: 25, fat: 33, carbs: 1.3, saturatedFat: 21, salt: 1.6))
        add("mozzarella", Entry(kcal: 280, protein: 22, fat: 20, carbs: 2.2, saturatedFat: 13, salt: 1.2))
        add("parmesan", Entry(kcal: 431, protein: 38, fat: 29, carbs: 4.1, saturatedFat: 19, salt: 1.8))
        add("feta", Entry(kcal: 264, protein: 14, fat: 21, carbs: 4.1, saturatedFat: 15, salt: 2.8))
        add("halloumi paneer", Entry(kcal: 321, protein: 22, fat: 25, carbs: 2.0, saturatedFat: 16, salt: 2.5))
        add("brie camembert goatcheese bluecheese", Entry(kcal: 334, protein: 21, fat: 28, carbs: 0.5, saturatedFat: 17, salt: 1.8))
        add("cottagecheese ricotta", Entry(kcal: 120, protein: 11, fat: 6.5, carbs: 3.5, saturatedFat: 4.0, salt: 0.6))
        add("creamcheese mascarpone", Entry(kcal: 342, protein: 6.0, fat: 34, carbs: 4.0, saturatedFat: 20, salt: 0.8))
        add("condensedmilk", Entry(kcal: 321, protein: 7.9, fat: 8.7, carbs: 54, saturatedFat: 5.5, sugars: 54, salt: 0.3))
        add("custard custardpowder", Entry(kcal: 118, protein: 3.0, fat: 4.5, carbs: 17, sugars: 12, salt: 0.2))
        add("icecream", Entry(kcal: 207, protein: 3.5, fat: 11, carbs: 24, saturatedFat: 6.8, sugars: 21, salt: 0.2))

        // Meat & poultry (raw, lean cuts)
        add("chicken chickenbreast", Entry(kcal: 120, protein: 22.5, fat: 2.6, carbs: 0, saturatedFat: 0.6, salt: 0.15))
        add("chickenthigh", Entry(kcal: 177, protein: 19, fat: 11, carbs: 0, saturatedFat: 3.0, salt: 0.2))
        add("chickenmince turkeymince", Entry(kcal: 143, protein: 17, fat: 8.1, carbs: 0, saturatedFat: 2.3, salt: 0.2))
        add("chickennugget", Entry(kcal: 296, protein: 15, fat: 20, carbs: 14, saturatedFat: 4.0, salt: 1.2))
        add("turkey", Entry(kcal: 114, protein: 23, fat: 1.5, carbs: 0, saturatedFat: 0.5, salt: 0.15))
        add("duck", Entry(kcal: 337, protein: 19, fat: 28, carbs: 0, saturatedFat: 9.7, salt: 0.15))
        add("beef steak", Entry(kcal: 187, protein: 26, fat: 9.0, carbs: 0, saturatedFat: 3.9, salt: 0.15))
        add("mince beefmince", Entry(kcal: 250, protein: 17, fat: 20, carbs: 0, saturatedFat: 8.0, salt: 0.2))
        add("porkmince lambmince", Entry(kcal: 263, protein: 17, fat: 21, carbs: 0, saturatedFat: 8.0, salt: 0.2))
        add("pork", Entry(kcal: 200, protein: 21, fat: 12, carbs: 0, saturatedFat: 4.5, salt: 0.15))
        add("lamb mutton", Entry(kcal: 258, protein: 17, fat: 21, carbs: 0, saturatedFat: 9.5, salt: 0.15))
        add("veal venison", Entry(kcal: 130, protein: 22, fat: 4.0, carbs: 0, saturatedFat: 1.5, salt: 0.15))
        add("bacon pancetta", Entry(kcal: 300, protein: 15, fat: 26, carbs: 0.5, saturatedFat: 9.0, salt: 3.5))
        add("ham", Entry(kcal: 145, protein: 21, fat: 6.0, carbs: 1.5, saturatedFat: 2.0, salt: 2.5))
        add("sausage hotdog", Entry(kcal: 300, protein: 13, fat: 26, carbs: 5.0, saturatedFat: 10, salt: 2.0))
        add("chorizo salami pepperoni", Entry(kcal: 420, protein: 22, fat: 36, carbs: 2.0, saturatedFat: 13, salt: 4.0))
        add("prosciutto", Entry(kcal: 250, protein: 26, fat: 16, carbs: 0.5, saturatedFat: 5.5, salt: 5.0))
        add("cornedbeef", Entry(kcal: 210, protein: 25, fat: 12, carbs: 0.5, saturatedFat: 5.0, salt: 2.4))

        // Seafood (raw)
        add("fish snapper cod hoki tarakihi gurnard kahawai trevally hake haddock basa tilapia barramundi flounder monkfish bass",
            Entry(kcal: 96, protein: 20, fat: 1.5, carbs: 0, saturatedFat: 0.3, salt: 0.2))
        add("salmon trout kingfish", Entry(kcal: 208, protein: 20, fat: 13, carbs: 0, saturatedFat: 3.0, salt: 0.15))
        add("tuna swordfish mackerel", Entry(kcal: 144, protein: 23, fat: 5.0, carbs: 0, saturatedFat: 1.3, salt: 0.15))
        add("sardine anchovy", Entry(kcal: 208, protein: 25, fat: 11, carbs: 0, saturatedFat: 1.5, salt: 1.0))
        add("seafood shrimp crab lobster crayfish", Entry(kcal: 85, protein: 18, fat: 1.0, carbs: 0.5, saturatedFat: 0.2, salt: 0.6))
        add("mussel clam pipi cockle oyster scallop", Entry(kcal: 86, protein: 12, fat: 2.2, carbs: 3.7, saturatedFat: 0.4, salt: 0.7))
        add("squid octopus", Entry(kcal: 92, protein: 16, fat: 1.4, carbs: 3.1, saturatedFat: 0.4, salt: 0.1))
        add("surimi fishfinger", Entry(kcal: 200, protein: 12, fat: 9.0, carbs: 18, saturatedFat: 1.0, salt: 0.9))

        // Vegetables (raw)
        add("onion shallot leek", Entry(kcal: 40, protein: 1.1, fat: 0.1, carbs: 9.3, sugars: 4.2, fibre: 1.7))
        add("springonion chive", Entry(kcal: 32, protein: 1.8, fat: 0.2, carbs: 7.3, sugars: 2.3, fibre: 2.6))
        add("garlic", Entry(kcal: 149, protein: 6.4, fat: 0.5, carbs: 33, sugars: 1.0, fibre: 2.1))
        add("capsicum", Entry(kcal: 31, protein: 1.0, fat: 0.3, carbs: 6.0, sugars: 4.2, fibre: 2.1))
        add("chilli jalapeno habanero", Entry(kcal: 40, protein: 1.9, fat: 0.4, carbs: 8.8, sugars: 5.3, fibre: 1.5))
        add("tomato", Entry(kcal: 18, protein: 0.9, fat: 0.2, carbs: 3.9, sugars: 2.6, fibre: 1.2))
        add("sundriedtomato", Entry(kcal: 258, protein: 14, fat: 3.0, carbs: 56, sugars: 38, fibre: 12, salt: 5.0))
        add("potato", Entry(kcal: 77, protein: 2.0, fat: 0.1, carbs: 17, sugars: 0.8, fibre: 2.2))
        add("kumara yam", Entry(kcal: 86, protein: 1.6, fat: 0.1, carbs: 20, sugars: 4.2, fibre: 3.0))
        add("taro cassava", Entry(kcal: 140, protein: 1.5, fat: 0.2, carbs: 34, sugars: 1.0, fibre: 3.5))
        add("carrot", Entry(kcal: 41, protein: 0.9, fat: 0.2, carbs: 9.6, sugars: 4.7, fibre: 2.8))
        add("celery", Entry(kcal: 16, protein: 0.7, fat: 0.2, carbs: 3.0, sugars: 1.3, fibre: 1.6))
        add("celeriac turnip swede parsnip", Entry(kcal: 50, protein: 1.3, fat: 0.3, carbs: 11, sugars: 4.5, fibre: 3.0))
        add("broccoli broccolini", Entry(kcal: 34, protein: 2.8, fat: 0.4, carbs: 6.6, sugars: 1.7, fibre: 2.6))
        add("cauliflower", Entry(kcal: 25, protein: 1.9, fat: 0.3, carbs: 5.0, sugars: 1.9, fibre: 2.0))
        add("cabbage bokchoy", Entry(kcal: 25, protein: 1.3, fat: 0.1, carbs: 5.8, sugars: 3.2, fibre: 2.5))
        add("brusselssprout", Entry(kcal: 43, protein: 3.4, fat: 0.3, carbs: 9.0, sugars: 2.2, fibre: 3.8))
        add("spinach silverbeet kale watercress cress arugula", Entry(kcal: 26, protein: 2.9, fat: 0.4, carbs: 3.6, sugars: 0.4, fibre: 2.2))
        add("lettuce", Entry(kcal: 15, protein: 1.4, fat: 0.2, carbs: 2.9, sugars: 0.8, fibre: 1.3))
        add("zucchini cucumber gherkin", Entry(kcal: 16, protein: 1.0, fat: 0.2, carbs: 3.1, sugars: 2.0, fibre: 1.0))
        add("eggplant", Entry(kcal: 25, protein: 1.0, fat: 0.2, carbs: 5.9, sugars: 3.5, fibre: 3.0))
        add("pumpkin butternut", Entry(kcal: 34, protein: 1.0, fat: 0.1, carbs: 8.0, sugars: 2.8, fibre: 1.5))
        add("corn creamedcorn popcorn", Entry(kcal: 86, protein: 3.3, fat: 1.4, carbs: 19, sugars: 3.2, fibre: 2.7))
        add("pea snowpea greenbean edamame", Entry(kcal: 60, protein: 4.0, fat: 0.4, carbs: 10, sugars: 4.0, fibre: 4.5))
        add("beansprout sprout", Entry(kcal: 30, protein: 3.0, fat: 0.2, carbs: 5.9, sugars: 4.1, fibre: 1.8))
        add("mushroom shiitake portobello enoki", Entry(kcal: 22, protein: 3.1, fat: 0.3, carbs: 3.3, sugars: 2.0, fibre: 1.0))
        add("asparagus", Entry(kcal: 20, protein: 2.2, fat: 0.1, carbs: 3.9, sugars: 1.9, fibre: 2.1))
        add("beetroot", Entry(kcal: 43, protein: 1.6, fat: 0.2, carbs: 9.6, sugars: 6.8, fibre: 2.8))
        add("radish fennel", Entry(kcal: 20, protein: 0.9, fat: 0.1, carbs: 4.0, sugars: 2.0, fibre: 2.0))
        add("avocado", Entry(kcal: 160, protein: 2.0, fat: 15, carbs: 8.5, saturatedFat: 2.1, sugars: 0.7, fibre: 6.7))
        add("artichoke okra", Entry(kcal: 40, protein: 2.5, fat: 0.2, carbs: 9.0, sugars: 1.5, fibre: 4.0))
        add("olive", Entry(kcal: 115, protein: 0.8, fat: 11, carbs: 6.0, saturatedFat: 1.4, fibre: 3.2, salt: 3.5))
        add("seaweed nori", Entry(kcal: 35, protein: 5.8, fat: 0.3, carbs: 5.1, fibre: 0.3, salt: 0.5))

        // Fruit
        add("apple pear quince", Entry(kcal: 52, protein: 0.3, fat: 0.2, carbs: 14, sugars: 10, fibre: 2.4))
        add("banana plantain", Entry(kcal: 89, protein: 1.1, fat: 0.3, carbs: 23, sugars: 12, fibre: 2.6))
        add("orange mandarin grapefruit", Entry(kcal: 47, protein: 0.9, fat: 0.1, carbs: 12, sugars: 9.4, fibre: 2.4))
        add("lemon lime", Entry(kcal: 29, protein: 1.1, fat: 0.3, carbs: 9.3, sugars: 2.5, fibre: 2.8))
        add("grape", Entry(kcal: 69, protein: 0.7, fat: 0.2, carbs: 18, sugars: 15, fibre: 0.9))
        add("berry strawberry raspberry blackberry boysenberry cranberry gooseberry blackcurrant",
            Entry(kcal: 43, protein: 1.0, fat: 0.4, carbs: 10, sugars: 5.0, fibre: 4.0))
        add("blueberry cherry", Entry(kcal: 57, protein: 0.7, fat: 0.3, carbs: 14, sugars: 10, fibre: 2.4))
        add("peach nectarine plum apricot", Entry(kcal: 42, protein: 0.9, fat: 0.3, carbs: 10, sugars: 8.4, fibre: 1.5))
        add("mango papaya", Entry(kcal: 60, protein: 0.8, fat: 0.4, carbs: 15, sugars: 14, fibre: 1.6))
        add("pineapple", Entry(kcal: 50, protein: 0.5, fat: 0.1, carbs: 13, sugars: 9.9, fibre: 1.4))
        add("kiwifruit feijoa", Entry(kcal: 61, protein: 1.1, fat: 0.5, carbs: 15, sugars: 9.0, fibre: 3.0))
        add("melon watermelon rockmelon honeydew", Entry(kcal: 32, protein: 0.7, fat: 0.2, carbs: 8.0, sugars: 7.5, fibre: 0.6))
        add("passionfruit pomegranate", Entry(kcal: 90, protein: 2.0, fat: 0.8, carbs: 20, sugars: 12, fibre: 7.0))
        add("fig persimmon lychee guava tamarillo", Entry(kcal: 70, protein: 0.8, fat: 0.3, carbs: 18, sugars: 14, fibre: 2.5))
        add("date raisin sultana currant prune", Entry(kcal: 290, protein: 2.5, fat: 0.4, carbs: 70, sugars: 60, fibre: 6.5))
        add("coconut desiccatedcoconut", Entry(kcal: 354, protein: 3.3, fat: 33, carbs: 15, saturatedFat: 30, sugars: 6.2, fibre: 9.0))
        add("rhubarb", Entry(kcal: 21, protein: 0.9, fat: 0.2, carbs: 4.5, sugars: 1.1, fibre: 1.8))

        // Herbs & spices
        add("parsley cilantro basil mint oregano thyme rosemary sage dill tarragon marjoram mixedherb bayleaf curryleaf lemongrass kaffirlime",
            Entry(kcal: 36, protein: 3.0, fat: 0.7, carbs: 6.3, sugars: 0.9, fibre: 3.3))
        add("ginger", Entry(kcal: 80, protein: 1.8, fat: 0.8, carbs: 18, sugars: 1.7, fibre: 2.0))
        add("pepper peppercorn paprika cumin turmeric cinnamon nutmeg clove cardamom chilliflake chillipowder currypowder garlicpowder onionpowder allspice mustardseed mustardpowder fennelseed corianderseed staranise sumac garammasala fivespice cayenne mixedspice saffron",
            Entry(kcal: 300, protein: 11, fat: 10, carbs: 50, sugars: 3.0, fibre: 25))

        // Grains, pasta, bakery (dry / as sold)
        add("rice arborio sushirice wildrice", Entry(kcal: 360, protein: 7.0, fat: 0.7, carbs: 79, sugars: 0.1, fibre: 1.3))
        add("quinoa buckwheat millet freekeh bulgur", Entry(kcal: 365, protein: 13, fat: 5.0, carbs: 64, sugars: 2.0, fibre: 7.0))
        add("couscous semolina polenta", Entry(kcal: 370, protein: 12, fat: 1.0, carbs: 75, fibre: 4.0))
        add("barley", Entry(kcal: 354, protein: 12, fat: 2.3, carbs: 73, sugars: 0.8, fibre: 17))
        add("oat muesli granola", Entry(kcal: 380, protein: 12, fat: 7.0, carbs: 63, sugars: 5.0, fibre: 9.0))
        add("pasta noodle ricenoodle", Entry(kcal: 355, protein: 12, fat: 1.5, carbs: 72, sugars: 2.5, fibre: 3.0))
        add("cereal cornflake", Entry(kcal: 370, protein: 7.0, fat: 1.0, carbs: 84, sugars: 8.0, fibre: 3.0, salt: 1.3))
        add("cornchip potatochip", Entry(kcal: 520, protein: 6.5, fat: 30, carbs: 55, saturatedFat: 3.5, sugars: 1.0, fibre: 4.0, salt: 1.2))
        add("bread bun bagel pita naan crumpet", Entry(kcal: 265, protein: 9.0, fat: 3.2, carbs: 49, sugars: 5.0, fibre: 2.7, salt: 1.2))
        add("breadcrumb crouton cracker", Entry(kcal: 395, protein: 13, fat: 5.3, carbs: 72, sugars: 6.0, fibre: 4.5, salt: 1.5))
        add("tortilla ricepaper springrollwrapper wontonwrapper dumplingwrapper", Entry(kcal: 300, protein: 8.0, fat: 7.0, carbs: 50, fibre: 3.0, salt: 1.5))
        add("croissant pastry puffpastry shortcrustpastry filo", Entry(kcal: 400, protein: 7.0, fat: 24, carbs: 40, saturatedFat: 13, sugars: 4.0, salt: 1.0))
        add("pizzabase", Entry(kcal: 270, protein: 9.0, fat: 3.5, carbs: 50, sugars: 3.0, fibre: 2.5, salt: 1.2))
        add("biscuit", Entry(kcal: 480, protein: 6.0, fat: 22, carbs: 65, saturatedFat: 11, sugars: 30, salt: 0.8))
        add("muffin scone cake", Entry(kcal: 370, protein: 5.5, fat: 16, carbs: 52, saturatedFat: 6.0, sugars: 28, salt: 0.7))
        add("pancake waffle", Entry(kcal: 230, protein: 6.0, fat: 9.0, carbs: 30, saturatedFat: 2.0, sugars: 6.0, salt: 0.9))
        add("springroll dumpling", Entry(kcal: 210, protein: 7.0, fat: 9.0, carbs: 25, saturatedFat: 2.0, salt: 1.0))

        // Legumes, nuts, seeds
        add("chickpea lentil bean kidneybean blackbean cannellinibean butterbean borlottibean pintobean broadbean splitpea",
            Entry(kcal: 120, protein: 8.0, fat: 1.5, carbs: 20, sugars: 1.0, fibre: 7.0, salt: 0.3))
        add("bakedbean refriedbean", Entry(kcal: 95, protein: 5.0, fat: 0.6, carbs: 16, sugars: 5.0, fibre: 5.0, salt: 0.9))
        add("tofu", Entry(kcal: 76, protein: 8.1, fat: 4.8, carbs: 1.9, saturatedFat: 0.7, fibre: 0.3))
        add("tempeh", Entry(kcal: 192, protein: 20, fat: 11, carbs: 7.6, saturatedFat: 2.5, fibre: 5.0))
        add("nut almond cashew walnut pecan pistachio hazelnut macadamia brazilnut pinenut",
            Entry(kcal: 600, protein: 20, fat: 52, carbs: 18, saturatedFat: 5.0, sugars: 4.0, fibre: 8.0))
        add("peanut", Entry(kcal: 567, protein: 26, fat: 49, carbs: 16, saturatedFat: 7.0, sugars: 4.0, fibre: 8.5))
        add("chestnut", Entry(kcal: 196, protein: 1.6, fat: 1.3, carbs: 44, sugars: 11, fibre: 5.0))
        add("nutbutter peanutbutter almondbutter cashewbutter", Entry(kcal: 590, protein: 25, fat: 50, carbs: 20, saturatedFat: 10, sugars: 9.0, fibre: 6.0, salt: 1.0))
        add("sesame chia flaxseed pepita sunflowerseed poppyseed hempseed",
            Entry(kcal: 540, protein: 20, fat: 45, carbs: 20, saturatedFat: 5.0, sugars: 1.0, fibre: 15))

        // Oils, condiments
        add("oil sesameoil truffleoil chillioil coconutoil", Entry(kcal: 884, protein: 0, fat: 100, carbs: 0, saturatedFat: 14))
        add("lard", Entry(kcal: 900, protein: 0, fat: 100, carbs: 0, saturatedFat: 39))
        add("mayonnaise aioli", Entry(kcal: 680, protein: 1.0, fat: 75, carbs: 1.0, saturatedFat: 6.0, sugars: 1.0, salt: 1.5))
        add("mustard", Entry(kcal: 66, protein: 4.4, fat: 4.0, carbs: 5.8, sugars: 3.0, fibre: 3.3, salt: 2.8))
        add("tomatosauce bbqsauce relish chutney", Entry(kcal: 110, protein: 1.2, fat: 0.2, carbs: 26, sugars: 22, salt: 2.0))
        add("hotsauce sriracha chillisauce", Entry(kcal: 60, protein: 1.0, fat: 0.5, carbs: 13, sugars: 10, salt: 5.0))
        add("sweetchillisauce", Entry(kcal: 220, protein: 0.5, fat: 0.2, carbs: 55, sugars: 50, salt: 2.0))
        add("soysauce fishsauce worcestershire teriyaki", Entry(kcal: 55, protein: 6.0, fat: 0.1, carbs: 6.0, sugars: 3.0, salt: 14))
        add("oystersauce hoisinsauce", Entry(kcal: 150, protein: 2.5, fat: 1.0, carbs: 33, sugars: 25, salt: 6.0))
        add("currypaste miso", Entry(kcal: 180, protein: 7.0, fat: 7.0, carbs: 22, sugars: 8.0, salt: 9.0))
        add("tahini", Entry(kcal: 595, protein: 17, fat: 54, carbs: 21, saturatedFat: 7.5, sugars: 0.5, fibre: 9.3))
        add("hummus", Entry(kcal: 237, protein: 7.9, fat: 18, carbs: 14, saturatedFat: 2.6, sugars: 0.3, fibre: 6.0, salt: 0.9))
        add("pesto", Entry(kcal: 420, protein: 6.0, fat: 42, carbs: 6.0, saturatedFat: 7.0, sugars: 2.0, salt: 2.0))
        add("pickle caper", Entry(kcal: 20, protein: 0.5, fat: 0.3, carbs: 3.0, sugars: 1.5, fibre: 1.0, salt: 3.0))
        add("vinegar balsamic redwinevinegar whitewinevinegar cidervinegar ricevinegar maltvinegar", Entry(kcal: 20, protein: 0, fat: 0, carbs: 1.0, sugars: 0.5))
        add("tomatopaste", Entry(kcal: 82, protein: 4.3, fat: 0.5, carbs: 19, sugars: 12, fibre: 4.1, salt: 0.2))
        add("passata salsa", Entry(kcal: 30, protein: 1.5, fat: 0.2, carbs: 6.0, sugars: 4.5, fibre: 1.5, salt: 0.7))
        add("gravy", Entry(kcal: 40, protein: 1.5, fat: 2.0, carbs: 4.0, salt: 1.0))
        add("vegemite marmite", Entry(kcal: 180, protein: 25, fat: 0.5, carbs: 20, sugars: 2.0, salt: 8.0))
        add("mirin ricewine", Entry(kcal: 230, protein: 0.2, fat: 0, carbs: 43, sugars: 40))
        add("tzatziki", Entry(kcal: 95, protein: 3.5, fat: 7.0, carbs: 4.0, saturatedFat: 4.5, sugars: 2.5, salt: 0.8))

        // Baking & sweet
        add("flour selfraisingflour riceflour", Entry(kcal: 364, protein: 10, fat: 1.0, carbs: 76, sugars: 0.3, fibre: 2.7))
        add("wholemealflour", Entry(kcal: 340, protein: 13, fat: 2.5, carbs: 72, sugars: 0.4, fibre: 11))
        add("coconutflour almondmeal", Entry(kcal: 500, protein: 18, fat: 40, carbs: 20, saturatedFat: 6.0, sugars: 5.0, fibre: 12))
        add("cornstarch", Entry(kcal: 381, protein: 0.3, fat: 0.1, carbs: 91, fibre: 0.9))
        add("bakingsoda bakingpowder yeast gelatine foodcolouring", Entry(kcal: 50, protein: 5.0, fat: 0.5, carbs: 10, salt: 5.0))
        add("cocoa", Entry(kcal: 228, protein: 20, fat: 14, carbs: 58, saturatedFat: 8.0, sugars: 1.8, fibre: 33))
        add("vanilla", Entry(kcal: 288, protein: 0.1, fat: 0.1, carbs: 13, sugars: 13))
        add("sugar castersugar rawsugar palmsugar coconutsugar icingsugar", Entry(kcal: 387, protein: 0, fat: 0, carbs: 100, sugars: 100))
        add("brownsugar", Entry(kcal: 380, protein: 0.1, fat: 0, carbs: 98, sugars: 97))
        add("honey goldensyrup maplesyrup treacle molasses", Entry(kcal: 304, protein: 0.3, fat: 0, carbs: 82, sugars: 82))
        add("chocolate nutella", Entry(kcal: 535, protein: 6.0, fat: 31, carbs: 58, saturatedFat: 19, sugars: 52, fibre: 4.0))
        add("jam marmalade jelly", Entry(kcal: 265, protein: 0.4, fat: 0.1, carbs: 66, sugars: 60, fibre: 1.0))
        add("caramel toffee fudge lolly marshmallow", Entry(kcal: 390, protein: 1.5, fat: 7.0, carbs: 82, saturatedFat: 4.5, sugars: 70))

        // Beverages & pantry
        add("water", Entry(kcal: 0, protein: 0, fat: 0, carbs: 0))
        add("tea coffee icedtea", Entry(kcal: 1, protein: 0.1, fat: 0, carbs: 0.2))
        add("icedcoffee", Entry(kcal: 60, protein: 2.5, fat: 1.5, carbs: 9.0, sugars: 8.5))
        add("beer cider", Entry(kcal: 43, protein: 0.5, fat: 0, carbs: 3.6, sugars: 1.5))
        add("wine redwine whitewine", Entry(kcal: 83, protein: 0.1, fat: 0, carbs: 2.6, sugars: 0.8))
        add("lemonade cola kombucha", Entry(kcal: 40, protein: 0, fat: 0, carbs: 10, sugars: 10))
        add("ice iceblock", Entry(kcal: 0, protein: 0, fat: 0, carbs: 0))
        add("salt", Entry(kcal: 0, protein: 0, fat: 0, carbs: 0, salt: 100))
        add("stock chickenstock beefstock vegetablestock fishstock", Entry(kcal: 5, protein: 0.5, fat: 0.1, carbs: 0.5, salt: 0.8))
        add("stockcube stockpowder", Entry(kcal: 200, protein: 12, fat: 8.0, carbs: 20, salt: 45))
        add("coconutmilk", Entry(kcal: 180, protein: 1.8, fat: 18, carbs: 2.8, saturatedFat: 16, sugars: 2.0))
        add("coconutcream", Entry(kcal: 230, protein: 2.3, fat: 24, carbs: 3.3, saturatedFat: 21, sugars: 2.5))
        add("coconutwater", Entry(kcal: 19, protein: 0.7, fat: 0.2, carbs: 3.7, sugars: 2.6))
        add("whey milkpowder", Entry(kcal: 380, protein: 30, fat: 5.0, carbs: 50, sugars: 40, salt: 0.9))
        add("evaporatedmilk buttermilk", Entry(kcal: 100, protein: 5.0, fat: 4.0, carbs: 10, saturatedFat: 2.5, sugars: 10, salt: 0.3))

        return t
    }()
}
