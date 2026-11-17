//
//  IngredientMatcherTests.swift
//  FrydgeRecipes Tests
//
//  Fridge ↔ recipe ingredient name matching (IngredientMatcher.swift).
//

import Testing
import Foundation
@testable import FrydgeRecipes

@Suite("Ingredient matcher")
struct IngredientMatcherTests {

    // MARK: - Noise

    @Test("Brand and marketing words in a product title never match a recipe line")
    func brandWordsIgnored() {
        // Regression: "Best Foods" shared "food" with "food colouring", so
        // Coconut Ice showed up as a recipe for mayonnaise.
        #expect(!IngredientMatcher.matches("Best Foods Real Mayonnaise 400g", "Pink food colouring 3 drops"))
        #expect(!IngredientMatcher.matches("Best Foods Real Mayonnaise 400g", "Icing sugar 500 g"))
        #expect(!IngredientMatcher.matches("Best Foods Real Mayonnaise 400g", "Desiccated coconut 250 g"))
        #expect(!IngredientMatcher.matches("Best Foods Real Mayonnaise 400g", "Sweetened condensed milk 200 g"))
    }

    @Test("Mayonnaise never surfaces Coconut Ice, however the fridge item is named")
    func mayonnaiseDoesNotMatchCoconutIce() {
        // The exact ingredient lines of the bundled Coconut Ice recipe.
        let coconutIce = IngredientMatcher.recipeTokens([
            "Icing sugar 500 g",
            "Desiccated coconut 250 g",
            "Sweetened condensed milk 200 g",
            "Pink food colouring 3 drops"
        ])
        for name in ["Mayonnaise", "Mayo", "Best Foods Real Mayonnaise 400g", "Mayonnaise 250 g",
                     "Best Foods Mayonnaise 500 g", "Real Mayo (lite) 3 pack", "Hellmann's Real Mayonnaise"] {
            #expect(!IngredientMatcher.tokensMatch(IngredientMatcher.tokens(name), coconutIce), "\(name)")
        }
        // The things that *should* match still do.
        #expect(IngredientMatcher.tokensMatch(IngredientMatcher.tokens("Icing sugar"), coconutIce))
        #expect(IngredientMatcher.tokensMatch(IngredientMatcher.tokens("Desiccated coconut 1kg"), coconutIce))
        #expect(IngredientMatcher.tokensMatch(IngredientMatcher.tokens("Condensed milk"), coconutIce))
    }

    @Test("Pack sizes and quantities are not shared tokens")
    func amountsIgnored() {
        #expect(!IngredientMatcher.matches("Mayonnaise 250 g", "Desiccated coconut 250 g"))
        #expect(!IngredientMatcher.matches("Butter 500g", "Icing sugar 500 g"))
        #expect(IngredientMatcher.tokens("400g").isEmpty)
        #expect(IngredientMatcher.tokens("2 x 1.5L").isEmpty)
    }

    @Test("Colours, prep words and cuts don't make unrelated foods match")
    func descriptorsIgnored() {
        #expect(!IngredientMatcher.matches("Red wine", "Red onion"))
        #expect(!IngredientMatcher.matches("Frozen peas", "Frozen berries"))
        #expect(!IngredientMatcher.matches("Plain flour", "Plain yoghurt"))
        #expect(!IngredientMatcher.matches("Chicken breast", "Duck breast"))
        #expect(!IngredientMatcher.matches("Salmon fillets", "Chicken fillets"))
        #expect(!IngredientMatcher.matches("Gluten free bread", "Gluten free flour"))
    }

    @Test("Household items on a shopping list produce no food tokens")
    func householdItemsAreNotFood() {
        #expect(IngredientMatcher.tokens("Paper towels").isEmpty)
        #expect(IngredientMatcher.tokens("Toilet paper 12 pack").isEmpty)
        #expect(!IngredientMatcher.matches("Paper towels", "2 tbsp capers"))
    }

    // MARK: - Plurals

