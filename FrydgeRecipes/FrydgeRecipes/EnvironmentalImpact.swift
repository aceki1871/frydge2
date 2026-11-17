//
//  EnvironmentalImpact.swift
//  FrydgeRecipes
//
//  One environmental rating for a product, whichever source produced it:
//  the Eco-Score stored in the Frydge products DB (sparse — roughly 1% of
//  rows), Open Food Facts' live Green-Score, or a typical-impact estimate
//  for the kind of food. The estimate exists so an everyday item like
//  "beef mince" or "lentils" still gets a grade instead of a blank, and it
//  is always labelled as an estimate in the UI.
//
//  Grades follow the Eco-Score letter scale (A best … E worst). Carbon
//  figures are kg CO₂e per kg of food, Agribalyse order of magnitude, which
//  is the same life-cycle database the Eco-Score is built on.
//

import Foundation

// MARK: - Model

struct EnvironmentalImpact: Equatable, Sendable {

    enum Source: Equatable, Sendable {
        /// Eco-Score column from the Frydge products Worker.
        case ecoScore
        /// Open Food Facts public API (`environmental_score_grade`).
        case greenScore
        /// Built-in typical figure for this kind of food.
        case estimated(basis: String)

        var label: String {
            switch self {
            case .ecoScore:   return "Eco-Score"
            case .greenScore: return "Green-Score"
            case .estimated:  return "Estimated"
            }
        }

        var isEstimate: Bool {
            if case .estimated = self { return true }
            return false
        }
    }

    /// Lowercase "a"…"e".
    let grade: String
    /// 0–100 where the source provides one (Eco-Score / Green-Score).
    var score: Int?
    /// kg CO₂e per kg of food, where known.
    var co2PerKg: Double?
    let source: Source

    init?(grade raw: String?, score: Int? = nil, co2PerKg: Double? = nil, source: Source) {
        guard let g = ProductNutritionFacts.letterGrade(raw), ("a"..."e").contains(g) else { return nil }
        self.grade = g
        self.score = score
        self.co2PerKg = co2PerKg
        self.source = source
    }

    /// Plain-English reading of the grade.
    var impactLabel: String {
        switch grade {
        case "a": return "Very low impact"
        case "b": return "Low impact"
        case "c": return "Moderate impact"
        case "d": return "High impact"
        default:  return "Very high impact"
        }
    }

    /// "2.7 kg CO₂e / kg" or nil.
    var co2Label: String? {
        guard let kg = co2PerKg else { return nil }
        let text = kg >= 10 ? String(Int(kg.rounded())) : String(format: "%.1f", kg)
        return "\(text) kg CO₂e / kg"
    }

    /// Letter grade for a carbon footprint, used by the estimate.
    static func grade(forCO2PerKg kg: Double) -> String {
        switch kg {
        case ..<1.0:  return "a"
        case ..<2.5:  return "b"
        case ..<6.0:  return "c"
        case ..<14.0: return "d"
        default:      return "e"
        }
    }
}

// MARK: - Typical impact by food

enum GenericEnvironmentalImpact {

    struct Entry: Equatable, Sendable {
        /// kg CO₂e per kg of food as sold.
        let co2PerKg: Double
        /// Short description used as the "based on …" basis.
        let basis: String
        var grade: String { EnvironmentalImpact.grade(forCO2PerKg: co2PerKg) }
    }

    /// Typical impact for a food name, or nil when nothing in the name is a
    /// known whole food. Uses the same token / family fallback as
    /// `GenericNutrition` so the two always agree on what a name is.
    static func entry(for name: String) -> Entry? {
        let tokens = IngredientMatcher.tokens(name)
        guard !tokens.isEmpty else { return nil }

        let ordered = tokens.sorted { a, b in
            let pa = IngredientMatcher.entry(for: a)?.parent != nil
            let pb = IngredientMatcher.entry(for: b)?.parent != nil
            if pa != pb { return pa }
            return a < b
        }
        for token in ordered {
            if let hit = table[token] { return hit }
        }
        for token in ordered {
            for family in IngredientMatcher.ancestors(of: [token]).sorted() {
                if let hit = table[family] { return hit }
            }
        }
        return nil
    }

    static func impact(for name: String) -> EnvironmentalImpact? {
        guard let e = entry(for: name) else { return nil }
        return EnvironmentalImpact(grade: e.grade, co2PerKg: e.co2PerKg, source: .estimated(basis: e.basis))
    }

