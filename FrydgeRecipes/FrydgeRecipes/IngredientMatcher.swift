//
//  IngredientMatcher.swift
//  FrydgeRecipes
//
//  Shared fridge ↔ recipe ingredient matching so Suggested recipes, ingredient
//  availability, cook-time deductions and the meal planner all agree on what
//  counts as a match.
//
//  Pipeline for one name ("Best Foods Real Mayonnaise 400g", "2 cloves garlic"):
//    1. lowercase, split on anything that isn't a letter or digit
//    2. drop amounts ("400g", "500", "2x")
//    3. singularise each word (tomatoes → tomato, berries → berry)
//    4. collapse multi-word foods to one token (spring onion → springonion,
//       peanut butter → peanutbutter, chicken stock → chickenstock) so a
//       compound never matches its parts
//    5. drop noise words (brands, packaging, colours, prep words, cuts)
//    6. map regional synonyms (capsicum/bell pepper, coriander/cilantro)
//    7. resolve derived words to the food they come from, but only when the
//       stem is a known food (iced/icy → ice, breaded → bread; "icing" and
//       "diced" are left alone)
//    8. if nothing in the name is a recognised food, correct obvious typos
//       against the lexicon (Mayonaise → mayonnaise, Brocoli → broccoli).
//       Names that already contain a food are never corrected, so a brand
//       word next to a real food ("Huttons Bacon") can't be rewritten.
//
//  Matching is exact on tokens — no prefix/stem guessing — so butter ≠
//  butternut, corn ≠ cornstarch, ice ≠ rice. On top of exact tokens the
//  lexicon adds *families*: a generic name on one side covers a specific one
//  on the other (recipe "cheese" ← fridge "mozzarella", recipe "pork mince" ←
//  fridge "mince"), but two specifics under the same family never match each
//  other (beef mince ≠ pork mince, cheddar ≠ mozzarella).
//
//  Every known token also has a `FoodCategory` (its region of the kitchen:
//  grain, dairy, frozen…). Families never cross a category, known words are
//  never fuzzed, and short words are never corrected, so a grain can never be
//  mistaken for something frozen: rice is never ice.
//
//  Performance: every tokenisation is memoised (names and recipe lines repeat
//  constantly across screens), and `Index` turns "does any fridge item match
//  this line?" into a handful of dictionary lookups instead of a scan.
//

import Foundation

/// Broad region of the kitchen a food belongs to. Used to keep spelling
/// correction, derived words and families from ever crossing between
/// unrelated foods.
enum FoodCategory: String, CaseIterable, Sendable {
    case vegetable, fruit, herb, spice, grain, bakery, legume, nut, seed
    case dairy, egg, meat, poultry, seafood, condiment, oil, baking, sweet
    case beverage, frozen, pantry
}

enum IngredientMatcher {

    /// Where a canonical token sits in the food taxonomy.
    struct FoodEntry: Equatable, Sendable {
        let category: FoodCategory
        /// Broader family this food can stand in for ("cheddar" → "cheese",
        /// "snapper" → "fish"). Always in the same category.
        let parent: String?
    }

    // MARK: - Public API

    /// Canonical tokens for a food/ingredient name. Memoised.
    static func tokens(_ s: String) -> Set<String> {
        if let hit = nameCache.get(s) { return hit }
        let computed = computeTokens(s)
        nameCache.set(s, computed)
        return computed
    }

    /// Canonical tokens for a raw recipe ingredient line ("500g butter, softened",
    /// "Icing sugar 500 g"): strips the amount and prep notes first. Memoised,
    /// which also avoids re-running the line parser's regex per call.
    static func recipeLineTokens(_ line: String) -> Set<String> {
        if let hit = lineCache.get(line) { return hit }
        let parsed = RecipeIngredientParser.parse(line)
        let cleaned = RecipeReadiness.cleanedName(parsed.name.isEmpty ? line : parsed.name)
        let computed = tokens(cleaned)
        lineCache.set(line, computed)
        return computed
    }

    /// Union of tokens across a recipe's ingredient lines. "Does this recipe
    /// use X?" is then one set intersection.
    static func recipeTokens(_ lines: [String]) -> Set<String> {
        // Memoised per ingredient list: sorting the fridge by recipe usage asks
        // for the same recipe's union once per fridge item.
        let key = lines.joined(separator: "\u{1F}")
        if let hit = recipeCache.get(key) { return hit }
        var union: Set<String> = []
        for line in lines { union.formUnion(recipeLineTokens(line)) }
        recipeCache.set(key, union)
        return union
    }

    /// True when two ingredient/food names share a canonical token, or one
    /// names the family the other belongs to.
    static func matches(_ a: String, _ b: String) -> Bool {
        tokensMatch(tokens(a), tokens(b))
    }

    /// Token-level form of `matches`.
    ///
    /// Exact token overlap always matches. Otherwise a token on one side may
    /// match a *family* the other side's tokens belong to (generic ↔ specific).
    /// Two different specifics under the same family do not match, because
    /// neither side's own tokens name the family.
    static func tokensMatch(_ ta: Set<String>, _ tb: Set<String>) -> Bool {
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        // Iterate the smaller set; each probe is O(1).
        if ta.count <= tb.count ? !ta.isDisjoint(with: tb) : !tb.isDisjoint(with: ta) { return true }
        // Probe each token's precomputed family chain directly rather than
        // building a union set: this runs for every (fridge item × recipe)
        // pair, and most pairs don't match.
        for token in ta {
            if let families = ancestorsByToken[token], !families.isDisjoint(with: tb) { return true }
        }
        for token in tb {
            if let families = ancestorsByToken[token], !families.isDisjoint(with: ta) { return true }
        }
        return false
    }