    @Test("Plurals match their singular without stem guessing")
    func plurals() {
        #expect(IngredientMatcher.singular("tomatoes") == "tomato")
        #expect(IngredientMatcher.singular("potatoes") == "potato")
        #expect(IngredientMatcher.singular("berries") == "berry")
        #expect(IngredientMatcher.singular("cheeses") == "cheese")
        #expect(IngredientMatcher.singular("peaches") == "peach")
        #expect(IngredientMatcher.singular("radishes") == "radish")
        #expect(IngredientMatcher.singular("chillies") == "chilli")
        #expect(IngredientMatcher.singular("leaves") == "leaf")
        #expect(IngredientMatcher.singular("eggs") == "egg")
        #expect(IngredientMatcher.singular("olives") == "olive")
        #expect(IngredientMatcher.singular("pies") == "pie")
        // Words that look plural but aren't.
        #expect(IngredientMatcher.singular("hummus") == "hummus")
        #expect(IngredientMatcher.singular("couscous") == "couscous")
        #expect(IngredientMatcher.singular("asparagus") == "asparagus")
        #expect(IngredientMatcher.singular("molasses") == "molasses")
        #expect(IngredientMatcher.singular("lemongrass") == "lemongrass")

        #expect(IngredientMatcher.matches("Tomatoes", "1 tomato"))
        #expect(IngredientMatcher.matches("Eggs", "2 eggs"))
        #expect(IngredientMatcher.matches("Cherry", "200g cherries"))
        #expect(IngredientMatcher.matches("Chilli", "2 red chillies, sliced"))
    }

    // MARK: - Exact tokens, not prefixes

    @Test("A food never matches a longer word or compound that merely starts with it")
    func noPrefixMatching() {
        #expect(!IngredientMatcher.matches("Butter", "butternut pumpkin"))
        #expect(!IngredientMatcher.matches("Corn", "2 tbsp cornflour"))
        #expect(!IngredientMatcher.matches("Ice", "1 cup rice"))
        #expect(!IngredientMatcher.matches("Cream", "ice cream"))
        #expect(!IngredientMatcher.matches("Milk", "400ml coconut milk"))
        #expect(!IngredientMatcher.matches("Chicken thighs", "500ml chicken stock"))
        #expect(!IngredientMatcher.matches("Peanuts", "2 tbsp peanut butter"))
        #expect(!IngredientMatcher.matches("Cherries", "250g cherry tomatoes"))
        #expect(!IngredientMatcher.matches("Potato chips", "100g chocolate chips"))
        #expect(!IngredientMatcher.matches("Sesame oil", "2 tbsp olive oil"))
        #expect(!IngredientMatcher.matches("Potatoes", "1 sweet potato"))
        #expect(!IngredientMatcher.matches("Cloves", "2 garlic cloves"))
        #expect(!IngredientMatcher.matches("Bread", "1 cup breadcrumbs"))
    }

    @Test("Compound foods still match themselves")
    func compoundsMatchThemselves() {
        #expect(IngredientMatcher.matches("Peanut butter", "2 tbsp peanut butter"))
        #expect(IngredientMatcher.matches("Chicken stock", "500ml chicken stock"))
        #expect(IngredientMatcher.matches("Coconut cream", "1 can coconut cream"))
        #expect(IngredientMatcher.matches("Icing sugar", "Icing sugar 500 g"))
        #expect(IngredientMatcher.matches("Spring onions", "2 green onions"))
        #expect(IngredientMatcher.matches("Food colouring", "Pink food colouring 3 drops"))
        #expect(IngredientMatcher.matches("Sour cream", "sour cream, to serve"))
    }

    // MARK: - Ice, iced, icing, rice

    @Test("Ice matches iced and icy, never rice, icing, ice cream or iced tea")
    func iceVersusRice() {
        #expect(IngredientMatcher.matches("Ice", "2 cups ice cubes"))
        #expect(IngredientMatcher.matches("Ice", "crushed ice"))
        #expect(IngredientMatcher.matches("Ice", "iced water"))
        #expect(IngredientMatcher.matches("Ice", "icy cold water"))
        #expect(IngredientMatcher.tokens("iced").contains("ice"))
        #expect(IngredientMatcher.derivedFood("icing") == nil)

        #expect(!IngredientMatcher.matches("Ice", "rice"))
        #expect(!IngredientMatcher.matches("Ice", "1 cup basmati rice"))
        #expect(!IngredientMatcher.matches("Ice", "chocolate icing"))
        #expect(!IngredientMatcher.matches("Ice", "vanilla ice cream"))
        #expect(!IngredientMatcher.matches("Ice", "iced tea"))
        #expect(!IngredientMatcher.matches("Ice", "riced cauliflower"))

        #expect(IngredientMatcher.matches("Rice", "1 cup basmati rice"))
        #expect(IngredientMatcher.matches("Rice", "arborio rice"))   // a kind of rice
        #expect(!IngredientMatcher.matches("Rice", "rice noodles"))
        #expect(!IngredientMatcher.matches("Rice", "rice flour"))
        #expect(!IngredientMatcher.matches("Rice", "iced water"))
    }

