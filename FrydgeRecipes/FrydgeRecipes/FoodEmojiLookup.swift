import Foundation

enum FoodEmoji {

    static func emoji(for name: String) -> String {
        let lower = name.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Longer / more specific keywords first so "sweet potato" beats "potato"
        for (keyword, emoji) in lookup {
            if lower.contains(keyword) { return emoji }
        }
        return "🍽️"
    }

    /// Returns the recognised food keyword for a name, stripping brand/descriptor prefixes.
    /// e.g. "Anchor Butter" → "butter", "Golden Syrup" → "golden syrup", "Corn Chips" → "corn chips"
    /// Falls back to the lowercased original when no keyword matches.
    static func searchTerm(for name: String) -> String {
        let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for (keyword, _) in lookup {
            if lower.contains(keyword) { return keyword }
        }
        return lower
    }

    /// Like `searchTerm`, but returns nil when no known food keyword is found
    /// (instead of echoing the whole string). Used to build at-a-glance shorthands.
    static func knownKeyword(for name: String) -> String? {
        let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for (keyword, _) in lookup {
            if lower.contains(keyword) { return keyword }
        }
        return nil
    }

    /// All known food keywords that appear as whole words in `name`.
    /// (De-duplicated; order is not significant.)
    static func wholeWordKeywords(in name: String) -> [String] {
        let lower = name.lowercased()
        var out: [String] = []
        var seen = Set<String>()
        for (keyword, _) in lookup {
            guard !seen.contains(keyword) else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: keyword)
            if lower.range(of: "\\b\(escaped)\\b", options: .regularExpression) != nil {
                out.append(keyword)
                seen.insert(keyword)
            }
        }
        return out
    }

    /// Every food keyword the emoji table knows, de-duplicated, in table
    /// order (specific phrases first). Used as the "all foods" catalogue for
    /// quick searches such as the Snack picker.
    static let allKeywords: [String] = {
        var seen = Set<String>()
        return lookup.compactMap { seen.insert($0.0).inserted ? $0.0 : nil }
    }()

    /// A short, varied rotation of food emojis for decorative cycling
    /// (e.g. the shopping list's add button).
    static let showcase: [String] = [
        "🍎", "🥕", "🧀", "🍞", "🥦", "🍗", "🥛", "🍌",
        "🍅", "🥚", "🐟", "🍓", "🥑", "🍚", "🌽", "🍇"
    ]

    // Ordered: specific phrases before their component words
    private static let lookup: [(String, String)] = [

        // ── Snacks ───────────────────────────────────────────────────────────
        // Listed first: branded snack names usually carry a flavour word
        // ("Doritos Chilli Heatwave", "Salt & Vinegar") that would otherwise
        // win the contains-order scan and label the product as that flavour.
        ("chocolate chips", "🍫"), ("chocolate chip", "🍫"), ("choc chips", "🍫"),
        ("corn chips", "🌽"), ("tortilla chips", "🌽"), ("doritos", "🌽"), ("nachos", "🌽"),
        ("potato chips", "🥔"), ("crisps", "🥔"), ("chips", "🥔"),
        ("popcorn", "🍿"), ("pretzel", "🥨"),
        ("rice cracker", "🍘"), ("cracker", "🍘"),

        // ── Proteins ─────────────────────────────────────────────────────────
        ("chicken breast", "🍗"), ("chicken thigh", "🍗"), ("chicken wing", "🍗"),
        ("chicken", "🍗"), ("turkey", "🦃"), ("duck", "🦆"),
        ("beef mince", "🥩"), ("ground beef", "🥩"), ("mince", "🥩"),
        ("steak", "🥩"), ("beef", "🥩"), ("lamb", "🍖"),
        ("pork belly", "🥩"), ("pork chop", "🥩"), ("pork", "🥩"),
        ("bacon", "🥓"), ("ham", "🍖"), ("sausage", "🌭"),
        ("salmon", "🐟"), ("tuna", "🐟"), ("cod", "🐟"),
        ("tilapia", "🐟"), ("snapper", "🐟"), ("hoki", "🐟"),
        ("trout", "🐟"), ("anchovy", "🐟"), ("sardine", "🐟"),
        ("fish fillet", "🐟"), ("fish", "🐟"),
        ("prawn", "🦐"), ("shrimp", "🦐"),
        ("crab", "🦀"), ("lobster", "🦞"),
        ("mussel", "🦪"), ("oyster", "🦪"), ("scallop", "🦪"), ("clam", "🦪"),
        ("squid", "🦑"), ("calamari", "🦑"), ("octopus", "🐙"),
        ("tofu", "🫘"), ("tempeh", "🫘"),
        ("egg white", "🥚"), ("egg yolk", "🥚"), ("egg", "🥚"),

        // ── Vegetables ───────────────────────────────────────────────────────
        ("sweet potato", "🍠"), ("potato", "🥔"),
        ("cherry tomato", "🍅"), ("tomato paste", "🍅"),
        ("tomato sauce", "🍅"), ("tomato", "🍅"),
        ("spring onion", "🧅"), ("red onion", "🧅"),
        ("white onion", "🧅"), ("onion", "🧅"),
        ("garlic clove", "🧄"), ("garlic", "🧄"),
        ("carrot", "🥕"), ("broccoli", "🥦"), ("cauliflower", "🥦"),
        ("asparagus", "🥦"), ("celery", "🥦"),
        ("spinach", "🥬"), ("kale", "🥬"), ("bok choy", "🥬"),
        ("silverbeet", "🥬"), ("chard", "🥬"),
        ("lettuce", "🥬"), ("cabbage", "🥬"), ("chinese cabbage", "🥬"),
        ("capsicum", "🫑"), ("bell pepper", "🫑"),
        ("red pepper", "🫑"), ("green pepper", "🫑"),
        ("chilli", "🌶️"), ("chili", "🌶️"), ("jalapeño", "🌶️"), ("jalapen", "🌶️"),
        ("cucumber", "🥒"), ("zucchini", "🥒"), ("courgette", "🥒"),
        ("corn", "🌽"), ("sweetcorn", "🌽"),
        ("mushroom", "🍄"), ("porcini", "🍄"), ("shiitake", "🍄"),
        ("portobello", "🍄"), ("enoki", "🍄"),
        ("peas", "🟢"), ("pea", "🟢"), ("edamame", "🫘"),
        ("green bean", "🫘"), ("broad bean", "🫘"),
        ("eggplant", "🍆"), ("aubergine", "🍆"),
        ("pumpkin", "🎃"), ("butternut squash", "🎃"), ("squash", "🎃"),
        ("avocado", "🥑"), ("leek", "🥬"),
        ("beetroot", "🫐"), ("beet", "🫐"),
        ("artichoke", "🥦"), ("fennel", "🌱"),
        ("radish", "🌱"), ("turnip", "🌱"), ("parsnip", "🌱"),
        ("celeriac", "🌱"), ("kohlrabi", "🌱"),
        ("watercress", "🌿"), ("rocket", "🌿"), ("arugula", "🌿"),
        ("baby spinach", "🥬"), ("mixed greens", "🥬"),

        // ── Fruits ───────────────────────────────────────────────────────────
        ("green apple", "🍏"), ("red apple", "🍎"), ("apple", "🍎"),
        ("banana", "🍌"), ("orange", "🍊"), ("mandarin", "🍊"), ("clementine", "🍊"),
        ("lemon", "🍋"), ("lime", "🍋"), ("grapefruit", "🍊"),
        ("mango", "🥭"), ("pineapple", "🍍"), ("papaya", "🥭"),
        ("watermelon", "🍉"), ("rockmelon", "🍈"), ("cantaloupe", "🍈"),
        ("honeydew", "🍈"), ("melon", "🍈"),
        ("grape", "🍇"), ("strawberry", "🍓"),
        ("blueberry", "🫐"), ("raspberry", "🍓"),
        ("blackberry", "🍇"), ("boysenberry", "🍇"),
        ("pear", "🍐"), ("peach", "🍑"), ("nectarine", "🍑"),
        ("plum", "🍑"), ("apricot", "🍑"),
        ("cherry", "🍒"), ("kiwi", "🥝"),
        ("pomegranate", "🍎"), ("fig", "🍑"), ("date", "🍑"),
        ("coconut", "🥥"), ("passion fruit", "🍊"), ("tamarillo", "🍅"),
        ("feijoa", "🍎"), ("guava", "🍊"), ("lychee", "🍊"),
        ("jackfruit", "🍈"), ("durian", "🍈"),
        ("mixed fruit", "🍓"), ("berries", "🫐"),

        // ── Dairy ────────────────────────────────────────────────────────────
        ("cream cheese", "🧀"), ("sour cream", "🥛"),
        ("double cream", "🥛"), ("heavy cream", "🥛"), ("whipping cream", "🥛"),
        ("milk", "🥛"), ("buttermilk", "🥛"),
        ("butter", "🧈"), ("ghee", "🧈"),
        ("cheddar", "🧀"), ("mozzarella", "🧀"), ("parmesan", "🧀"),
        ("feta", "🧀"), ("brie", "🧀"), ("camembert", "🧀"),
        ("gouda", "🧀"), ("gruyère", "🧀"), ("gruyere", "🧀"),
        ("ricotta", "🧀"), ("mascarpone", "🧀"), ("cottage cheese", "🧀"),
        ("halloumi", "🧀"), ("cheese", "🧀"),
        ("greek yogurt", "🥛"), ("yoghurt", "🥛"), ("yogurt", "🥛"),
        ("ice cream", "🍦"), ("gelato", "🍦"),
        ("custard", "🍮"), ("cream", "🥛"),

        // ── Grains & Bread ───────────────────────────────────────────────────
        ("white rice", "🍚"), ("brown rice", "🍚"), ("jasmine rice", "🍚"),
        ("basmati rice", "🍚"), ("rice", "🍚"),
        ("pasta", "🍝"), ("spaghetti", "🍝"), ("penne", "🍝"),
        ("fettuccine", "🍝"), ("linguine", "🍝"), ("fusilli", "🍝"),
        ("lasagne", "🍝"), ("lasagna", "🍝"),
        ("udon", "🍜"), ("ramen", "🍜"), ("soba", "🍜"), ("noodle", "🍜"),
        ("sourdough", "🍞"), ("baguette", "🥖"), ("bread", "🍞"),
        ("pita", "🫓"), ("tortilla", "🫓"), ("wrap", "🫓"),
        ("bagel", "🥯"), ("croissant", "🥐"),
        ("flour", "🌾"), ("plain flour", "🌾"), ("self-raising flour", "🌾"),
        ("oat", "🌾"), ("rolled oats", "🌾"),
        ("quinoa", "🌾"), ("couscous", "🌾"), ("barley", "🌾"),
        ("wheat", "🌾"), ("semolina", "🌾"),
        ("breadcrumb", "🍞"), ("panko", "🍞"),
        ("polenta", "🌽"), ("cornmeal", "🌽"),

        // ── Pantry & Sauces ──────────────────────────────────────────────────
        ("olive oil", "🫒"), ("sesame oil", "🫙"), ("vegetable oil", "🫙"),
        ("coconut oil", "🥥"), ("canola oil", "🫙"), ("oil", "🫙"),
        ("balsamic vinegar", "🍶"), ("apple cider vinegar", "🍶"), ("vinegar", "🍶"),
        ("soy sauce", "🍶"), ("fish sauce", "🍶"), ("worcestershire", "🍶"),
        ("oyster sauce", "🍶"), ("hoisin", "🍶"), ("tamari", "🍶"),
        ("hot sauce", "🌶️"), ("sriracha", "🌶️"), ("tabasco", "🌶️"),
        ("tomato paste", "🍅"), ("tomato ketchup", "🍅"), ("ketchup", "🍅"),
        ("mustard", "🌭"), ("dijon", "🌭"),
        ("mayonnaise", "🥚"), ("mayo", "🥚"), ("aioli", "🥚"),
        ("honey", "🍯"), ("maple syrup", "🍯"), ("golden syrup", "🍯"),
        ("white sugar", "🍬"), ("brown sugar", "🍬"), ("caster sugar", "🍬"),
        ("icing sugar", "🍬"), ("sugar", "🍬"),
        ("salt", "🧂"), ("sea salt", "🧂"), ("rock salt", "🧂"),
        ("black pepper", "🌶️"), ("white pepper", "🌶️"), ("pepper", "🌶️"),
        ("paprika", "🌶️"), ("cayenne", "🌶️"), ("chilli powder", "🌶️"),
        ("cinnamon", "🫚"), ("turmeric", "🫚"), ("cumin", "🫚"),
        ("coriander powder", "🫚"), ("garam masala", "🫚"),
        ("curry powder", "🫚"), ("curry paste", "🫚"),
        ("five spice", "🫚"), ("star anise", "🫚"), ("cardamom", "🫚"),
        ("clove", "🫚"), ("nutmeg", "🫚"), ("allspice", "🫚"),
        ("smoked paprika", "🌶️"),
        ("ginger", "🫚"), ("ground ginger", "🫚"),
        ("vanilla extract", "🫙"), ("vanilla", "🫙"),
        ("baking powder", "🫙"), ("baking soda", "🫙"),
        ("bicarbonate", "🫙"), ("yeast", "🫙"),
        ("cornflour", "🌽"), ("cornstarch", "🌽"),
        ("cocoa powder", "🍫"), ("cocoa", "🍫"),
        ("dark chocolate", "🍫"), ("milk chocolate", "🍫"),
        ("white chocolate", "🍫"), ("chocolate", "🍫"),
        ("tahini", "🫙"), ("miso", "🫙"),
        ("peanut butter", "🥜"), ("almond butter", "🌰"),
        ("jam", "🍓"), ("marmalade", "🍊"), ("chutney", "🫙"),
        ("stock", "🫙"), ("broth", "🫙"), ("bouillon", "🫙"),
        ("coconut milk", "🥥"), ("coconut cream", "🥥"),
        ("passata", "🍅"), ("canned tomato", "🍅"), ("tinned tomato", "🍅"),
        ("condensed milk", "🥛"), ("evaporated milk", "🥛"),
        ("lard", "🧈"), ("shortening", "🧈"),

        // ── Herbs ────────────────────────────────────────────────────────────
        ("fresh basil", "🌿"), ("basil", "🌿"),
        ("flat leaf parsley", "🌿"), ("curly parsley", "🌿"), ("parsley", "🌿"),
        ("fresh coriander", "🌿"), ("coriander", "🌿"), ("cilantro", "🌿"),
        ("mint", "🌿"), ("peppermint", "🌿"), ("spearmint", "🌿"),
        ("rosemary", "🌿"), ("thyme", "🌿"), ("oregano", "🌿"),
        ("sage", "🌿"), ("dill", "🌿"), ("chive", "🌿"),
        ("tarragon", "🌿"), ("bay leaf", "🌿"), ("bay leaves", "🌿"),
        ("lemongrass", "🌿"), ("kaffir lime", "🍋"), ("makrut", "🍋"),

        // ── Nuts & Seeds ─────────────────────────────────────────────────────
        ("almond", "🌰"), ("walnut", "🌰"), ("cashew", "🌰"),
        ("pistachio", "🌰"), ("hazelnut", "🌰"), ("pecan", "🌰"),
        ("macadamia", "🌰"), ("brazil nut", "🌰"), ("pine nut", "🌰"),
        ("peanut", "🥜"),
        ("sesame seed", "🌱"), ("sesame", "🌱"),
        ("chia seed", "🌱"), ("chia", "🌱"),
        ("flaxseed", "🌱"), ("linseed", "🌱"),
        ("sunflower seed", "🌱"), ("pumpkin seed", "🌱"),
        ("poppy seed", "🌱"),
        ("mixed nuts", "🌰"),

        // ── Legumes ──────────────────────────────────────────────────────────
        ("chickpea", "🫘"), ("lentil", "🫘"),
        ("black bean", "🫘"), ("kidney bean", "🫘"),
        ("cannellini", "🫘"), ("navy bean", "🫘"),
        ("black-eyed pea", "🫘"), ("split pea", "🫘"),
        ("butter bean", "🫘"), ("borlotti", "🫘"),
        ("soybean", "🫘"), ("bean", "🫘"),

        // ── Baking ───────────────────────────────────────────────────────────
        ("cake", "🎂"), ("cupcake", "🧁"), ("muffin", "🧁"),
        ("cookie", "🍪"), ("biscuit", "🍪"),
        ("pastry", "🥐"), ("waffle", "🧇"), ("pancake", "🥞"),
        ("tart", "🥧"), ("pie", "🥧"), ("crumble", "🥧"),
        ("cheesecake", "🎂"), ("brownie", "🍫"), ("fudge", "🍫"),
        ("doughnut", "🍩"), ("donut", "🍩"),
        ("meringue", "🍮"), ("pavlova", "🍮"),
        ("gelatin", "🫙"), ("gelatine", "🫙"),

        // ── Drinks (sometimes in fridge) ─────────────────────────────────────
        ("orange juice", "🧃"), ("apple juice", "🧃"), ("juice", "🧃"),
        ("red wine", "🍷"), ("white wine", "🍾"), ("wine", "🍷"),
        ("beer", "🍺"), ("cider", "🍺"),
        ("coffee", "☕"), ("espresso", "☕"),
        ("tea", "🍵"), ("green tea", "🍵"),
        ("sparkling water", "💧"), ("water", "💧"),

        // ── Miscellaneous ────────────────────────────────────────────────────
        ("mixed herb", "🌿"), ("herb", "🌿"),
        ("spice", "🫚"), ("seasoning", "🫚"),
        ("sauce", "🫙"), ("dressing", "🫙"),
        ("soup", "🍲"), ("stew", "🍲"),
        ("salad", "🥗"), ("coleslaw", "🥗"),
    ]
}