    /// Keys are canonical matcher tokens, as in `GenericNutrition.table`.
    static let table: [String: Entry] = {
        var t: [String: Entry] = [:]
        func add(_ keys: String, _ co2: Double, _ basis: String) {
            let e = Entry(co2PerKg: co2, basis: basis)
            for k in keys.split(separator: " ") { t[String(k)] = e }
        }

        // Red meat — the heaviest footprint in the kitchen.
        add("beef steak cornedbeef", 33, "typical beef")
        add("mince beefmince", 28, "typical beef mince")
        add("veal", 30, "typical veal")
        add("lamb mutton lambmince", 35, "typical lamb")
        add("venison", 25, "typical venison")

        // Pork & poultry
        add("pork porkmince", 6.5, "typical pork")
        add("bacon pancetta ham prosciutto", 8.0, "typical cured pork")
        add("sausage hotdog chorizo salami pepperoni", 7.5, "typical processed meat")
        add("chicken chickenbreast chickenthigh chickenmince chickennugget", 4.8, "typical chicken")
        add("turkey turkeymince", 5.0, "typical turkey")
        add("duck", 5.5, "typical duck")

        // Eggs & dairy
        add("egg", 2.7, "typical eggs")
        add("milk evaporatedmilk buttermilk", 1.3, "typical dairy milk")
        add("condensedmilk whey milkpowder", 5.0, "typical concentrated dairy")
        add("almondmilk oatmilk soymilk ricemilk", 0.6, "typical plant milk")
        add("cream sourcream cremefraiche", 5.0, "typical cream")
        add("yoghurt", 2.0, "typical yoghurt")
        add("coconutyoghurt", 1.5, "typical coconut yoghurt")
        add("butter ghee", 8.5, "typical butter")
        add("cheese cheddar swisscheese gouda havarti parmesan mozzarella feta halloumi paneer brie camembert goatcheese bluecheese", 7.5, "typical cheese")
        add("cottagecheese ricotta creamcheese mascarpone", 4.0, "typical soft cheese")
        add("icecream custard custardpowder", 3.5, "typical dairy dessert")

        // Seafood
        add("fish snapper cod hoki tarakihi gurnard kahawai trevally hake haddock basa tilapia barramundi flounder monkfish bass surimi fishfinger", 4.5, "typical white fish")
        add("salmon trout kingfish", 5.5, "typical farmed salmon")
        add("tuna swordfish mackerel sardine anchovy", 5.5, "typical oily fish")
        add("seafood shrimp crab lobster crayfish", 10, "typical shellfish")
        add("mussel clam pipi cockle oyster scallop", 1.5, "typical farmed shellfish")
        add("squid octopus", 5.0, "typical squid")

        // Vegetables
        add("onion shallot leek springonion chive garlic", 0.4, "typical alliums")
        add("potato kumara yam taro cassava carrot celeriac turnip swede parsnip beetroot radish fennel", 0.4, "typical root vegetables")
        add("tomato", 0.9, "typical tomatoes")
        add("sundriedtomato tomatopaste passata salsa", 1.6, "typical tomato products")
        add("capsicum chilli jalapeno habanero eggplant zucchini cucumber gherkin", 0.9, "typical salad vegetables")
        add("broccoli broccolini cauliflower cabbage bokchoy brusselssprout spinach silverbeet kale watercress cress arugula lettuce celery asparagus artichoke okra", 0.5, "typical green vegetables")
        add("pumpkin butternut corn creamedcorn popcorn", 0.6, "typical vegetables")
        add("pea snowpea greenbean edamame beansprout sprout", 0.9, "typical legumes")
        add("mushroom shiitake portobello enoki", 1.2, "typical mushrooms")
        add("avocado", 1.5, "typical avocado")
        add("olive", 1.8, "typical olives")
        add("seaweed nori", 0.5, "typical seaweed")

        // Fruit
        add("apple pear quince orange mandarin grapefruit lemon lime grape peach nectarine plum apricot kiwifruit feijoa melon watermelon rockmelon honeydew rhubarb fig persimmon lychee guava tamarillo passionfruit pomegranate", 0.5, "typical fruit")
        add("banana plantain pineapple mango papaya", 0.8, "typical tropical fruit")
        add("berry strawberry raspberry blackberry boysenberry cranberry gooseberry blackcurrant blueberry cherry", 1.3, "typical berries")
        add("date raisin sultana currant prune", 2.0, "typical dried fruit")
        add("coconut desiccatedcoconut coconutmilk coconutcream coconutwater", 2.2, "typical coconut")

        // Herbs & spices
        add("parsley cilantro basil mint oregano thyme rosemary sage dill tarragon marjoram mixedherb bayleaf curryleaf lemongrass kaffirlime ginger", 0.8, "typical fresh herbs")
        add("pepper peppercorn paprika cumin turmeric cinnamon nutmeg clove cardamom chilliflake chillipowder currypowder garlicpowder onionpowder allspice mustardseed mustardpowder fennelseed corianderseed staranise sumac garammasala fivespice cayenne mixedspice saffron vanilla", 3.0, "typical dried spices")

        // Grains, pasta, bakery
        add("rice arborio sushirice wildrice ricenoodle riceflour ricepaper", 2.7, "typical rice")
        add("quinoa buckwheat millet freekeh bulgur couscous semolina polenta barley", 1.4, "typical grains")
        add("oat muesli granola cereal cornflake", 1.2, "typical cereals")
        add("pasta noodle", 1.3, "typical pasta")
        add("flour selfraisingflour wholemealflour cornstarch", 0.8, "typical flour")
        add("coconutflour almondmeal", 2.5, "typical nut flour")
        add("bread bun bagel pita naan crumpet breadcrumb crouton cracker tortilla pizzabase springrollwrapper wontonwrapper dumplingwrapper", 1.1, "typical bread")
        add("croissant pastry puffpastry shortcrustpastry filo biscuit muffin scone cake pancake waffle", 3.0, "typical baked goods")
        add("cornchip potatochip", 2.5, "typical snack foods")
        add("springroll dumpling", 2.5, "typical prepared foods")

        // Legumes, nuts, seeds
        add("chickpea lentil bean kidneybean blackbean cannellinibean butterbean borlottibean pintobean broadbean splitpea bakedbean refriedbean", 0.9, "typical pulses")
        add("tofu tempeh", 2.0, "typical soy foods")
        add("nut almond cashew walnut pecan pistachio hazelnut macadamia brazilnut pinenut chestnut peanut nutbutter peanutbutter almondbutter cashewbutter tahini", 1.5, "typical nuts")
        add("sesame chia flaxseed pepita sunflowerseed poppyseed hempseed", 1.5, "typical seeds")
        add("hummus", 1.4, "typical hummus")

        // Oils, condiments
        add("oil sesameoil truffleoil chillioil", 3.5, "typical vegetable oil")
        add("coconutoil", 3.0, "typical coconut oil")
        add("lard", 6.0, "typical animal fat")
        add("mayonnaise aioli pesto", 3.5, "typical oil-based sauces")
        add("mustard tomatosauce bbqsauce relish chutney hotsauce sriracha chillisauce sweetchillisauce soysauce fishsauce worcestershire teriyaki oystersauce hoisinsauce currypaste miso pickle caper vinegar balsamic redwinevinegar whitewinevinegar cidervinegar ricevinegar maltvinegar gravy vegemite marmite mirin ricewine", 1.5, "typical condiments")
        add("tzatziki", 2.0, "typical dairy dips")

        // Sweet & baking
        add("sugar castersugar rawsugar palmsugar coconutsugar icingsugar brownsugar", 1.5, "typical sugar")
        add("honey goldensyrup maplesyrup treacle molasses jam marmalade jelly", 1.8, "typical sweet spreads")
        add("chocolate nutella", 15, "typical chocolate")
        add("cocoa", 15, "typical cocoa")
        add("caramel toffee fudge lolly marshmallow", 3.0, "typical confectionery")
        add("bakingsoda bakingpowder yeast gelatine foodcolouring salt", 0.5, "typical pantry staples")

        // Drinks & pantry
        add("water ice iceblock", 0.1, "typical water")
        add("tea", 8.0, "typical dried tea")
        add("coffee", 15, "typical coffee beans")
        add("icedtea icedcoffee lemonade cola kombucha", 0.6, "typical soft drinks")
        add("beer cider", 0.8, "typical beer")
        add("wine redwine whitewine", 1.6, "typical wine")
        add("stock chickenstock beefstock vegetablestock fishstock", 0.5, "typical stock")
        add("stockcube stockpowder", 3.0, "typical stock concentrate")

        return t
    }()
}