    // MARK: - Categories (regions) and families

    @Test("Known foods carry a category, and ice and rice live in different ones")
    func categories() {
        #expect(IngredientMatcher.category(for: "Ice") == .frozen)
        #expect(IngredientMatcher.category(for: "Iced water") == nil)   // frozen + beverage: mixed
        #expect(IngredientMatcher.category(for: "2 cups ice cubes") == .frozen)
        #expect(IngredientMatcher.category(for: "Rice") == .grain)
        #expect(IngredientMatcher.category(for: "Basmati rice 1kg") == .grain)
        #expect(IngredientMatcher.category(for: "Tasty cheese") == .dairy)
        #expect(IngredientMatcher.category(for: "Snapper fillets") == .seafood)
        #expect(IngredientMatcher.category(for: "Best Foods Mayonnaise") == .condiment)
        #expect(IngredientMatcher.category(for: "Kombucha starter kit") == .beverage)
        #expect(IngredientMatcher.category(for: "Mystery jar") == nil)
    }

    @Test("A generic name covers a specific one, but two specifics in a family never match")
    func families() {
        // Fish
        #expect(IngredientMatcher.matches("Snapper fillets", "500g white fish fillets"))
        #expect(IngredientMatcher.matches("Fish", "2 salmon fillets"))
        #expect(!IngredientMatcher.matches("Snapper", "2 salmon fillets"))
        // Mince
        #expect(IngredientMatcher.matches("Mince", "500g pork mince"))
        #expect(IngredientMatcher.matches("Beef mince", "500g mince"))
        #expect(!IngredientMatcher.matches("Beef mince", "500g chicken mince"))
        // Cheese
        #expect(IngredientMatcher.matches("Mozzarella", "1 cup grated cheese"))
        #expect(IngredientMatcher.matches("Cheese", "100g feta, crumbled"))
        #expect(!IngredientMatcher.matches("Mozzarella", "100g cheddar"))
        #expect(!IngredientMatcher.matches("Parmesan", "100g feta"))
        // Berries
        #expect(IngredientMatcher.matches("Strawberries", "2 cups mixed berries"))
        #expect(!IngredientMatcher.matches("Strawberries", "1 cup blueberries"))
        // Sugar: caster is a kind of sugar, icing sugar is not a swap
        #expect(IngredientMatcher.matches("Sugar", "1 cup caster sugar"))
        #expect(!IngredientMatcher.matches("Sugar", "1 cup icing sugar"))
        #expect(!IngredientMatcher.matches("Brown sugar", "1 cup caster sugar"))
        // Stock
        #expect(IngredientMatcher.matches("Stock", "500ml chicken stock"))
        #expect(!IngredientMatcher.matches("Beef stock", "500ml chicken stock"))
        // Ancestors are exposed for callers that want the family
        #expect(IngredientMatcher.ancestors(of: ["cheddar"]) == ["cheese"])
        #expect(IngredientMatcher.ancestors(of: ["rice"]).isEmpty)
    }

    @Test("Foods from different categories never match, whatever the pair")
    func categoriesNeverCross() {
        let lexicon = IngredientMatcher.lexicon
        let tokens = lexicon.keys.sorted()
        var crossMatches: [String] = []
        for i in tokens.indices {
            let a = tokens[i]
            let categoryA = lexicon[a]!.category
            for j in (i + 1)..<tokens.count {
                let b = tokens[j]
                guard lexicon[b]!.category != categoryA else { continue }
                if IngredientMatcher.tokensMatch([a], [b]) { crossMatches.append("\(a) ~ \(b)") }
            }
        }
        #expect(crossMatches.isEmpty, "\(crossMatches)")
    }

    @Test("Every synonym target and family parent is a known food in the same category")
    func lexiconIntegrity() {
        let lexicon = IngredientMatcher.lexicon
        for (token, entry) in lexicon {
            guard let parent = entry.parent else { continue }
            let parentEntry = lexicon[parent]
            #expect(parentEntry != nil, "\(token) → \(parent) is not in the lexicon")
            #expect(parentEntry?.category == entry.category, "\(token) → \(parent) crosses categories")
        }
        for (phrase, target) in IngredientMatcher.phraseSynonyms {
            #expect(lexicon[target] != nil, "phrase '\(phrase)' → \(target) is not in the lexicon")
            #expect(!IngredientMatcher.noiseWords.contains(target))
        }
        for (word, target) in IngredientMatcher.wordSynonyms {
            #expect(lexicon[target] != nil, "'\(word)' → \(target) is not in the lexicon")
            #expect(!IngredientMatcher.noiseWords.contains(word), "'\(word)' is both a synonym and noise")
        }
        for token in lexicon.keys {
            #expect(!IngredientMatcher.noiseWords.contains(token), "'\(token)' is both a food and noise")
        }
    }

