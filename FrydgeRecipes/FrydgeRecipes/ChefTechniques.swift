//
//  ChefTechniques.swift
//  FrydgeRecipes
//
//  The "Chef" button: short, practical how-tos for the hand skills recipes
//  assume you already have — cracking an egg, slicing a fish fillet, dicing
//  an onion. Every technique is tagged with the foods it applies to, the
//  `CookAction`s that call for it and the verbs recipes use, so cook mode
//  can surface the right ones for the step on screen and a fridge item can
//  show how to prep itself.
//
//  Content is bundled (no network) so it works at the bench with wet hands
//  and no signal; each technique also shows an in-app animated demonstration
//  for people who learn by watching.
//

import Foundation

struct ChefTechnique: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let summary: String
    let symbol: String
    let emoji: String
    /// Foods this applies to, as plain names (matched through IngredientMatcher).
    let foods: [String]
    /// Step actions that call for it.
    let actions: Set<CookAction>
    /// Words in step text that call for it ("crack", "fillet", "julienne").
    let verbs: [String]
    let steps: [String]
    let tips: [String]

    /// The motion shown as an in-app animated demonstration. Picked
    /// deterministically so the same technique always shows the same motion.
    var demonstrationPrimitive: AnimationPrimitive {
        actions.sorted(by: { $0.rawValue < $1.rawValue }).first?.primitive ?? .wait
    }

    static func == (lhs: ChefTechnique, rhs: ChefTechnique) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum ChefTechniqueLibrary {

    // MARK: - Relevance

    /// Techniques for a cooking step, best match first. Matches on the step's
    /// ingredients, its action and the verbs in its text; general knife-work
    /// comes last so a specific "dice an onion" always outranks "knife grip".
    static func relevant(to step: RecipeStep) -> [ChefTechnique] {
        relevant(toText: step.text, ingredients: step.ingredientRefs, action: step.action)
    }

    static func relevant(toText text: String, ingredients: [String], action: CookAction? = nil) -> [ChefTechnique] {
        let words = Self.words(in: text)
        let ingredientTokens = ingredients.map { IngredientMatcher.tokens($0) }
        let textTokens = IngredientMatcher.tokens(text)

        var scored: [(ChefTechnique, Int)] = []
        for technique in all {
            var score = 0
            let foodTokens = foodTokensByID[technique.id] ?? []
            let foodInIngredients = ingredientTokens.contains { IngredientMatcher.tokensMatch(foodTokens, $0) }
            let foodInText = IngredientMatcher.tokensMatch(foodTokens, textTokens)
            let verbInText = technique.verbs.contains { words.contains($0) }
            let actionMatches = action.map { technique.actions.contains($0) } ?? false

            if foodInIngredients || foodInText { score += 3 }
            if verbInText { score += 3 }
            if actionMatches { score += 1 }
            // A food-specific technique needs its food present; a general one
            // (no foods) needs its verb or action.
            if !technique.foods.isEmpty && !(foodInIngredients || foodInText) { continue }
            if technique.foods.isEmpty && !(verbInText || actionMatches) { continue }
            // Food alone isn't enough for a technique with a very specific
            // verb (fillet, debeard): require the verb or a knife action.
            if !technique.foods.isEmpty && !verbInText && !actionMatches { continue }
            if score > 0 { scored.append((technique, score)) }
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Techniques for a food on its own ("how do I prep this?").
    static func relevant(toFood name: String) -> [ChefTechnique] {
        let tokens = IngredientMatcher.tokens(name)
        guard !tokens.isEmpty else { return [] }
        return all.filter { technique in
            guard let foodTokens = foodTokensByID[technique.id], !foodTokens.isEmpty else { return false }
            return IngredientMatcher.tokensMatch(foodTokens, tokens)
        }
    }

    /// Free-text search over titles, summaries, foods and verbs.
    static func search(_ query: String) -> [ChefTechnique] {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        return all.filter { t in
            t.title.lowercased().contains(q)
                || t.summary.lowercased().contains(q)
                || t.foods.contains { $0.lowercased().contains(q) }
                || t.verbs.contains { $0.contains(q) }
        }
    }

    static func technique(id: String) -> ChefTechnique? { all.first { $0.id == id } }

    private static func words(in text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
    }

    private static let foodTokensByID: [String: Set<String>] = {
        var out: [String: Set<String>] = [:]
        for t in all {
            var tokens: Set<String> = []
            for food in t.foods { tokens.formUnion(IngredientMatcher.tokens(food)) }
            out[t.id] = tokens
        }
        return out
    }()

    // MARK: - Library

    static let all: [ChefTechnique] = [

        // ── Eggs ────────────────────────────────────────────────────────────

        ChefTechnique(
            id: "crack-egg", title: "Crack an egg", summary: "Clean break, no shell in the bowl.",
            symbol: "oval.portrait", emoji: "🥚", foods: ["egg"], actions: [.add, .mix, .whisk],
            verbs: ["crack", "cracked", "eggs", "egg"],
            steps: [
                "Tap the egg firmly once on a flat surface (the bench, not the rim of the bowl). A flat surface makes one clean crack; a rim drives shell inwards.",
                "Hold the egg over the bowl with both thumbs on the crack.",
                "Pull the halves apart gently and let the egg drop. Don't squeeze.",
                "If a piece of shell falls in, scoop it out with half the shell — it cuts through the white far better than a finger."
            ],
            tips: [
                "Crack into a small bowl first when adding to a batter, so a bad egg or shell doesn't ruin the lot.",
                "Room-temperature eggs crack cleaner and mix in more evenly."
            ]),

        ChefTechnique(
            id: "separate-egg", title: "Separate an egg", summary: "Yolks one way, whites the other, no yolk in the whites.",
            symbol: "circle.lefthalf.filled", emoji: "🥚", foods: ["egg"], actions: [],
            verbs: ["separate", "separated", "yolk", "yolks", "whites", "white"],
            steps: [
                "Crack the egg into a clean, dry bowl.",
                "Scoop the yolk out with clean fingers, letting the white run through them. Or tip the yolk back and forth between the shell halves.",
                "Drop the yolk into a second bowl.",
                "Separate each egg over a third small bowl, then pour the clean white into the main bowl. One broken yolk won't spoil the batch."
            ],
            tips: [
                "Cold eggs separate more easily; whites whip higher once they warm up.",
                "Even a trace of yolk stops whites whipping. Start again rather than fish it out."
            ]),

        ChefTechnique(
            id: "whisk-whites", title: "Whisk egg whites to peaks", summary: "Soft, firm and stiff peaks, and how to tell.",
            symbol: "tornado", emoji: "🥚", foods: ["egg"], actions: [.whisk],
            verbs: ["peaks", "peak", "whisk", "whip", "beat", "meringue", "stiff"],
            steps: [
                "Use a spotless, dry metal or glass bowl — fat or water stops whites foaming.",
                "Start on medium speed until foamy, then increase to high.",
                "Soft peaks: the tip flops over when you lift the whisk. Good for folding into mousses and soufflés.",
                "Firm peaks: the tip holds but curls at the top. Most meringues and pavlova start adding sugar here.",
                "Stiff peaks: the tip stands straight and the bowl can be tipped without movement. Stop here — further whisking turns them grainy."
            ],
            tips: [
                "A pinch of salt or cream of tartar helps whites hold their shape.",
                "Add sugar a spoon at a time once soft peaks form; dumping it in collapses the foam."
            ]),

        ChefTechnique(
            id: "poach-egg", title: "Poach an egg", summary: "Set white, runny yolk, no wispy mess.",
            symbol: "drop", emoji: "🍳", foods: ["egg"], actions: [.simmer, .boil],
            verbs: ["poach", "poached", "poaching"],
            steps: [
                "Bring a deep pan of water to a bare simmer — small bubbles, not a rolling boil. Add a splash of vinegar if you like.",
                "Crack the egg into a small cup or sieve first; a sieve drains the thin, wispy white away.",
                "Stir the water into a gentle whirlpool and slide the egg into the centre.",
                "Cook 3 minutes for a runny yolk, 4 for jammy.",
                "Lift out with a slotted spoon and rest on paper towel for a moment."
            ],
            tips: [
                "The fresher the egg, the tighter it holds together.",
                "Poach ahead into iced water, then reheat 30 seconds in hot water when serving a crowd."
            ]),

        // ── Vegetables & aromatics ───────────────────────────────────────────

        ChefTechnique(
            id: "dice-onion", title: "Dice an onion", summary: "Even dice, fast, fewer tears.",
            symbol: "square.grid.3x3", emoji: "🧅", foods: ["onion", "shallot"], actions: [.dice, .chop, .slice],
            verbs: ["dice", "diced", "chop", "chopped", "finely"],
            steps: [
                "Cut the onion in half through the root, then peel. Leave the root on — it holds the layers together.",
                "Lay a half flat. Make horizontal cuts towards the root, stopping just short of it.",
                "Make vertical cuts from the top towards the root, again stopping short, spaced to the dice size you want.",
                "Slice across the cuts and the dice falls away. Discard the root nub.",
                "For slices instead of dice, skip the horizontal and vertical cuts and just slice across."
            ],
            tips: [
                "A sharp knife crushes fewer cells, which means less of the gas that makes you cry.",
                "Chill the onion 15 minutes first and it will be gentler on your eyes."
            ]),

        ChefTechnique(
            id: "mince-garlic", title: "Mince or crush garlic", summary: "Paste for sauces, mince for frying.",
            symbol: "circle.hexagongrid", emoji: "🧄", foods: ["garlic"], actions: [.mince, .crush, .chop],
            verbs: ["mince", "minced", "crush", "crushed", "garlic", "paste"],
            steps: [
                "Lay the flat of the knife on the clove and press down with your palm to split the skin. Peel it off.",
                "Trim the hard root end.",
                "Slice the clove thinly, then rock the knife over the slices until finely chopped.",
                "For a paste, sprinkle with a pinch of salt and drag the flat of the blade across the pile a few times."
            ],
            tips: [
                "Minced garlic burns in seconds — add it to the pan after the onion has softened, and cook just until fragrant.",
                "Smashed whole cloves give a mellower flavour that won't burn as easily."
            ]),

        ChefTechnique(
            id: "julienne", title: "Julienne vegetables", summary: "Matchsticks for stir-fries, slaws and garnish.",
            symbol: "line.3.horizontal", emoji: "🥕", foods: ["carrot", "capsicum", "zucchini", "cucumber", "ginger", "celery"], actions: [.slice, .chop],
            verbs: ["julienne", "julienned", "matchstick", "matchsticks", "batons", "strips", "thinly"],
            steps: [
                "Cut the vegetable into 5–6 cm lengths.",
                "Square off one side so it sits flat and doesn't roll.",
                "Slice lengthways into thin planks, 2–3 mm thick.",
                "Stack a few planks and slice lengthways again into matchsticks the same width."
            ],
            tips: [
                "Keep the pieces the same thickness and they'll cook at the same rate.",
                "A mandoline makes the planks in seconds — always use the guard."
            ]),

        ChefTechnique(
            id: "chiffonade", title: "Chiffonade herbs and greens", summary: "Fine ribbons of basil, mint or spinach without bruising.",
            symbol: "leaf", emoji: "🌿", foods: ["basil", "mint", "spinach", "sage", "silverbeet", "kale"], actions: [.slice, .chop, .garnish],
            verbs: ["chiffonade", "shred", "shredded", "ribbons", "sliced", "slice", "torn"],
            steps: [
                "Stack 6–8 leaves, largest on the bottom.",
                "Roll the stack tightly into a cigar.",
                "Slice across the roll thinly with a sharp knife. Don't saw.",
                "Fluff the ribbons apart with your fingers and use straight away."
            ],
            tips: [
                "Cut basil at the last moment; the cut edges darken within minutes.",
                "For kale and silverbeet, strip the tough stem out first."
            ]),

        ChefTechnique(
            id: "chop-herbs", title: "Chop herbs finely", summary: "Parsley, coriander and chives without turning them to mush.",
            symbol: "scissors", emoji: "🌿", foods: ["parsley", "cilantro", "chive", "dill", "tarragon", "oregano", "rosemary", "thyme"], actions: [.chop, .garnish],
            verbs: ["chop", "chopped", "finely", "roughly", "garnish", "sprinkle"],
            steps: [
                "Wash and dry the herbs completely — wet herbs clump and bruise.",
                "Pick the leaves from thick stems (coriander and parsley stems are tender; keep them).",
                "Gather into a tight pile and slice across it, keeping the knife tip on the board.",
                "Rock the knife over the pile until it's as fine as you want. Stop before it looks wet."
            ],
            tips: [
                "Strip woody herbs like rosemary and thyme by pulling backwards along the stem.",
                "Add soft herbs at the end of cooking; woody ones go in early."
            ]),

        ChefTechnique(
            id: "ginger", title: "Peel and grate ginger", summary: "Spoon-peel, then grate or slice without the fibres.",
            symbol: "circle.dotted", emoji: "🫚", foods: ["ginger"], actions: [.peel, .grate, .mince],
            verbs: ["grate", "grated", "peel", "peeled", "ginger"],
            steps: [
                "Scrape the skin off with the edge of a teaspoon. It gets into the knobbles and wastes far less than a peeler.",
                "To grate: rub across a microplane. Grate against the grain and the fibres stay behind.",
                "To slice: cut thin coins across the grain, then stack and cut into matchsticks or mince.",
                "Squeeze grated ginger in your fist for juice if a recipe only wants the flavour."
            ],
            tips: [
                "Freeze the root and grate it from frozen — no peeling, no fibres.",
                "Young ginger with thin, shiny skin doesn't need peeling at all."
            ]),

        ChefTechnique(
            id: "avocado", title: "Cut and stone an avocado", summary: "Halve, twist, remove the stone safely, scoop or dice.",
            symbol: "circle.circle", emoji: "🥑", foods: ["avocado"], actions: [.slice, .dice, .peel],
            verbs: ["avocado", "stone", "pit", "halve", "halved", "mash", "mashed", "scoop"],
            steps: [
                "Cut lengthways around the stone and twist the halves apart.",
                "Put the half with the stone on a board, cup side up. Hold it with a tea towel and tap the stone gently with the knife heel so the blade lodges, then twist to lift it out. Never hold it in your palm.",
                "Score the flesh in a grid without cutting through the skin, then scoop out with a spoon for dice.",
                "For slices, peel the skin away and lay the half flat before slicing."
            ],
            tips: [
                "A ripe avocado yields to gentle pressure at the stem end and the stem button flicks off green.",
                "Lemon or lime juice on cut surfaces slows browning."
            ]),

        ChefTechnique(
            id: "capsicum", title: "Core and slice a capsicum", summary: "No seeds, no waste, flat pieces that slice evenly.",
            symbol: "square.dashed", emoji: "🫑", foods: ["capsicum"], actions: [.slice, .dice, .chop],
            verbs: ["deseed", "deseeded", "core", "cored", "seeds", "capsicum", "pepper", "strips", "sliced"],
            steps: [
                "Stand the capsicum upright and slice down each side, following the curve, leaving the core and seeds standing.",
                "Trim any white pith from the inside of the pieces.",
                "Lay each piece skin-side down and slice into strips. Skin-side down stops the knife sliding.",
                "Turn the strips and cut across for dice."
            ],
            tips: [
                "Cut around the core and there's nothing to wash out — the seeds stay attached.",
                "Char whole over a flame or under the grill, steam in a covered bowl 10 minutes, and the skin slips off."
            ]),

        ChefTechnique(
            id: "mango", title: "Cut a mango", summary: "Hedgehog cubes around the flat stone.",
            symbol: "square.grid.2x2", emoji: "🥭", foods: ["mango"], actions: [.slice, .dice, .peel],
            verbs: ["mango", "cheeks", "cubes", "diced", "dice", "cubed"],
            steps: [
                "Stand the mango on its end, stem down. The stone is a flat oval running through the middle.",
                "Slice down each side about 1 cm from the centre to take off the two cheeks.",
                "Score each cheek in a grid down to the skin without cutting through.",
                "Push the skin from underneath to pop the cubes up, then slice them off.",
                "Trim the remaining flesh from around the stone."
            ],
            tips: [
                "A ripe mango smells sweet at the stem and gives slightly — colour isn't a reliable guide.",
                "Freeze the cubes on a tray for smoothies."
            ]),

        ChefTechnique(
            id: "citrus", title: "Zest and segment citrus", summary: "Zest without pith, and clean segments with no membrane.",
            symbol: "circle.grid.cross", emoji: "🍊", foods: ["orange", "lemon", "lime", "grapefruit", "mandarin"], actions: [.garnish, .peel, .slice],
            verbs: ["zest", "zested", "segment", "segments", "supreme", "juice", "juiced", "rind", "peel"],
            steps: [
                "Zest before juicing. Rub the fruit across a microplane and stop at the white pith, which is bitter.",
                "To segment: slice off the top and bottom so it stands flat.",
                "Cut the peel and pith away in strips, following the curve, until no white remains.",
                "Hold the fruit over a bowl and cut along each side of the membranes to release the segments.",
                "Squeeze the leftover membranes for juice."
            ],
            tips: [
                "Roll the fruit firmly on the bench before juicing and you'll get noticeably more out of it.",
                "Microwave a cold lemon 10 seconds for more juice."
            ]),

        ChefTechnique(
            id: "peel-tomato", title: "Peel and seed tomatoes", summary: "Score, blanch, shock — skins slip off.",
            symbol: "circle.dashed", emoji: "🍅", foods: ["tomato"], actions: [.peel, .boil],
            verbs: ["peel", "peeled", "skin", "skinned", "blanch", "blanched", "seeded", "deseed", "concasse"],
            steps: [
                "Cut a shallow cross in the base of each tomato.",
                "Drop into boiling water for 15–30 seconds, until the skin at the cross starts to curl.",
                "Lift straight into iced water.",
                "Peel the skin back from the cross — it comes away in sheets.",
                "To seed, quarter the tomato and scoop out the seeds and jelly with your thumb."
            ],
            tips: [
                "Don't leave them in the hot water longer or the outside goes mushy.",
                "Keep the seeds and jelly for stock or a vinaigrette; that's where much of the flavour is."
            ]),

        ChefTechnique(
            id: "pineapple", title: "Prepare a pineapple", summary: "Skin, eyes and core gone in a couple of minutes.",
            symbol: "circle.hexagonpath", emoji: "🍍", foods: ["pineapple"], actions: [.peel, .slice, .dice],
            verbs: ["pineapple", "core", "cored", "peel", "peeled", "chunks"],
            steps: [
                "Slice off the top and the base so it stands flat.",
                "Cut the skin away in strips from top to bottom, following the curve.",
                "Cut out any remaining eyes in diagonal grooves — they spiral around the fruit.",
                "Quarter lengthways and slice the fibrous core off each quarter.",
                "Cut into spears or chunks."
            ],
            tips: [
                "A ripe pineapple smells sweet at the base and a centre leaf pulls out easily.",
                "Fresh pineapple contains an enzyme that stops jelly setting and tenderises meat fast — a marinade of 20 minutes is plenty."
            ]),

        // ── Fish & seafood ───────────────────────────────────────────────────

        ChefTechnique(
            id: "slice-fish", title: "Slice and portion a fish fillet", summary: "Even portions, clean slices, for pan-frying, curries or sashimi.",
            symbol: "fish", emoji: "🐟", foods: ["fish", "salmon", "snapper", "tuna", "cod", "hoki", "tarakihi", "gurnard", "kingfish", "trevally"], actions: [.slice, .chop, .dice, .trim],
            verbs: ["slice", "sliced", "portion", "portions", "cut", "pieces", "chunks", "cubes", "strips"],
            steps: [
                "Pat the fillet dry and lay it skin-side down on the board.",
                "Run your fingers along the centre line and pull out any pin bones with tweezers.",
                "For portions, cut straight down across the fillet with one long stroke — don't saw. Aim for equal weight, so make thin-tail pieces longer than thick-head pieces.",
                "For curry or stir-fry chunks, cut across into 3 cm strips, then across again.",
                "For thin slices (sashimi, ceviche, crudo), angle the blade at about 45° and draw it through in one pull, against the grain of the flakes."
            ],
            tips: [
                "A long, thin, very sharp knife tears less. Wipe the blade between cuts.",
                "Half-frozen fish (20 minutes in the freezer) slices far more cleanly for thin slices."
            ]),

        ChefTechnique(
            id: "skin-fillet", title: "Skin a fish fillet", summary: "Remove the skin in one piece without losing flesh.",
            symbol: "rectangle.and.hand.point.up.left", emoji: "🐟", foods: ["fish", "salmon", "snapper", "cod", "hoki", "tarakihi", "gurnard"], actions: [.trim, .peel],
            verbs: ["skin", "skinned", "skinless", "remove"],
            steps: [
                "Lay the fillet skin-side down, tail end towards you.",
                "Make a small cut through the flesh at the tail end, down to the skin but not through it.",
                "Grip the skin tab firmly — salt on your fingers helps — and angle the knife blade down slightly against the skin.",
                "Hold the knife still and pull the skin towards you with a gentle side-to-side wiggle, letting the skin slide under the blade.",
                "Trim any silver skin or dark bloodline left behind if you want a milder flavour."
            ],
            tips: [
                "Leave the skin on if you're pan-frying: it crisps up and protects the flesh.",
                "A flexible filleting knife follows the skin; a stiff chef's knife tends to cut through it."
            ]),

        ChefTechnique(
            id: "fillet-fish", title: "Fillet a whole fish", summary: "Two clean fillets from a whole round fish.",
            symbol: "fish.fill", emoji: "🐟", foods: ["fish", "snapper", "trout", "kahawai", "gurnard", "tarakihi", "trevally", "mackerel", "sardine"], actions: [.trim],
            verbs: ["fillet", "filleted", "filleting", "whole", "gut", "gutted", "scale", "scaled", "bone"],
            steps: [
                "Scale the fish under running water by scraping from tail to head with the back of a knife, then gut it if needed and rinse the cavity.",
                "Lay it on its side. Cut behind the gill plate and pectoral fin, angling towards the head, down to the backbone.",
                "Turn the blade flat, pointing to the tail. Cut along the backbone in long strokes, keeping the blade pressed against the bones, until the fillet lifts off at the tail.",
                "Flip the fish and repeat on the other side.",
                "Trim the rib bones from each fillet by sliding the knife under them, then pull the pin bones with tweezers."
            ],
            tips: [
                "Keep the fish very cold and the board dry; a wet fish slides.",
                "Save the frame and head for stock — simmer 20 minutes, no longer, or it turns bitter."
            ]),

        ChefTechnique(
            id: "prawns", title: "Peel and devein prawns", summary: "Shell off, vein out, tail on or off.",
            symbol: "allergens", emoji: "🦐", foods: ["shrimp", "prawn"], actions: [.peel, .trim],
            verbs: ["devein", "deveined", "peel", "peeled", "shell", "shelled", "prawns", "shrimp"],
            steps: [
                "Twist off the head if it's still on.",
                "Peel the shell away from the legs side, leaving the last tail segment on for presentation or removing it for curries.",
                "Run a small knife shallowly along the back and lift out the dark vein with the tip. Rinse.",
                "For butterflied prawns, cut deeper along the back and press them open flat."
            ],
            tips: [
                "Keep the heads and shells; fried in oil then simmered 15 minutes they make a quick, intense stock.",
                "Prawns are done the instant they curl into a C and turn opaque. An O shape means overcooked."
            ]),

        ChefTechnique(
            id: "mussels", title: "Clean and debeard mussels", summary: "Scrub, debeard, and spot the ones to throw out.",
            symbol: "oval.inset.filled", emoji: "🦪", foods: ["mussel"], actions: [.steam, .boil],
            verbs: ["debeard", "debearded", "beard", "beards", "scrub", "scrubbed", "clean", "cleaned", "mussels"],
            steps: [
                "Tip the mussels into cold water and discard any that are cracked, or open and don't close when tapped.",
                "Scrub the shells with a stiff brush to remove grit and barnacles.",
                "Pull the stringy beard firmly towards the hinge end of the shell to remove it. Do this just before cooking — it kills the mussel.",
                "Rinse again, drain, and cook within the hour.",
                "After cooking, discard any that stayed firmly shut."
            ],
            tips: [
                "Store live mussels in the fridge under a damp cloth, never in water or a sealed bag.",
                "They need only 3–5 minutes of steam; take them out as they open."
            ]),

        // ── Meat & poultry ───────────────────────────────────────────────────

        ChefTechnique(
            id: "debone-thigh", title: "Debone a chicken thigh", summary: "Bone out in under a minute; keep the skin on for crispness.",
            symbol: "bandage", emoji: "🍗", foods: ["chicken", "chickenthigh"], actions: [.trim],
            verbs: ["debone", "deboned", "boneless", "bone", "thigh", "thighs"],
            steps: [
                "Lay the thigh skin-side down. You'll feel the single bone running through the middle.",
                "Cut along the length of the bone to expose it.",
                "Scrape the meat away from the bone on both sides with short strokes, keeping the blade on the bone.",
                "Cut under each end of the bone to free it. Trim any cartilage or excess fat.",
                "Open the thigh out flat — it's now ready to pan-fry, grill or dice."
            ],
            tips: [
                "Thighs forgive overcooking far more than breast; aim for 74 °C at the thickest point.",
                "Freeze the bones for stock."
            ]),

        ChefTechnique(
            id: "butterfly-breast", title: "Butterfly a chicken breast", summary: "Even thickness so it cooks through without drying out.",
            symbol: "rectangle.split.2x1", emoji: "🍗", foods: ["chicken", "chickenbreast"], actions: [.slice, .trim, .fry, .grill],
            verbs: ["butterfly", "butterflied", "flatten", "flattened", "pound", "even", "thickness", "breast", "breasts", "schnitzel"],
            steps: [
                "Lay the breast flat and put your palm on top.",
                "Holding the knife parallel to the board, slice horizontally through the thickest side, stopping about 1 cm from the far edge.",
                "Open it out like a book.",
                "For an even schnitzel, cover with baking paper and flatten gently with a rolling pin or the base of a pan."
            ],
            tips: [
                "For two thin fillets rather than one butterflied, simply cut all the way through.",
                "Brine 30 minutes in salted water for a noticeably juicier breast."
            ]),

        ChefTechnique(
            id: "carve-chicken", title: "Carve a roast chicken", summary: "Legs, thighs, wings and neat breast slices.",
            symbol: "fork.knife", emoji: "🍗", foods: ["chicken", "turkey", "duck"], actions: [.plate, .serve, .rest],
            verbs: ["carve", "carved", "carving", "joint", "jointed", "roast", "whole"],
            steps: [
                "Rest the bird 15 minutes under loose foil first, or the juices run out on the board.",
                "Pull a leg away from the body and cut through the skin, then push the leg down until the thigh joint pops. Cut through the joint. Separate drumstick and thigh at the knuckle.",
                "Pull each wing out and cut through its joint.",
                "Cut down along one side of the breastbone, then follow the ribcage with the knife to lift the whole breast off.",
                "Slice each breast across the grain into thick slices."
            ],
            tips: [
                "A chicken is done when a skewer in the thickest part of the thigh runs clear, or a thermometer reads 74 °C.",
                "Keep the carcass for stock."
            ]),

        ChefTechnique(
            id: "against-grain", title: "Slice meat against the grain", summary: "The single biggest difference between tender and chewy.",
            symbol: "arrow.left.and.right", emoji: "🥩", foods: ["beef", "steak", "lamb", "pork", "venison"], actions: [.slice, .serve, .plate],
            verbs: ["grain", "slice", "sliced", "thinly", "strips", "carve"],
            steps: [
                "Look at the cooked (or raw) meat for the direction the muscle fibres run — fine parallel lines.",
                "Turn the meat so those lines run left to right in front of you.",
                "Slice across the lines, so each slice contains short fibres rather than long ones.",
                "For stir-fries, slice raw meat this way as thinly as you can; 20 minutes in the freezer firms it up for thinner slices."
            ],
            tips: [
                "On a flank, skirt or bavette the grain is obvious and the difference is dramatic.",
                "On a roast, the grain can change direction between muscles — re-check as you go."
            ]),

        ChefTechnique(
            id: "sear-steak", title: "Sear and rest a steak", summary: "Deep crust, pink centre, and why the rest matters.",
            symbol: "flame", emoji: "🥩", foods: ["steak", "beef", "lamb"], actions: [.sear, .fry, .grill, .rest],
            verbs: ["sear", "seared", "searing", "crust", "rest", "rested", "medium", "rare", "steak"],
            steps: [
                "Take the steak out of the fridge 30 minutes ahead and pat it completely dry. Salt it generously just before cooking.",
                "Get a heavy pan smoking hot with a little high-smoke-point oil.",
                "Lay the steak in away from you and leave it alone — moving it stops the crust forming. Turn once it releases easily, about 2–3 minutes for a 2.5 cm steak.",
                "Add butter, garlic and thyme in the last minute and baste.",
                "Rest on a warm plate for at least as long as it cooked. The juices redistribute instead of running out when cut.",
                "Doneness by thermometer after resting: rare 52 °C, medium-rare 57 °C, medium 63 °C."
            ],
            tips: [
                "Don't crowd the pan — two steaks at most, or it steams.",
                "Flip every 30 seconds instead of once and you get a more even cook with the same crust."
            ]),

        ChefTechnique(
            id: "doneness", title: "Check meat is cooked", summary: "Safe temperatures and the touch test, by meat.",
            symbol: "thermometer.medium", emoji: "🌡️", foods: ["chicken", "turkey", "pork", "beef", "lamb", "mince", "sausage", "fish"], actions: [.roast, .bake, .grill, .fry, .sear],
            verbs: ["cooked", "through", "doneness", "done", "internal", "temperature", "juices", "clear", "pink"],
            steps: [
                "Use a probe thermometer in the thickest part, away from bone. It's the only reliable way.",
                "Chicken and turkey: 74 °C. Juices run clear and there's no pink at the bone.",
                "Pork: 63 °C then rest 3 minutes; a hint of pink in the middle is fine today.",
                "Mince, sausages and anything stuffed or rolled: 71 °C — bacteria from the surface are mixed through.",
                "Whole cuts of beef and lamb can be served rare (52 °C) because the inside is sterile; only the surface needs searing.",
                "Fish: 60 °C, or the flesh flakes easily and has just turned opaque."
            ],
            tips: [
                "Pull meat off the heat a few degrees early — it keeps cooking while it rests.",
                "Touch test for steak: press the fleshy pad under your thumb. Relaxed hand feels like rare; thumb to little finger feels like well done."
            ]),

        // ── Knife & hand skills ──────────────────────────────────────────────

        ChefTechnique(
            id: "knife-grip", title: "Hold a knife safely", summary: "The pinch grip and the claw: faster cutting, fingers intact.",
            symbol: "hand.raised", emoji: "🔪", foods: [], actions: [.chop, .slice, .dice, .mince, .trim],
            verbs: ["chop", "chopped", "slice", "sliced", "dice", "diced", "mince", "minced", "cut", "knife"],
            steps: [
                "Pinch the blade just in front of the handle between thumb and the side of your index finger; wrap the other fingers around the handle. This gives control the handle alone can't.",
                "With the other hand, curl your fingertips under into a claw and hold the food with your knuckles forward.",
                "Rest the flat of the blade against your knuckles. The blade can't climb over them, so it can't reach your fingertips.",
                "Rock the knife: keep the tip on the board and bring the heel down and forward through the food.",
                "Move the claw back a slice at a time; the knife follows your knuckles."
            ],
            tips: [
                "Put a damp cloth under the board so it can't slide.",
                "A sharp knife is safer than a dull one — it goes where you point it instead of skidding off."
            ]),

        ChefTechnique(
            id: "fold", title: "Fold a mixture gently", summary: "Keep the air in whipped cream, egg whites and batters.",
            symbol: "arrow.triangle.turn.up.right.diamond", emoji: "🥣", foods: [], actions: [.fold],
            verbs: ["fold", "folded", "folding", "gently"],
            steps: [
                "Add about a third of the light mixture (whites or cream) to the heavier one first and stir it in without worrying — this loosens the base.",
                "Add the rest. Cut straight down through the centre with a large metal spoon or spatula.",
                "Sweep along the bottom of the bowl and up the side, turning the mixture over onto itself.",
                "Give the bowl a quarter turn and repeat. Stop as soon as no streaks remain — a few is better than overmixing."
            ],
            tips: [
                "A big, wide bowl makes folding far easier.",
                "Flour folded into whisked eggs should be sifted over in two or three batches."
            ]),

        ChefTechnique(
            id: "knead", title: "Knead dough", summary: "Push, fold, turn — and the windowpane test for when it's done.",
            symbol: "hands.and.sparkles", emoji: "🍞", foods: ["flour", "yeast", "bread", "pizzabase"], actions: [.knead, .proof],
            verbs: ["knead", "kneaded", "kneading", "dough", "elastic", "smooth", "windowpane"],
            steps: [
                "Tip the dough onto a lightly floured bench. Resist adding much flour — a tacky dough makes a lighter loaf.",
                "Push the dough away from you with the heel of your hand, stretching it.",
                "Fold the far edge back over towards you, give it a quarter turn, and push again.",
                "Keep going 8–10 minutes until it's smooth, springy and no longer sticks.",
                "Windowpane test: stretch a small piece thin between your fingers. If it goes translucent without tearing, the gluten is developed."
            ],
            tips: [
                "Wet, sticky doughs can be kneaded in the bowl with a slap-and-fold or just left to rest; time develops gluten too.",
                "Dough has proved enough when a floured finger poked in leaves a dent that springs back slowly."
            ]),

        ChefTechnique(
            id: "roux", title: "Make a roux and a smooth sauce", summary: "Butter, flour, then liquid — without lumps.",
            symbol: "drop.triangle", emoji: "🥛", foods: ["flour", "butter", "milk"], actions: [.stir, .whisk, .simmer],
            verbs: ["roux", "thicken", "thickened", "bechamel", "béchamel", "white", "sauce", "gravy", "lumps"],
            steps: [
                "Melt the butter over medium heat and stir in an equal weight of flour.",
                "Cook, stirring, 1–2 minutes until it smells biscuity. Longer gives a darker, nuttier roux for gumbo or gravy.",
                "Take the pan off the heat and add the liquid a splash at a time at first, whisking until smooth before the next splash.",
                "Once it's loose, add the rest in a steady stream, return to the heat and whisk until it bubbles and thickens.",
                "Simmer 2–3 minutes to cook out the floury taste. Season at the end."
            ],
            tips: [
                "Warm liquid into a hot roux is the lump-free combination; cold into hot also works if you whisk hard.",
                "Lumps anyway? Blitz with a stick blender or push through a sieve. Nobody will know."
            ]),

        ChefTechnique(
            id: "deglaze", title: "Deglaze a pan", summary: "Turn the browned bits into a sauce.",
            symbol: "wineglass", emoji: "🍷", foods: ["wine", "stock", "redwine", "whitewine"], actions: [.reduce, .pour, .simmer],
            verbs: ["deglaze", "deglazed", "scrape", "scraping", "browned", "bits", "fond", "pan", "juices"],
            steps: [
                "After searing meat or frying onions, take the food out and pour off all but a spoonful of fat.",
                "With the pan still hot, pour in a splash of wine, stock, vinegar or even water.",
                "Scrape the base with a wooden spoon as it sizzles — the stuck-on browned bits dissolve into the liquid. That's the flavour.",
                "Let it bubble and reduce by half, then build the sauce: add stock, cream or butter and simmer to the consistency you want."
            ],
            tips: [
                "Stand back when adding alcohol to a very hot pan.",
                "Don't deglaze a non-stick pan — nothing sticks, so there's nothing to lift."
            ]),

        ChefTechnique(
            id: "blanch", title: "Blanch and refresh vegetables", summary: "Bright green, crisp-tender, and ready ahead of time.",
            symbol: "snowflake", emoji: "🥦", foods: ["broccoli", "greenbean", "asparagus", "pea", "spinach", "kale", "cauliflower", "snowpea"], actions: [.boil, .drain],
            verbs: ["blanch", "blanched", "refresh", "refreshed", "shock", "iced", "tender"],
            steps: [
                "Bring a large pot of well-salted water to a rolling boil and have a bowl of iced water ready.",
                "Drop the vegetables in — small batches so the water keeps boiling.",
                "Cook until just tender and vividly coloured: 1 minute for peas and spinach, 2–3 for beans and broccoli.",
                "Lift straight into the iced water to stop the cooking and fix the colour.",
                "Drain well. Reheat in butter or a hot pan for 30 seconds when serving."
            ],
            tips: [
                "Salt the water like the sea; it seasons the vegetables and helps keep the colour.",
                "This is how to prep greens hours ahead for a dinner party."
            ]),

        ChefTechnique(
            id: "rice", title: "Cook rice by absorption", summary: "Fluffy, separate grains with no rice cooker.",
            symbol: "circle.grid.3x3.fill", emoji: "🍚", foods: ["rice"], actions: [.simmer, .boil, .rest],
            verbs: ["rice", "absorption", "absorbed", "fluff", "fluffed", "steam"],
            steps: [
                "Rinse the rice in a sieve under cold water until it runs clear. This removes surface starch so the grains don't clump.",
                "Put the rice in a pot with 1.5 times its volume in water (1 cup rice, 1½ cups water) and a pinch of salt.",
                "Bring to the boil uncovered, then cover tightly and turn the heat to the lowest setting.",
                "Cook 12 minutes without lifting the lid.",
                "Take off the heat and leave covered 10 minutes more, then fluff with a fork."
            ],
            tips: [
                "Brown rice needs about 2 times the water and 35–40 minutes.",
                "Cool leftover rice quickly and refrigerate within an hour; reheat until steaming hot."
            ]),

        ChefTechnique(
            id: "pasta", title: "Cook pasta al dente", summary: "Salted water, timing, and saving the starchy water.",
            symbol: "water.waves", emoji: "🍝", foods: ["pasta", "noodle"], actions: [.boil, .drain, .toss],
            verbs: ["pasta", "al", "dente", "boil", "boiled", "drain", "drained", "toss", "tossed"],
            steps: [
                "Use a big pot and plenty of water — at least 1 litre per 100 g. Salt it generously (about 10 g per litre) once boiling.",
                "Add the pasta and stir in the first minute so it doesn't stick.",
                "Cook 1–2 minutes less than the packet says, tasting as you go. Al dente has a faint firm bite at the centre.",
                "Scoop out a mug of the cooking water before draining.",
                "Toss the pasta with the sauce in the pan over heat, adding splashes of the starchy water until it clings and looks glossy."
            ],
            tips: [
                "No oil in the water — it stops the sauce clinging later.",
                "Pasta finishes cooking in the sauce; that's why you under-cook it slightly."
            ]),

        ChefTechnique(
            id: "caramelise-onion", title: "Caramelise onions", summary: "Sweet, deep brown, and why it takes longer than recipes say.",
            symbol: "sun.max", emoji: "🧅", foods: ["onion"], actions: [.saute, .fry, .reduce],
            verbs: ["caramelise", "caramelised", "caramelize", "caramelized", "golden", "soften", "softened", "sweated", "sweat"],
            steps: [
                "Slice the onions evenly, pole to pole, so they cook at the same rate.",
                "Cook in butter or oil over medium-low heat with a pinch of salt. Stir every few minutes.",
                "Soft and translucent takes about 10 minutes; golden about 20; deep caramel 40 or more. There's no honest shortcut.",
                "When the base of the pan browns, add a splash of water and scrape it back into the onions.",
                "Finish with a little vinegar or wine to balance the sweetness."
            ],
            tips: [
                "A wide pan with the onions in a shallow layer is faster than a deep pile.",
                "Make a big batch and freeze in portions; they lift soups, pizzas and burgers."
            ]),

        ChefTechnique(
            id: "melt-chocolate", title: "Melt and temper chocolate", summary: "Smooth melting, and a glossy snap for dipping.",
            symbol: "square.fill.on.square", emoji: "🍫", foods: ["chocolate"], actions: [.warm, .stir],
            verbs: ["melt", "melted", "melting", "temper", "tempered", "chocolate", "seize", "seized"],
            steps: [
                "Chop the chocolate evenly. Melt in a bowl over barely simmering water (the bowl must not touch the water) or in the microwave in 20-second bursts, stirring between each.",
                "Keep every drop of water away from it — a single splash makes it seize into a grainy paste.",
                "To temper dark chocolate simply: melt two-thirds to 45–50 °C, take off the heat, and stir in the remaining third until it melts and the mixture cools to about 31 °C.",
                "Test by dipping a knife tip: tempered chocolate sets glossy within a few minutes at room temperature."
            ],
            tips: [
                "Seized chocolate can be rescued for sauces by stirring in warm cream or milk a spoon at a time.",
                "Milk and white chocolate burn at lower temperatures — go gently."
            ]),

        ChefTechnique(
            id: "season", title: "Season to taste", summary: "Salt in layers, acid at the end, and what to do when it's bland.",
            symbol: "sparkles", emoji: "🧂", foods: [], actions: [.season, .garnish, .serve],
            verbs: ["season", "seasoned", "seasoning", "taste", "salt", "pepper", "adjust", "bland"],
            steps: [
                "Salt as you go, a little at each stage, rather than all at the end. Flavour built in layers tastes seasoned, not salty.",
                "Taste before serving. If it's flat but you can't say why, it almost always needs salt first.",
                "If it's seasoned but still dull, add acid: a squeeze of lemon or a splash of vinegar brightens without tasting sour.",
                "Too salty? Add volume (more unsalted stock, potato, cream) or acid and a pinch of sugar; you can't take salt out.",
                "Finish with fresh pepper, herbs or good oil — the aromatics that cooking drives off."
            ],
            tips: [
                "Use flaky salt in your fingers so you can feel how much you're adding.",
                "Soups and stews taste less salty when hot than when they cool — season them hot."
            ])
    ]
}