    /// Convenience: does any of `names` match `other`? Tokenises `other` once.
    static func anyMatches(_ names: [String], _ other: String) -> Bool {
        let target = tokens(other)
        guard !target.isEmpty else { return false }
        return names.contains { tokensMatch(tokens($0), target) }
    }

    /// Number of recipe lines covered by anything in `index`.
    static func coveredLineCount(_ lines: [String], in index: Index) -> Int {
        guard !index.isEmpty else { return 0 }
        return lines.reduce(0) { $0 + (index.matches(recipeLineTokens($1)) ? 1 : 0) }
    }

    /// Family tokens the given tokens can stand in for ("cheddar" → {"cheese"},
    /// "beefmince" → {"mince"}). Empty for generic or unknown tokens.
    static func ancestors(of tokens: Set<String>) -> Set<String> {
        var out: Set<String> = []
        for token in tokens {
            if let chain = ancestorsByToken[token] { out.formUnion(chain) }
        }
        return out
    }

    /// Category of a name when all of its recognised tokens agree; nil for
    /// unknown foods and for mixed names ("chicken and rice soup").
    static func category(for name: String) -> FoodCategory? {
        var found: FoodCategory? = nil
        for token in tokens(name) {
            guard let category = lexicon[token]?.category else { continue }
            if let existing = found, existing != category { return nil }
            found = category
        }
        return found
    }

    /// Lexicon entry for a canonical token, if it is a known food.
    static func entry(for token: String) -> FoodEntry? { lexicon[token] }

    // MARK: - Index

    /// Inverted index over a set of names (the fridge, the shopping list).
    /// Build once per evaluation, then each lookup costs one dictionary probe
    /// per token in the query instead of a pass over every name.
    struct Index {
        let names: [String]
        private let tokenSets: [Set<String>]
        /// Positions whose own tokens include the key.
        private let positionsByToken: [String: [Int]]
        /// Positions whose tokens belong to the family named by the key.
        private let positionsByFamily: [String: [Int]]

        init(names: [String]) {
            self.names = names
            let sets = names.map { IngredientMatcher.tokens($0) }
            self.tokenSets = sets
            var own: [String: [Int]] = [:]
            var family: [String: [Int]] = [:]
            for (position, set) in sets.enumerated() {
                for token in set { own[token, default: []].append(position) }
                for token in IngredientMatcher.ancestors(of: set) { family[token, default: []].append(position) }
            }
            self.positionsByToken = own
            self.positionsByFamily = family
        }

        var isEmpty: Bool { names.isEmpty }

        func tokens(at position: Int) -> Set<String> { tokenSets[position] }

        /// Calls `body` with every position list the query can hit: exact
        /// tokens, indexed specifics whose family the query names, and indexed
        /// generics that the query's own tokens specialise.
        private func probe(_ query: Set<String>, _ body: ([Int]) -> Void) {
            for token in query {
                if let positions = positionsByToken[token] { body(positions) }
                if let positions = positionsByFamily[token] { body(positions) }
                // Indexed generics that this specific token belongs to. Walks
                // the precomputed chain directly rather than building a set.
                if let families = IngredientMatcher.ancestorsByToken[token] {
                    for family in families {
                        if let positions = positionsByToken[family] { body(positions) }
                    }
                }
            }
        }

        /// Position of the earliest name that matches, preserving the "first
        /// item wins" behaviour of a linear scan.
        func firstMatch(_ query: Set<String>) -> Int? {
            var best: Int? = nil
            probe(query) { positions in
                // Positions are appended in order, so `.first` is the earliest.
                guard let earliest = positions.first else { return }
                if best == nil || earliest < best! { best = earliest }
            }
            return best
        }

        func matches(_ query: Set<String>) -> Bool {
            if query.contains(where: { positionsByToken[$0] != nil || positionsByFamily[$0] != nil }) { return true }
            return IngredientMatcher.ancestors(of: query).contains { positionsByToken[$0] != nil }
        }

        /// Every matching position, ascending.
        func allMatches(_ query: Set<String>) -> [Int] {
            var found: Set<Int> = []
            probe(query) { found.formUnion($0) }
            return found.sorted()
        }

        func firstMatch(forName name: String) -> Int? {
            firstMatch(IngredientMatcher.tokens(name))
        }

        func firstMatch(forRecipeLine line: String) -> Int? {
            firstMatch(IngredientMatcher.recipeLineTokens(line))
        }
    }

    // MARK: - Tokenisation

    private static let maxPhraseWords = 3

    private static func computeTokens(_ s: String) -> Set<String> {
        let words = baseWords(s)
        guard !words.isEmpty else { return [] }
        let tokens = assemble(words)
        if tokens.contains(where: { lexicon[$0] != nil }) { return tokens }

        // Nothing recognisable — most likely a typed name with a typo
        // ("Mayonaise", "Brocoli"). Correct the unknown words against the
        // lexicon and try once more. Names that already contain a known food
        // never reach this point, so brand words beside real foods stay as is.
        var changed = false
        let corrected = words.map { word -> String in
            guard !isKnownWord(word), let fix = correctedSpelling(word) else { return word }
            changed = true
            return fix
        }
        guard changed else { return tokens }
        let retry = assemble(corrected)
        return retry.contains(where: { lexicon[$0] != nil }) ? retry : tokens
    }