    // MARK: - Spelling

    @Test("Typos in a typed fridge name are corrected to the nearest food")
    func typosCorrected() {
        #expect(IngredientMatcher.matches("Mayonaise", "2 tbsp mayonnaise"))
        #expect(IngredientMatcher.matches("Brocoli", "1 head broccoli"))
        #expect(IngredientMatcher.matches("Avacado", "1 avocado, sliced"))
        #expect(IngredientMatcher.matches("Corriander", "handful of coriander"))
        #expect(IngredientMatcher.matches("Zuchini", "2 zucchini"))
        #expect(IngredientMatcher.matches("Tumeric", "1 tsp turmeric"))
        #expect(IngredientMatcher.matches("Chilly", "1 red chilli"))
        #expect(IngredientMatcher.correctedSpelling("mayonaise") == "mayonnaise")
    }

    @Test("Spelling correction never touches short words, known words or names that already contain a food")
    func spellingIsConservative() {
        // Short words: ice can never become rice, beer can never become beef.
        #expect(IngredientMatcher.correctedSpelling("ice") == nil)
        #expect(!IngredientMatcher.matches("Beer", "500g beef"))
        #expect(!IngredientMatcher.matches("Pear", "1 cup peas"))
        // Known words are never "corrected" into a neighbour.
        #expect(!IngredientMatcher.matches("Lemon", "1 melon"))
        #expect(!IngredientMatcher.matches("Salmon", "100g salami"))
        // A brand word beside a real food is left alone.
        let bacon = IngredientMatcher.tokens("Huttons Streaky Bacon")
        #expect(bacon.contains("bacon"))
        #expect(!bacon.contains("mutton"))
        let bar = IngredientMatcher.tokens("Tasti Muesli Bar")
        #expect(bar.contains("muesli"))
        #expect(!bar.contains("cheddar"))
        // Ties and far-away words stay as typed.
        #expect(IngredientMatcher.correctedSpelling("flower") == nil)
        #expect(IngredientMatcher.tokens("Kombucha scoby").contains("scoby"))
    }

    // MARK: - Synonyms and families

    @Test("Regional names and interchangeable families match")
    func synonymsAndFamilies() {
        #expect(IngredientMatcher.matches("Capsicum", "1 red bell pepper"))
        #expect(IngredientMatcher.matches("Coriander", "handful of cilantro"))
        #expect(IngredientMatcher.matches("Courgette", "2 zucchini, diced"))
        #expect(IngredientMatcher.matches("Yogurt", "1 cup greek yoghurt"))
        #expect(IngredientMatcher.matches("Kumara", "1 sweet potato"))
        #expect(IngredientMatcher.matches("Cheddar", "1 cup grated tasty cheese"))
        #expect(IngredientMatcher.matches("Edam", "1 cup grated cheddar"))
        #expect(IngredientMatcher.matches("Spaghetti", "400g pasta"))
        #expect(IngredientMatcher.matches("Oil", "2 tbsp olive oil"))
        #expect(IngredientMatcher.matches("Beef mince", "500g ground beef"))
        #expect(IngredientMatcher.matches("Free range eggs 12 pack", "2 eggs"))
        #expect(IngredientMatcher.matches("Lemon", "juice of 1 lemon"))
        #expect(!IngredientMatcher.matches("Beef mince", "500g pork mince"))
        #expect(!IngredientMatcher.matches("Capsicum", "pepper"))
    }

    // MARK: - Recipe lines

    @Test("Recipe lines are stripped of amounts and prep notes before tokenising")
    func recipeLineTokens() {
        #expect(IngredientMatcher.recipeLineTokens("Icing sugar 500 g") == ["icingsugar"])
        #expect(IngredientMatcher.recipeLineTokens("500g butter, softened") == ["butter"])
        #expect(IngredientMatcher.recipeLineTokens("2 cloves garlic") == ["garlic"])
        #expect(IngredientMatcher.recipeLineTokens("Pink food colouring 3 drops") == ["foodcolouring"])
        #expect(IngredientMatcher.recipeLineTokens("1 large onion (finely diced)") == ["onion"])
        #expect(IngredientMatcher.recipeTokens(["2 eggs", "1 cup milk", "250g flour"]) == ["egg", "milk", "flour"])
    }

