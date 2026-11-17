import SwiftUI

// MARK: - Recipe category

/// Coarse "what's the main protein" grouping used for the recipe book's
/// colour-coded sections and side tabs.
enum RecipeCategory: String, CaseIterable, Identifiable, Hashable {
    case chicken
    case beef
    case pork
    case lamb
    case seafood
    case veggie
    case sweet
    case snacking

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chicken:  return "Chicken"
        case .beef:     return "Beef"
        case .pork:     return "Pork"
        case .lamb:     return "Lamb"
        case .seafood:  return "Seafood"
        case .veggie:   return "Veggie"
        case .sweet:    return "Sweet"
        case .snacking: return "Snacking"
        }
    }

    var emoji: String {
        switch self {
        case .chicken:  return "🐔"
        case .beef:     return "🐄"
        case .pork:     return "🐖"
        case .lamb:     return "🐑"
        case .seafood:  return "🐟"
        case .veggie:   return "🥕"
        case .sweet:    return "🍰"
        case .snacking: return "🍿"
        }
    }

    /// Tab / heading colour. Chosen to read on both the dark recipe background
    /// and over card imagery.
    var color: Color {
        switch self {
        case .chicken:  return Color(red: 0.98, green: 0.72, blue: 0.22)
        case .beef:     return Color(red: 0.86, green: 0.28, blue: 0.28)
        case .pork:     return Color(red: 0.95, green: 0.58, blue: 0.68)
        case .lamb:     return Color(red: 0.62, green: 0.48, blue: 0.82)
        case .seafood:  return Color(red: 0.30, green: 0.62, blue: 0.90)
        case .veggie:   return Color(red: 0.40, green: 0.72, blue: 0.40)
        case .sweet:    return Color(red: 0.72, green: 0.48, blue: 0.30)
        case .snacking: return Color(red: 0.93, green: 0.78, blue: 0.30)
        }
    }

    /// Position in `allCases`; used to keep sections and tabs in book order.
    var sortOrder: Int {
        RecipeCategory.allCases.firstIndex(of: self) ?? 0
    }

    // MARK: Classification

    /// Order matters when one ingredient line mentions two proteins:
    /// "lamb mince" is lamb, "pork sausage" is pork, plain "mince" is beef.
    private static let meatOrder: [RecipeCategory] = [.chicken, .lamb, .pork, .seafood, .beef]

    private static let meatKeywords: [RecipeCategory: Set<String>] = [
        .chicken: ["chicken", "poultry", "turkey", "duck", "drumstick"],
        .lamb:    ["lamb", "mutton", "hogget"],
        .pork:    ["pork", "bacon", "ham", "sausage", "prosciutto", "chorizo", "pancetta", "salami", "pepperoni"],
        .seafood: ["fish", "salmon", "tuna", "cod", "snapper", "hoki", "prawn", "shrimp", "crab", "lobster",
                   "mussel", "oyster", "scallop", "squid", "calamari", "octopus", "anchovy", "sardine", "trout",
                   "tilapia", "seafood", "clam", "kingfish", "tarakihi", "gurnard"],
        .beef:    ["beef", "steak", "mince", "sirloin", "brisket", "ribeye", "rump", "oxtail", "veal"]
    ]

    private static let sweetKeywords: Set<String> = [
        "cake", "cookie", "biscuit", "brownie", "dessert", "pudding", "chocolate", "muffin", "pancake",
        "waffle", "icing", "caramel", "custard", "cupcake", "tart", "fudge", "scone", "cheesecake",
        "meringue", "vanilla", "cocoa", "sugar", "syrup", "jam"
    ]

    /// Savoury between-meals food rather than sweet treats: dips, nibbles,
    /// finger food. Single words only — matched against the same tokenizer
    /// that strips trailing "s" (so "nachos" / "crisps" still match).
    private static let snackKeywords: Set<String> = [
        "dip", "hummus", "guacamole", "popcorn", "chip", "crisp", "cracker", "pretzel", "nacho",
        "salsa", "granola", "bruschetta", "nut", "jerky", "snack"
    ]

    /// Ingredient lines that mention a protein without being the protein
    /// (fish sauce, chicken stock, beef gravy powder ...).
    private static let ignoredIngredientTerms: Set<String> = [
        "sauce", "stock", "broth", "powder", "seasoning", "flavour", "flavor", "gravy", "cube"
    ]

    static func classify(_ recipe: CloudRecipe) -> RecipeCategory {
        var scores: [RecipeCategory: Int] = [:]

        // The title carries the most weight: "Beef Stew" is beef even when it
        // lists chicken stock.
        let nameTokens = tokens(in: recipe.name)
        for category in meatOrder where !nameTokens.isDisjoint(with: meatKeywords[category] ?? []) {
            scores[category, default: 0] += 3
        }

        var sweetScore = nameTokens.isDisjoint(with: sweetKeywords) ? 0 : 3
        var snackScore = nameTokens.isDisjoint(with: snackKeywords) ? 0 : 3

        for raw in recipe.ingredients {
            let lineTokens = tokens(in: raw)
            if !lineTokens.isDisjoint(with: sweetKeywords) { sweetScore += 1 }
            if !lineTokens.isDisjoint(with: snackKeywords) { snackScore += 1 }

            guard lineTokens.isDisjoint(with: ignoredIngredientTerms) else { continue }
            if let category = meatOrder.first(where: { !lineTokens.isDisjoint(with: meatKeywords[$0] ?? []) }) {
                scores[category, default: 0] += 1
            }
        }

        // Highest meat score wins; ties fall to the earlier case in `allCases`.
        var best: RecipeCategory?
        var bestScore = 0
        for category in RecipeCategory.allCases where (scores[category] ?? 0) > bestScore {
            best = category
            bestScore = scores[category] ?? 0
        }
        if let best { return best }

        // No protein in the running: sweet treat, savoury snack, or veggie
        // main. Ties fall to sweet, matching the existing fallback.
        if sweetScore >= 2 && sweetScore >= snackScore { return .sweet }
        if snackScore >= 2 { return .snacking }
        return .veggie
    }

    /// Lowercased word tokens plus naive singular forms, so "prawns" matches
    /// "prawn" and "anchovies" matches "anchovy".
    private static func tokens(in text: String) -> Set<String> {
        var out = Set<String>()
        let words = text.lowercased().split { !$0.isLetter }
        for word in words {
            let w = String(word)
            out.insert(w)
            if w.hasSuffix("ies"), w.count > 4 {
                out.insert(String(w.dropLast(3)) + "y")
            }
            if w.hasSuffix("es"), w.count > 4 {
                out.insert(String(w.dropLast(2)))
            }
            if w.hasSuffix("s"), w.count > 3 {
                out.insert(String(w.dropLast()))
            }
        }
        return out
    }
}