    /// Steps 1–3: lowercase words, minus amounts, singularised.
    private static func baseWords(_ s: String) -> [String] {
        var words: [String] = []
        words.reserveCapacity(6)
        for part in s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            guard let first = part.first, !first.isNumber else { continue }
            words.append(singular(String(part)))
        }
        return words
    }

    /// Steps 4–7: longest-phrase-first merge, then noise filter, synonyms and
    /// derived words.
    private static func assemble(_ words: [String]) -> Set<String> {
        var out: Set<String> = []
        var i = 0
        while i < words.count {
            var merged = false
            var length = min(maxPhraseWords, words.count - i)
            while length >= 2 {
                let key = words[i..<(i + length)].joined(separator: " ")
                if let canonical = phraseSynonyms[key] {
                    out.insert(canonical)
                    i += length
                    merged = true
                    break
                }
                length -= 1
            }
            if merged { continue }

            let word = words[i]
            i += 1
            if noiseWords.contains(word) { continue }
            if let mapped = wordSynonyms[word] { out.insert(mapped); continue }
            if lexicon[word] != nil { out.insert(word); continue }
            if let derived = derivedFood(word) { out.insert(derived); continue }
            if word.count >= 3 { out.insert(word) }
        }
        return out
    }

    /// Cheap English singulariser tuned for food words. Only ever removes a
    /// plural ending, so it can't invent a stem that collides with another food.
    static func singular(_ w: String) -> String {
        if let irregular = irregularSingulars[w] { return irregular }
        guard w.count > 3, w.hasSuffix("s") else { return w }
        if w.hasSuffix("ss") || w.hasSuffix("us") || w.hasSuffix("is") { return w }   // cress, hummus, couscous
        if w.hasSuffix("ies"), w.count > 4 { return String(w.dropLast(3)) + "y" }   // berries → berry
        if w.hasSuffix("oes") { return String(w.dropLast(2)) }                         // tomatoes → tomato
        if w.hasSuffix("ches") || w.hasSuffix("shes") || w.hasSuffix("xes") || w.hasSuffix("zes") {
            return String(w.dropLast(2))                                                 // peaches → peach
        }
        return String(w.dropLast())                                                      // eggs → egg, cheeses → cheese
    }

    /// The food a derived word comes from, when the stem is a known food:
    /// iced/icy → ice, breaded → bread, cheesy → cheese. Returns nil for
    /// words whose stem isn't a food ("diced", "icing", "tasty"), so the
    /// derivation can never invent a match. "-ing" is deliberately not
    /// handled: icing is not ice.
    static func derivedFood(_ w: String) -> String? {
        if let special = derivedSynonyms[w] { return special }
        guard w.count >= 3 else { return nil }
        let stems: [String]
        if w.hasSuffix("ed") {
            let stem = String(w.dropLast(2))
            stems = [stem, stem + "e"]            // breaded → bread, iced → ice
        } else if w.hasSuffix("y") {
            let stem = String(w.dropLast())
            stems = [stem, stem + "e"]            // salty → salt, icy → ice
        } else {
            return nil
        }
        for stem in stems where stem.count >= 3 {
            if lexicon[stem] != nil { return stem }
        }
        return nil
    }

    /// Words the pipeline already understands, which spelling correction must
    /// never touch.
    private static func isKnownWord(_ w: String) -> Bool {
        noiseWords.contains(w)
            || wordSynonyms[w] != nil
            || lexicon[w] != nil
            || phraseWords.contains(w)
            || derivedFood(w) != nil
    }

    // MARK: - Spelling correction

    /// Nearest known food word within a small edit distance, or nil when the
    /// word is too short to correct safely, nothing is close enough, or two
    /// candidates tie. Only called for words that are not already known.
    static func correctedSpelling(_ w: String) -> String? {
        guard w.count >= 5, w.allSatisfy(\.isLetter) else { return nil }
        if let hit = spellingCache.get(w) { return hit }
        let maxDistance = w.count >= 8 ? 2 : 1
        var best: String? = nil
        var bestDistance = maxDistance + 1
        var tie = false
        for candidate in correctionCandidates where abs(candidate.count - w.count) <= maxDistance {
            let distance = editDistance(w, candidate, limit: maxDistance)
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
                tie = false
            } else if distance == bestDistance, distance <= maxDistance {
                tie = true
            }
        }
        let result = (bestDistance <= maxDistance && !tie) ? best : nil
        spellingCache.set(w, result)
        return result
    }

    /// Levenshtein distance with early exit once every cell in a row exceeds
    /// `limit` (returns `limit + 1` in that case).
    private static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a.utf8), y = Array(b.utf8)
        if abs(x.count - y.count) > limit { return limit + 1 }
        guard !x.isEmpty, !y.isEmpty else { return max(x.count, y.count) }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            var rowMin = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if current[j] < rowMin { rowMin = current[j] }
            }
            if rowMin > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    /// Everything a typo may be corrected to: lexicon tokens, synonym keys and
    /// the words that make up phrases. Noise words and very short words are
    /// excluded so a correction can only ever land on a food.
    private static let correctionCandidates: [String] = {
        var set = Set(lexicon.keys)
        set.formUnion(wordSynonyms.keys)
        set.formUnion(phraseWords)
        set.subtract(noiseWords)
        return set.filter { $0.count >= 4 }.sorted()
    }()

    // MARK: - Caches

    private static let nameCache = MemoCache<Set<String>>()
    private static let lineCache = MemoCache<Set<String>>()
    private static let recipeCache = MemoCache<Set<String>>(limit: 2_000)
    private static let spellingCache = MemoCache<String?>(limit: 2_000)

    /// Small lock-protected memo. Bounded so a long session can't grow it
    /// without limit; clearing is cheap because everything recomputes lazily.
    private final class MemoCache<Value>: @unchecked Sendable {
        private var storage: [String: Value] = [:]
        private let lock = NSLock()
        private let limit: Int

        init(limit: Int = 6_000) { self.limit = limit }

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

    // MARK: - Lexicon

    /// Every canonical food token with its category and (optional) family.
    /// Interchangeable foods share one token (via `wordSynonyms` /
    /// `phraseSynonyms`); foods that are a *kind of* something broader point at
    /// it with `parent`. Parents always share the child's category.
    static let lexicon: [String: FoodEntry] = {
        var map: [String: FoodEntry] = [:]
        func add(_ category: FoodCategory, parent: String? = nil, _ words: String) {
            for word in words.split(separator: " ") {
                map[String(word)] = FoodEntry(category: category, parent: parent)
            }
        }

        add(.vegetable, """
            onion springonion shallot leek garlic capsicum chilli tomato sundriedtomato potato kumara carrot \
            celery celeriac broccoli broccolini cauliflower cabbage spinach kale silverbeet lettuce arugula \
            bokchoy watercress cress zucchini eggplant cucumber gherkin pumpkin butternut corn pea snowpea \
            greenbean beansprout sprout brusselssprout mushroom asparagus beetroot radish turnip parsnip swede \
            fennel avocado artichoke okra olive yam taro cassava seaweed nori
            """)
        add(.vegetable, parent: "chilli", "jalapeno habanero")
        add(.vegetable, parent: "corn", "creamedcorn")
        add(.vegetable, parent: "mushroom", "shiitake portobello enoki")

        add(.fruit, """
            apple pear banana orange mandarin lemon lime grapefruit grape berry cherry peach nectarine plum \
            apricot mango pineapple kiwifruit melon watermelon rockmelon honeydew papaya passionfruit fig date \
            raisin sultana currant prune coconut feijoa tamarillo persimmon pomegranate lychee guava rhubarb \
            plantain quince blackcurrant
            """)
        add(.fruit, parent: "berry", "strawberry blueberry raspberry blackberry boysenberry cranberry gooseberry")
        add(.fruit, parent: "coconut", "desiccatedcoconut")

        add(.herb, "parsley cilantro basil mint oregano thyme rosemary sage dill chive tarragon bayleaf curryleaf kaffirlime lemongrass marjoram mixedherb")

        add(.spice, """
            pepper peppercorn paprika cumin turmeric cinnamon nutmeg clove cardamom ginger chilliflake \
            chillipowder currypowder garlicpowder onionpowder saffron allspice mustardseed mustardpowder \
            fennelseed corianderseed staranise sumac garammasala fivespice cayenne mixedspice
            """)

        add(.grain, """
            rice quinoa couscous barley oat bulgur polenta semolina freekeh millet buckwheat pasta noodle \
            ricenoodle muesli granola cereal cornflake popcorn cornchip wheatgerm
            """)
        add(.grain, parent: "rice", "arborio sushirice wildrice")

        add(.bakery, """
            bread breadcrumb pita naan tortilla bagel croissant bun crumpet pizzabase pastry biscuit cracker \
            crouton ricepaper springrollwrapper wontonwrapper dumplingwrapper muffin scone pancake waffle cake
            """)
        add(.bakery, parent: "pastry", "puffpastry shortcrustpastry filo")

        add(.legume, "chickpea lentil bean bakedbean refriedbean broadbean edamame tofu tempeh splitpea")
        add(.legume, parent: "bean", "kidneybean blackbean cannellinibean butterbean borlottibean pintobean")

        add(.nut, "nut nutbutter chestnut")
        add(.nut, parent: "nut", "almond cashew peanut walnut pecan pistachio hazelnut macadamia brazilnut pinenut")
        add(.nut, parent: "nutbutter", "peanutbutter almondbutter cashewbutter")

        add(.seed, "sesame chia flaxseed pepita sunflowerseed poppyseed hempseed")

        add(.dairy, """
            milk cream sourcream creamcheese cremefraiche yoghurt butter ghee cheese cottagecheese ricotta \
            mascarpone condensedmilk evaporatedmilk buttermilk custard milkpowder whey
            """)
        add(.dairy, parent: "cheese", "cheddar mozzarella swisscheese gouda parmesan feta goatcheese bluecheese halloumi brie camembert paneer havarti")

        add(.egg, "egg")

        add(.meat, "beef mince pork lamb veal venison mutton bacon ham sausage chorizo salami prosciutto pancetta pepperoni cornedbeef hotdog")
        add(.meat, parent: "mince", "beefmince porkmince chickenmince lambmince turkeymince")

        add(.poultry, "chicken turkey duck quail chickennugget")

        add(.seafood, "fish seafood surimi fishfinger")
        add(.seafood, parent: "fish", """
            salmon tuna snapper cod hoki tarakihi gurnard kahawai trevally kingfish hake haddock basa tilapia \
            barramundi swordfish mackerel sardine anchovy trout bass flounder monkfish
            """)
        add(.seafood, parent: "seafood", "shrimp mussel oyster squid scallop crab lobster crayfish clam pipi cockle octopus")

        add(.condiment, """
            mayonnaise aioli mustard tomatosauce bbqsauce hotsauce soysauce fishsauce oystersauce hoisinsauce \
            worcestershire chillisauce sweetchillisauce currypaste miso tahini hummus pesto relish chutney \
            pickle vinegar balsamic tomatopaste passata salsa gravy teriyaki caper vegemite marmite mirin \
            ricewine tzatziki
            """)
        add(.condiment, parent: "vinegar", "redwinevinegar whitewinevinegar cidervinegar ricevinegar maltvinegar")
        add(.condiment, parent: "hotsauce", "sriracha")

        add(.oil, "oil sesameoil truffleoil chillioil coconutoil lard")

        add(.baking, """
            flour riceflour coconutflour almondmeal cornstarch bakingsoda bakingpowder yeast cocoa vanilla \
            gelatine icingsugar sugar goldensyrup maplesyrup honey treacle molasses chocolate foodcolouring \
            custardpowder
            """)
        add(.baking, parent: "flour", "selfraisingflour wholemealflour")
        add(.baking, parent: "sugar", "castersugar brownsugar rawsugar palmsugar coconutsugar")

        add(.sweet, "jam marmalade jelly caramel toffee fudge marshmallow lolly nutella")

        add(.beverage, "water tea coffee icedtea icedcoffee beer wine redwine whitewine cider lemonade cola kombucha")

        add(.frozen, "ice icecream iceblock")

        add(.pantry, """
            salt stock stockcube stockpowder coconutmilk coconutcream coconutwater coconutyoghurt almondmilk \
            oatmilk soymilk ricemilk springroll dumpling potatochip
            """)
        add(.pantry, parent: "stock", "chickenstock beefstock vegetablestock fishstock")

        return map
    }()

    /// Full family chain for every token that has a parent, precomputed once.
    private static let ancestorsByToken: [String: Set<String>] = {
        var out: [String: Set<String>] = [:]
        for (token, entry) in lexicon {
            var chain: Set<String> = []
            var next = entry.parent
            var hops = 0
            while let parent = next, hops < 8 {
                chain.insert(parent)
                next = lexicon[parent]?.parent
                hops += 1
            }
            if !chain.isEmpty { out[token] = chain }
        }
        return out
    }()

    // MARK: - Vocabulary

    /// Plurals the suffix rules get wrong.
    private static let irregularSingulars: [String: String] = [
        "chillies": "chilli", "chilies": "chilli", "chiles": "chile",
        "leaves": "leaf", "loaves": "loaf", "halves": "half", "knives": "knife",
        "cookies": "cookie", "brownies": "brownie", "quiches": "quiche", "brioches": "brioche",
        "mangos": "mango", "anchovies": "anchovy", "feet": "foot", "children": "child",
        // Mass nouns that end in "es" but aren't plural.
        "molasses": "molasses"
    ]

    /// Derived words whose stem the suffix rules can't recover.
    private static let derivedSynonyms: [String: String] = [
        "garlicky": "garlic", "chocolatey": "chocolate", "chocolaty": "chocolate"
    ]

    /// Multi-word foods collapsed to a single canonical token. Keys are
    /// lowercase, singularised words separated by one space. Longer phrases
    /// are matched before shorter ones. Every value is a lexicon token.
    static let phraseSynonyms: [String: String] = [
        // Alliums
        "spring onion": "springonion", "green onion": "springonion", "salad onion": "springonion",
        "red onion": "onion", "brown onion": "onion", "garlic clove": "garlic", "clove garlic": "garlic",
        "garlic powder": "garlicpowder", "onion powder": "onionpowder",
        // Capsicum / chilli
        "bell pepper": "capsicum", "red pepper": "capsicum", "green pepper": "capsicum",
        "yellow pepper": "capsicum", "sweet pepper": "capsicum",
        "chilli flake": "chilliflake", "chili flake": "chilliflake", "red pepper flake": "chilliflake",
        "chilli powder": "chillipowder", "chili powder": "chillipowder",
        "chilli sauce": "chillisauce", "chili sauce": "chillisauce",
        "sweet chilli sauce": "sweetchillisauce", "sweet chili sauce": "sweetchillisauce", "sweet chilli": "sweetchillisauce",
        "chilli oil": "chillioil", "chili oil": "chillioil",
        // Mince (specific minces are a kind of mince, not of each other)
        "ground beef": "beefmince", "beef mince": "beefmince", "minced beef": "beefmince", "mince beef": "beefmince",
        "pork mince": "porkmince", "ground pork": "porkmince", "minced pork": "porkmince",
        "chicken mince": "chickenmince", "ground chicken": "chickenmince", "minced chicken": "chickenmince",
        "lamb mince": "lambmince", "ground lamb": "lambmince", "minced lamb": "lambmince",
        "turkey mince": "turkeymince", "ground turkey": "turkeymince",
        "corned beef": "cornedbeef",
        // Beef cuts → beef (steak alone defaults to beef below)
        "scotch fillet": "beef", "eye fillet": "beef", "blade steak": "beef", "chuck steak": "beef",
        "rump steak": "beef", "sirloin steak": "beef", "gravy beef": "beef", "beef steak": "beef",
        "tuna steak": "tuna", "salmon steak": "salmon", "fish steak": "fish", "swordfish steak": "swordfish",
        "white fish": "fish", "fish finger": "fishfinger", "chicken nugget": "chickennugget",
        // Stock
        "chicken stock": "chickenstock", "chicken broth": "chickenstock",
        "beef stock": "beefstock", "beef broth": "beefstock",
        "vegetable stock": "vegetablestock", "vegetable broth": "vegetablestock", "veggie stock": "vegetablestock",
        "fish stock": "fishstock", "stock cube": "stockcube", "stock powder": "stockpowder",
        // Tomato
        "tomato paste": "tomatopaste", "tomato puree": "tomatopaste", "tomato sauce": "tomatosauce",
        "tomato ketchup": "tomatosauce",
        "cherry tomato": "tomato", "grape tomato": "tomato", "roma tomato": "tomato",
        "sun dried tomato": "sundriedtomato", "sundried tomato": "sundriedtomato", "passata": "passata",
        // Coconut
        "coconut cream": "coconutcream", "coconut milk": "coconutmilk", "coconut oil": "coconutoil",
        "coconut sugar": "coconutsugar", "coconut flour": "coconutflour", "coconut water": "coconutwater",
        "coconut yoghurt": "coconutyoghurt", "coconut yogurt": "coconutyoghurt",
        "desiccated coconut": "desiccatedcoconut", "shredded coconut": "desiccatedcoconut",
        "coconut flake": "desiccatedcoconut", "coconut thread": "desiccatedcoconut",
        // Dairy
        "sour cream": "sourcream", "cream cheese": "creamcheese", "ice cream": "icecream",
        "double cream": "cream", "heavy cream": "cream", "thickened cream": "cream",
        "whipping cream": "cream", "single cream": "cream", "pouring cream": "cream",
        "creme fraiche": "cremefraiche",
        "condensed milk": "condensedmilk", "evaporated milk": "evaporatedmilk",
        "almond milk": "almondmilk", "oat milk": "oatmilk", "soy milk": "soymilk", "rice milk": "ricemilk",
        "full cream milk": "milk", "trim milk": "milk", "skim milk": "milk", "lite milk": "milk",
        "cheddar cheese": "cheddar", "tasty cheese": "cheddar", "edam cheese": "cheddar", "colby cheese": "cheddar",
        "mild cheese": "cheddar", "mozzarella cheese": "mozzarella", "swiss cheese": "swisscheese",
        "gouda cheese": "gouda", "parmesan cheese": "parmesan", "feta cheese": "feta", "goat cheese": "goatcheese",
        "blue cheese": "bluecheese", "cottage cheese": "cottagecheese", "ricotta cheese": "ricotta",
        "halloumi cheese": "halloumi",
        "greek yoghurt": "yoghurt", "greek yogurt": "yoghurt", "natural yoghurt": "yoghurt",
        "egg white": "egg", "egg yolk": "egg",
        // Nut butters and spreads
        "peanut butter": "peanutbutter", "almond butter": "almondbutter", "cashew butter": "cashewbutter",
        "butter bean": "butterbean", "nut butter": "nutbutter",
        // Sauces / condiments
        "soy sauce": "soysauce", "fish sauce": "fishsauce", "oyster sauce": "oystersauce",
        "hoisin sauce": "hoisinsauce", "worcestershire sauce": "worcestershire", "bbq sauce": "bbqsauce",
        "barbecue sauce": "bbqsauce", "hot sauce": "hotsauce",
        "dijon mustard": "mustard", "wholegrain mustard": "mustard", "english mustard": "mustard",
        "mustard seed": "mustardseed", "mustard powder": "mustardpowder",
        "curry paste": "currypaste", "curry powder": "currypowder", "curry leaf": "curryleaf",
        "miso paste": "miso",
        // Oils (neutral + olive are interchangeable; flavour oils are not)
        "olive oil": "oil", "vegetable oil": "oil", "canola oil": "oil", "sunflower oil": "oil",
        "rice bran oil": "oil", "peanut oil": "oil", "avocado oil": "oil", "grapeseed oil": "oil",
        "cooking oil": "oil", "cooking spray": "oil", "sesame oil": "sesameoil", "truffle oil": "truffleoil",
        // Vinegars
        "white vinegar": "vinegar", "distilled vinegar": "vinegar",
        "red wine vinegar": "redwinevinegar", "white wine vinegar": "whitewinevinegar",
        "apple cider vinegar": "cidervinegar", "cider vinegar": "cidervinegar",
        "balsamic vinegar": "balsamic", "rice vinegar": "ricevinegar", "rice wine vinegar": "ricevinegar",
        "malt vinegar": "maltvinegar",
        // Wine and drinks
        "red wine": "redwine", "white wine": "whitewine", "rice wine": "ricewine", "cooking wine": "whitewine",
        "apple cider": "cider", "iced tea": "icedtea", "iced coffee": "icedcoffee",
        "soda water": "water", "sparkling water": "water", "mineral water": "water",
        // Sugars
        "icing sugar": "icingsugar", "powdered sugar": "icingsugar", "confectioner sugar": "icingsugar",
        "caster sugar": "castersugar", "superfine sugar": "castersugar",
        "brown sugar": "brownsugar", "raw sugar": "rawsugar", "demerara sugar": "rawsugar",
        "palm sugar": "palmsugar", "white sugar": "sugar", "granulated sugar": "sugar",
        "golden syrup": "goldensyrup", "maple syrup": "maplesyrup",
        // Flours and raising agents
        "plain flour": "flour", "all purpose flour": "flour", "ap flour": "flour", "bread flour": "flour",
        "self raising flour": "selfraisingflour", "self rising flour": "selfraisingflour",
        "selfraising flour": "selfraisingflour", "wholemeal flour": "wholemealflour",
        "whole wheat flour": "wholemealflour", "rice flour": "riceflour", "corn flour": "cornstarch",
        "corn starch": "cornstarch", "almond flour": "almondmeal", "almond meal": "almondmeal",
        "ground almond": "almondmeal", "baking soda": "bakingsoda", "bicarbonate of soda": "bakingsoda",
        "bicarb soda": "bakingsoda", "baking powder": "bakingpowder", "cocoa powder": "cocoa",
        "vanilla extract": "vanilla", "vanilla essence": "vanilla", "vanilla bean": "vanilla",
        "vanilla paste": "vanilla", "custard powder": "custardpowder",
        // Legumes
        "chick pea": "chickpea", "green bean": "greenbean", "black bean": "blackbean",
        "kidney bean": "kidneybean", "cannellini bean": "cannellinibean", "baked bean": "bakedbean",
        "broad bean": "broadbean", "edamame bean": "edamame", "refried bean": "refriedbean",
        "borlotti bean": "borlottibean", "pinto bean": "pintobean", "split pea": "splitpea",
        "red lentil": "lentil", "brown lentil": "lentil", "green lentil": "lentil",
        // Grains, pasta, bread
        "egg noodle": "noodle", "rice noodle": "ricenoodle", "lasagne sheet": "pasta", "lasagna sheet": "pasta",
        "bread crumb": "breadcrumb", "panko crumb": "breadcrumb", "rice paper": "ricepaper",
        "puff pastry": "puffpastry", "shortcrust pastry": "shortcrustpastry", "filo pastry": "filo",
        "phyllo pastry": "filo", "pizza base": "pizzabase", "pita bread": "pita", "naan bread": "naan",
        "tortilla wrap": "tortilla", "rolled oat": "oat", "porridge oat": "oat", "quick oat": "oat",
        "basmati rice": "rice", "jasmine rice": "rice", "long grain rice": "rice", "brown rice": "rice",
        "white rice": "rice", "arborio rice": "arborio", "risotto rice": "arborio", "sushi rice": "sushirice",
        "wild rice": "wildrice", "corn flake": "cornflake", "rice cracker": "cracker",
        "corn chip": "cornchip", "potato chip": "potatochip", "potato crisp": "potatochip",
        "wonton wrapper": "wontonwrapper", "dumpling wrapper": "dumplingwrapper",
        // Veg
        "sweet potato": "kumara", "sweet corn": "corn", "corn kernel": "corn", "corn cob": "corn",
        "creamed corn": "creamedcorn",
        "baby spinach": "spinach", "bok choy": "bokchoy", "pak choi": "bokchoy", "pak choy": "bokchoy",
        "snow pea": "snowpea", "sugar snap pea": "snowpea", "sugar snap": "snowpea",
        "spring roll wrapper": "springrollwrapper", "bean sprout": "beansprout",
        "brussel sprout": "brusselssprout", "brussels sprout": "brusselssprout",
        "bay leaf": "bayleaf", "kaffir lime leaf": "kaffirlime", "lime leaf": "kaffirlime",
        "flat leaf parsley": "parsley", "italian parsley": "parsley", "curly parsley": "parsley",
        "lemon grass": "lemongrass", "butternut squash": "butternut", "butternut pumpkin": "butternut",
        "iceberg lettuce": "lettuce", "cos lettuce": "lettuce", "romaine lettuce": "lettuce",
        "button mushroom": "mushroom", "oyster mushroom": "mushroom", "portobello mushroom": "mushroom",
        "swiss brown mushroom": "mushroom", "field mushroom": "mushroom",
        // Fruit
        "granny smith": "apple", "pink lady": "apple", "royal gala": "apple",
        // Seeds and nuts
        "pumpkin seed": "pepita", "sunflower seed": "sunflowerseed", "chia seed": "chia",
        "sesame seed": "sesame", "poppy seed": "poppyseed", "fennel seed": "fennelseed",
        "coriander seed": "corianderseed", "cumin seed": "cumin", "flax seed": "flaxseed",
        "pine nut": "pinenut", "mixed nut": "nut",
        // Herbs and spices
        "mixed herb": "mixedherb", "mixed spice": "mixedspice", "garam masala": "garammasala",
        "star anise": "staranise", "five spice": "fivespice",
        // Chocolate
        "chocolate chip": "chocolate", "milk chocolate": "chocolate", "cooking chocolate": "chocolate",
        "cocoa nib": "cocoa",
        // Misc
        "food colouring": "foodcolouring", "food coloring": "foodcolouring",
        "sea salt": "salt", "rock salt": "salt", "table salt": "salt", "flaky salt": "salt",
        "black pepper": "pepper", "white pepper": "pepper", "cracked pepper": "pepper",
        "hot water": "water", "cold water": "water", "warm water": "water", "boiling water": "water",
        "ice cube": "ice", "ice block": "iceblock", "icy pole": "iceblock", "ice lolly": "iceblock",
        "lemon juice": "lemon", "lime juice": "lime", "lemon zest": "lemon", "lime zest": "lime",
        "orange juice": "orange", "orange zest": "orange", "apple juice": "apple",
        "tinned tuna": "tuna", "canned tuna": "tuna", "smoked salmon": "salmon",
        "ham hock": "ham", "streaky bacon": "bacon", "middle bacon": "bacon", "bacon rasher": "bacon",
        "chorizo sausage": "chorizo", "pork sausage": "sausage", "beef sausage": "sausage",
        "hot dog": "hotdog", "spring roll": "springroll"
    ]

    /// Every word that appears in a phrase key, so spelling correction leaves
    /// phrase parts alone ("iced" in "iced tea", "condensed" in "condensed milk").
    private static let phraseWords: Set<String> = {
        var words: Set<String> = []
        for key in phraseSynonyms.keys {
            for word in key.split(separator: " ") { words.insert(String(word)) }
        }
        return words
    }()

    /// Single-word regional synonyms and interchangeable foods mapped onto one
    /// canonical token. Keys are singular; every value is a lexicon token.
    /// Foods that are a *kind of* something broader (cheddar, snapper) are not
    /// here — they live in the lexicon with a parent instead.
    static let wordSynonyms: [String: String] = [
        "scallion": "springonion", "eschallot": "shallot",
        "coriander": "cilantro",
        "aubergine": "eggplant",
        "courgette": "zucchini",
        "rocket": "arugula",
        "prawn": "shrimp",
        "minced": "mince",
        "cornflour": "cornstarch",
        "garbanzo": "chickpea",
        "yogurt": "yoghurt",
        "chili": "chilli", "chile": "chilli",
        "beet": "beetroot",
        "chard": "silverbeet",
        "cantaloupe": "rockmelon",
        "pawpaw": "papaya",
        "tangerine": "mandarin",
        "kiwi": "kiwifruit",
        "ketchup": "tomatosauce",
        "broth": "stock",
        "cookie": "biscuit",
        "fetta": "feta",
        "haloumi": "halloumi",
        "parmigiano": "parmesan", "pecorino": "parmesan", "grana": "parmesan",
        "edam": "cheddar", "colby": "cheddar",
        "emmental": "swisscheese", "gruyere": "swisscheese",
        "cacao": "cocoa",
        "sweetcorn": "corn",
        "steak": "beef", "rump": "beef", "sirloin": "beef", "porterhouse": "beef", "ribeye": "beef",
        "spaghetti": "pasta", "penne": "pasta", "fettuccine": "pasta", "fettucine": "pasta",
        "linguine": "pasta", "macaroni": "pasta", "fusilli": "pasta", "rigatoni": "pasta",
        "tagliatelle": "pasta", "farfalle": "pasta", "orecchiette": "pasta", "pappardelle": "pasta",
        "lasagne": "pasta", "lasagna": "pasta",
        "udon": "noodle", "soba": "noodle", "ramen": "noodle",
        "panko": "breadcrumb",
        "linseed": "flaxseed",
        "bicarb": "bakingsoda",
        "mayo": "mayonnaise",
        "tabasco": "hotsauce",
        "calamari": "squid",
        "iceberg": "lettuce", "cos": "lettuce", "romaine": "lettuce",
        "popsicle": "iceblock",
        "crisp": "potatochip"
    ]

    /// Words that say nothing about *what* the food is, so sharing one must
    /// never count as a match. Fridge items often carry a product title
    /// ("Best Foods Real Mayonnaise 400g") and recipe lines carry amounts,
    /// prep notes and descriptors ("Pink food colouring 3 drops", "2 large
    /// skinless chicken breasts, diced"). Singular forms (the pipeline has
    /// already singularised). Also used to keep spelling correction away from
    /// words that are never foods.
    static let noiseWords: Set<String> = [
        // Brand / marketing
        "best", "food", "real", "lite", "light", "free", "fresh", "original", "classic",
        "premium", "select", "selection", "value", "essential", "choice", "finest", "gold",
        "golden", "deluxe", "traditional", "homestyle", "famous", "brand", "range", "style",
        "home", "kitchen", "farm", "country", "signature", "everyday", "simply", "basic",
        // Dietary labels
        "organic", "natural", "pure", "gluten", "dairy", "vegan", "vegetarian", "lactose",
        "keto", "paleo", "sugarfree", "fatfree", "low", "fat", "reduced", "trim", "skim",
        "skimmed", "unsalted", "salted", "mild",
        // Packaging / size
        "pack", "packet", "bag", "bottle", "jar", "tin", "can", "box", "tub", "pouch", "carton",
        "tray", "punnet", "bunch", "sachet", "squeeze", "each", "size", "large", "small",
        "medium", "mini", "jumbo", "family", "twin", "multipack", "tinned", "canned", "block",
        "loaf", "dozen", "stack", "wrap",
        // Amounts spelled out
        "drop", "pinch", "dash", "handful", "cup", "tbsp", "tbs", "tsp", "tablespoon", "teaspoon",
        "gram", "kilogram", "litre", "liter", "millilitre", "milliliter", "ounce", "pound",
        "piece", "slice", "serving", "serve", "portion", "half", "quarter", "whole", "one",
        "two", "three", "few", "some", "about", "approx", "approximately", "extra", "plus",
        // Prep notes
        "chopped", "diced", "riced", "sliced", "grated", "crushed", "peeled", "shredded", "ground",
        "finely", "roughly", "thinly", "thickly", "ripe", "softened", "melted", "room",
        "temperature", "optional", "taste", "garnish", "toasted", "roasted", "roast", "smoked",
        "cooked", "raw", "frozen", "chilled", "dried", "sweetened", "unsweetened", "thick",
        "thin", "plain", "mixed", "assorted", "baby", "boneless", "skinless", "deboned",
        "trimmed", "cubed", "halved", "quartered", "juiced", "juice", "zested", "beaten", "whisked",
        "sifted", "packed", "heaped", "level", "pickled", "corned", "shaved", "crumbled", "flaked",
        "baking",
        // Cuts and portions (chicken breast ≈ chicken; duck breast ≠ chicken breast)
        "breast", "thigh", "drumstick", "wing", "leg", "fillet", "filet", "cutlet", "chop",
        "rasher", "sprig", "stalk", "stick", "head", "knob", "strip", "wedge", "chunk",
        "floret", "stem", "rib", "belly", "shank", "nibble", "loin", "tenderloin",
        // Colours ("orange" is a fruit, so it stays)
        "red", "green", "white", "brown", "black", "yellow", "pink", "blue", "dark", "purple",
        // Household items that share a list with food but never match a recipe
        "paper", "towel", "toilet", "tissue", "soap", "detergent", "dishwashing", "cleaner",
        "bleach", "liner", "cling", "foil", "candle", "battery", "shampoo", "toothpaste",
        "sponge", "wipe", "nappy", "glad",
        // Joining words
        "and", "with", "the", "for", "from", "into", "without", "per", "any", "your"
    ]
}