    // MARK: - Index

    @Test("Index finds the earliest matching name and all matches")
    func index() {
        let index = IngredientMatcher.Index(names: ["Milk", "Butter", "Free range eggs", "Salted butter"])
        #expect(!index.isEmpty)
        #expect(index.firstMatch(forRecipeLine: "50g butter") == 1)
        #expect(index.allMatches(IngredientMatcher.tokens("butter")) == [1, 3])
        #expect(index.firstMatch(forName: "2 eggs") == 2)
        #expect(index.firstMatch(forName: "Cheese") == nil)
        #expect(index.matches(IngredientMatcher.tokens("milk")))
        #expect(!index.matches(IngredientMatcher.tokens("coconut milk")))
        #expect(IngredientMatcher.Index(names: []).firstMatch(forName: "milk") == nil)

        let lines = ["2 eggs", "1 cup milk", "250g flour", "pinch of salt"]
        #expect(IngredientMatcher.coveredLineCount(lines, in: index) == 2)
    }

    @Test("Index honours families in both directions, but not between siblings")
    func indexFamilies() {
        let fridge = IngredientMatcher.Index(names: ["Snapper", "Beef mince", "Cheese", "Strawberries"])
        #expect(fridge.firstMatch(forRecipeLine: "500g white fish") == 0)      // generic recipe, specific fridge
        #expect(fridge.firstMatch(forRecipeLine: "500g mince") == 1)
        #expect(fridge.firstMatch(forRecipeLine: "100g mozzarella") == 2)      // specific recipe, generic fridge
        #expect(fridge.firstMatch(forRecipeLine: "1 cup mixed berries") == 3)
        #expect(fridge.firstMatch(forRecipeLine: "2 salmon fillets") == nil)   // sibling
        #expect(fridge.firstMatch(forRecipeLine: "500g pork mince") == nil)    // sibling
        #expect(fridge.allMatches(IngredientMatcher.tokens("fish")) == [0])
        #expect(IngredientMatcher.coveredLineCount(["white fish", "pork mince", "cheddar", "blueberries"], in: fridge) == 2)
    }

    // MARK: - Speed

    @Test("Fridge-by-recipe-usage over a large library stays fast")
    func largeLibraryIsFast() {
        let foods = ["chicken thighs", "garlic", "onion", "tomatoes", "coconut milk", "basmati rice",
                     "spring onions", "capsicum", "beef mince", "cheddar cheese", "eggs", "butter",
                     "plain flour", "olive oil", "soy sauce", "ginger", "lemon", "spinach", "mushrooms",
                     "pasta", "bacon", "cream", "potatoes", "carrots", "celery", "broccoli", "salmon",
                     "prawns", "tofu", "chickpeas"]
        // 300 recipes × 8 lines, every line a distinct string so the first
        // pass can't lean on the memo.
        let recipes: [[String]] = (0..<300).map { r in
            (0..<8).map { i in "\(100 + (r * 7 + i) % 400)g \(foods[(r + i * 3) % foods.count]), chopped #\(r)-\(i)" }
        }
        let fridge = (0..<60).map { "Best Foods \(foods[$0 % foods.count]) \(200 + $0)g" }

        func usageCounts() -> [Int] {
            fridge.map { item in
                let itemTokens = IngredientMatcher.tokens(item)
                return recipes.reduce(0) { $0 + (IngredientMatcher.tokensMatch(IngredientMatcher.recipeTokens($1), itemTokens) ? 1 : 0) }
            }
        }

        let clock = ContinuousClock()
        let cold = clock.measure { _ = usageCounts() }
        let warm = clock.measure { _ = usageCounts() }

        #expect(usageCounts().reduce(0, +) > 0)
        // Generous bounds: a simulator running the whole suite can be slow.
        #expect(cold < .seconds(3))
        #expect(warm < .milliseconds(500))
    }

    @Test("Spelling correction over many unknown names stays fast")
    func spellingIsFast() {
        let clock = ContinuousClock()
        let names = (0..<300).map { "Mystery item number \($0) xyzzy\($0 % 7)" }
        let elapsed = clock.measure {
            for name in names { _ = IngredientMatcher.tokens(name) }
        }
        #expect(elapsed < .seconds(2))
    }
}