// MARK: - Side tab rail

/// Book-style tab ends pinned to the trailing edge of the recipe list. Each tab
/// is one category; tapping it jumps to that section.
struct RecipeCategoryTabRail: View {
    let categories: [RecipeCategory]
    let selected: RecipeCategory?
    let onSelect: (RecipeCategory) -> Void

    /// Horizontal room the rail needs so list content can leave it clear.
    static let width: CGFloat = 46

    private static let tabShape = UnevenRoundedRectangle(
        topLeadingRadius: 10,
        bottomLeadingRadius: 10,
        bottomTrailingRadius: 0,
        topTrailingRadius: 0,
        style: .continuous
    )

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(categories) { category in
                tab(for: category)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
    }

    private func tab(for category: RecipeCategory) -> some View {
        let isSelected = category == selected

        return Button {
            onSelect(category)
        } label: {
            Text(category.emoji)
                .font(.system(size: 18))
                // A little drop shadow lifts the glyph off the tab surface.
                .shadow(color: .black.opacity(0.35), radius: 0.6, x: 0, y: 1)
                .opacity(isSelected ? 1 : 0.9)
                .frame(width: isSelected ? Self.width : Self.width - 8, height: 44)
                .background(embossedTab(for: category, isSelected: isSelected))
                .shadow(color: .black.opacity(isSelected ? 0.4 : 0.22), radius: isSelected ? 5 : 2, x: -2, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(category.title) recipes")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Raised, leather-index-tab look: lit from the top-left, shaded towards
    /// the bottom-right, with a soft inner shadow hugging the lower edge and a
    /// crisp highlight rim.
    private func embossedTab(for category: RecipeCategory, isSelected: Bool) -> some View {
        ZStack {
            Self.tabShape
                .fill(category.color.opacity(isSelected ? 1 : 0.72))

            // Directional light
            Self.tabShape
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.38), Color.clear, Color.black.opacity(0.22)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Inner shadow along the bottom / inner edge
            Self.tabShape
                .stroke(Color.black.opacity(0.45), lineWidth: 4)
                .blur(radius: 3)
                .offset(x: -1.5, y: 2)
                .mask(Self.tabShape)

            // Highlight rim
            Self.tabShape
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.75), Color.white.opacity(0.12), Color.black.opacity(0.25)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }
}

#Preview("Tab rail") {
    ZStack(alignment: .topTrailing) {
        Color(white: 0.13).ignoresSafeArea()
        RecipeCategoryTabRail(
            categories: RecipeCategory.allCases,
            selected: .beef,
            onSelect: { _ in }
        )
        .padding(.top, 40)
    }
}
