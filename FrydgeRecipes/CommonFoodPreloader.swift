import Foundation

/// Manages a 100-slot warm image cache.
/// On first launch it seeds from a curated base list.
/// On every subsequent run it rebuilds the list by putting the user's actual
/// fridge + shopping items first, then fills remaining slots from the base list
/// — so over time the cache reflects what this user actually needs.
enum CommonFoodPreloader {

    private static let versionKey = "commonFoodPreloadVersion"
    private static let currentVersion = 1

    // MARK: - Base list (100 common ingredients)

    static let baseFoods: [String] = [
        // Proteins
        "chicken", "beef", "pork", "salmon", "tuna", "eggs", "lamb",
        "turkey", "shrimp", "prawns", "bacon", "ham", "sausage",
        // Seafood
        "cod", "tilapia", "mussels", "crab",
        // Plant protein
        "tofu", "tempeh", "chickpeas", "lentils", "black beans", "kidney beans",
        // Vegetables
        "carrot", "potato", "onion", "garlic", "tomato", "broccoli", "spinach",
        "cucumber", "lettuce", "celery", "bell pepper", "mushroom", "corn",
        "peas", "sweet potato", "zucchini", "cauliflower", "cabbage", "kale",
        "avocado", "leek", "beetroot", "eggplant", "pumpkin", "asparagus",
        "bok choy", "green beans",
        // Fruits
        "apple", "banana", "orange", "strawberry", "lemon", "lime", "mango",
        "pineapple", "grapes", "blueberry", "watermelon", "pear", "kiwi",
        "peach", "raspberry",
        // Dairy
        "milk", "butter", "cheese", "yogurt", "cream", "sour cream",
        "cheddar", "mozzarella", "feta", "ricotta",
        // Grains & Carbs
        "rice", "pasta", "bread", "flour", "oats", "noodles", "quinoa",
        "couscous", "tortilla",
        // Pantry
        "olive oil", "soy sauce", "vinegar", "honey", "sugar",
        "sesame oil", "coconut milk", "tomato paste",
        // Herbs & Spices
        "basil", "parsley", "coriander", "ginger", "cinnamon", "paprika",
        "turmeric", "rosemary", "thyme", "oregano", "chili",
        // Nuts & Seeds
        "almonds", "walnuts", "cashews", "peanuts", "sesame seeds", "chia seeds",
    ]

    // MARK: - First-run flag

    static var needsInitialPreload: Bool {
        UserDefaults.standard.integer(forKey: versionKey) < currentVersion
    }

    static func markInitialPreloadDone() {
        UserDefaults.standard.set(currentVersion, forKey: versionKey)
    }

    // MARK: - Adaptive list builder

    /// Returns up to `limit` names to prefetch.
    /// User's own items fill slots first; the base list fills the rest.
    /// Items already covered by the user's list are dropped from the base list
    /// so the cache stays focused on what matters.
    static func preloadList(merging userItems: [String], limit: Int = 100) -> [String] {
        let userSet = Set(userItems.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        var result = Array(userSet)          // user items first (already de-duped)
        for food in baseFoods {
            guard result.count < limit else { break }
            if !userSet.contains(food) { result.append(food) }
        }
        return result
    }
}
