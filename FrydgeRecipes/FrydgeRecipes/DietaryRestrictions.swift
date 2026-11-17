//
//  DietaryRestrictions.swift
//  FrydgeRecipes
//
//  The user's own list of ingredients they can't eat (allergies, medical) or
//  would rather avoid (taste, ethics, "no palm oil"). Lives alongside the
//  coarse GF/DF/V/VG profile tags and extends them: those tags are folded in
//  as implicit "prefer not to" terms so a dairy-free person is warned about
//  milk without having to type it.
//
//  Everything that adds food — fridge, shopping list, barcode / fridge / link
//  scans — asks `DietaryRestrictionStore.shared.flags(...)` and shows what
//  matched. A match on the product name uses the shared IngredientMatcher
//  (so "cheddar" trips a "cheese" rule); a match in the ingredients list is a
//  whole-word search, which also catches additives written as E-numbers.
//

import Foundation

// MARK: - Model

struct DietaryRestriction: Identifiable, Codable, Hashable {
    enum Severity: String, Codable, CaseIterable, Identifiable {
        /// Allergy or medical: must not eat. Flagged as an error.
        case cannot
        /// Preference: would rather not. Flagged as a warning.
        case avoid

        var id: String { rawValue }

        var title: String {
            switch self {
            case .cannot: return "Can't eat"
            case .avoid: return "Prefer not to"
            }
        }

        var shortTitle: String {
            switch self {
            case .cannot: return "Can't"
            case .avoid: return "Avoid"
            }
        }
    }

    var id: UUID = UUID()
    /// What to look for: "peanuts", "palm oil", "E621", "cow's milk".
    var term: String
    var severity: Severity
    /// Optional context shown in the editor: "anaphylaxis", "migraines".
    var note: String = ""

    var displayTerm: String {
        term.trimmingCharacters(in: .whitespacesAndNewlines).localizedCapitalized
    }
}

/// One restriction that matched a product, with where it was found.
struct DietaryFlag: Identifiable, Hashable {
    enum Evidence: Hashable {
        /// The product name itself matched.
        case name
        /// The term appeared in the ingredients list; `snippet` is the
        /// ingredient line it was found in.
        case ingredients(snippet: String)
    }

    let term: String
    let severity: DietaryRestriction.Severity
    let evidence: Evidence
    /// Non-nil when the flag comes from a profile tag (GF/DF/V/VG) rather
    /// than a restriction the user typed: "Dairy-free".
    let impliedBy: String?

    var id: String { "\(term)|\(severity.rawValue)|\(impliedBy ?? "")" }
    var isBlocking: Bool { severity == .cannot }

    /// "Contains peanuts" / "Lists milk powder in its ingredients".
    var headline: String {
        switch evidence {
        case .name:
            return "Contains \(term)"
        case .ingredients(let snippet):
            return snippet.lowercased() == term.lowercased()
                ? "Lists \(term) in its ingredients"
                : "Lists \(snippet) in its ingredients"
        }
    }

    /// Why it matters: "You said you can't eat this" / "Dairy-free preference".
    var reason: String {
        if let impliedBy { return "\(impliedBy) preference" }
        return severity == .cannot ? "You said you can't eat this" : "You said you'd rather avoid this"
    }
}

// MARK: - Matching

enum DietaryRestrictionMatcher {

    /// Flags for one product. `name` is matched by food family as well as by
    /// word; `ingredientsText` (an Open Food Facts style comma list) by word.
    static func flags(
        name: String,
        ingredientsText: String?,
        restrictions: [DietaryRestriction],
        impliedTerms: [(term: String, impliedBy: String)] = []
    ) -> [DietaryFlag] {
        var out: [DietaryFlag] = []
        var seenTerms: Set<String> = []

        func consider(term: String, severity: DietaryRestriction.Severity, impliedBy: String?) {
            let cleanTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTerm.isEmpty else { return }
            let key = cleanTerm.lowercased()
            guard !seenTerms.contains(key) else { return }

            if nameMatches(term: cleanTerm, name: name) {
                seenTerms.insert(key)
                out.append(DietaryFlag(term: key, severity: severity, evidence: .name, impliedBy: impliedBy))
                return
            }
            if let snippet = ingredientSnippet(containing: cleanTerm, in: ingredientsText) {
                seenTerms.insert(key)
                out.append(DietaryFlag(term: key, severity: severity, evidence: .ingredients(snippet: snippet), impliedBy: impliedBy))
            }
        }

        // Explicit rules first so a typed "milk (can't)" wins over the DF tag.
        for r in restrictions where r.severity == .cannot { consider(term: r.term, severity: .cannot, impliedBy: nil) }
        for r in restrictions where r.severity == .avoid { consider(term: r.term, severity: .avoid, impliedBy: nil) }
        for implied in impliedTerms { consider(term: implied.term, severity: .avoid, impliedBy: implied.impliedBy) }

        // Blocking flags first, then in the order they were declared.
        return out.sorted { a, b in
            if a.isBlocking != b.isBlocking { return a.isBlocking }
            return false
        }
    }

    /// Whole-word match of `term` against the product name, or a food-family
    /// match through IngredientMatcher ("brie" ↔ "cheese"). E-numbers are
    /// matched as words only; the family matcher doesn't know them.
    static func nameMatches(term: String, name: String) -> Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if wordRegex(for: term)?.firstMatch(in: normalize(name), range: fullRange(normalize(name))) != nil {
            return true
        }
        if isAdditiveCode(term) { return false }
        return IngredientMatcher.matches(term, name)
    }

    /// The ingredient entry (between commas / brackets) that contains `term`.
    static func ingredientSnippet(containing term: String, in ingredientsText: String?) -> String? {
        guard let raw = ingredientsText?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let regex = wordRegex(for: term) else { return nil }

        let pieces = raw
            .components(separatedBy: CharacterSet(charactersIn: ",;()[].:"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for piece in pieces {
            let normalized = normalize(piece)
            if regex.firstMatch(in: normalized, range: fullRange(normalized)) != nil {
                // Strip percentages and asterisks so the snippet reads cleanly.
                let cleaned = piece
                    .replacingOccurrences(of: #"\s*\d+([.,]\d+)?\s*%"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "*", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.isEmpty ? piece : cleaned
            }
        }
        return nil
    }

    // MARK: Helpers

    /// Lowercased, diacritics folded, punctuation collapsed to spaces so
    /// "Cow's Milk", "cows milk" and "COW’S MILK" all compare equal.
    static func normalize(_ s: String) -> String {
        // Apostrophes vanish rather than split ("cow's" → "cows") so a label's
        // "COWS MILK" matches a typed "cow's milk".
        let noApostrophes = s.replacingOccurrences(of: #"['’`]"#, with: "", options: .regularExpression)
        let folded = noApostrophes.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        return String(scalars)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func isAdditiveCode(_ term: String) -> Bool {
        normalize(term).range(of: #"^e ?\d{3,4}[a-z]?$"#, options: .regularExpression) != nil
    }

    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    /// Whole-word pattern for a term, tolerant of plurals ("peanut" ↔
    /// "peanuts", "tomato" ↔ "tomatoes") and E-number spacing ("E621" ↔
    /// "e 621"). Multi-word terms match as a phrase.
    static func wordRegex(for term: String) -> NSRegularExpression? {
        let normalized = normalize(term)
        guard !normalized.isEmpty else { return nil }
        if let cached = regexCache.object(forKey: normalized as NSString) { return cached }

        let pattern: String
        if isAdditiveCode(normalized) {
            // "e621", "e 621", "621", "e150d" → the code without its E prefix.
            let code = normalized.replacingOccurrences(of: #"^e ?"#, with: "", options: .regularExpression)
            // Labels write "E621", "E 621" or just "621".
            pattern = #"\b(?:e ?)?"# + NSRegularExpression.escapedPattern(for: code) + #"\b"#
        } else {
            // Every word tolerates a plural so "cow's milk" also finds "cows milk".
            let parts = normalized.split(separator: " ").map { word in
                NSRegularExpression.escapedPattern(for: stem(String(word))) + "(e?s)?"
            }
            pattern = #"\b"# + parts.joined(separator: #"\s+"#) + #"\b"#
        }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        regexCache.setObject(regex, forKey: normalized as NSString)
        return regex
    }

    /// "peanuts" → "peanut", "tomatoes" → "tomato", "glass" stays "glass".
    private static func stem(_ word: String) -> String {
        guard word.count > 3 else { return word }
        if word.hasSuffix("oes") { return String(word.dropLast(2)) }
        if word.hasSuffix("ss") { return word }
        if word.hasSuffix("s") { return String(word.dropLast()) }
        return word
    }

    private static func fullRange(_ s: String) -> NSRange {
        NSRange(s.startIndex..., in: s)
    }
}

// MARK: - Store

/// Persists the restriction list (as a JSON string so ProfileCloudSync can
/// mirror it through iCloud's key-value store) and answers "is this food a
/// problem for me?" for every add path in the app.
@MainActor
final class DietaryRestrictionStore: ObservableObject {

    static let shared = DietaryRestrictionStore()

    /// Mirrored across devices by ProfileCloudSync, which is not main-actor
    /// bound; a constant string is safe to read from any isolation.
    nonisolated static let defaultsKey = "frydge.dietaryRestrictions.v1"
    /// The coarse GF/DF/V/VG profile tags (ProfileView).
    static let profileTagsKey = "frydge.profileDietary"

    @Published private(set) var restrictions: [DietaryRestriction] = []

    private let defaults = UserDefaults.standard
    private var isWriting = false

    private init() {
        restrictions = Self.load(from: defaults)
        // Pick up changes mirrored down from iCloud (ProfileCloudSync writes
        // straight into UserDefaults) without a relaunch.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isWriting else { return }
                let fresh = Self.load(from: self.defaults)
                if fresh != self.restrictions { self.restrictions = fresh }
            }
        }
    }

    // MARK: Editing

    var cannotEat: [DietaryRestriction] { restrictions.filter { $0.severity == .cannot } }
    var prefersToAvoid: [DietaryRestriction] { restrictions.filter { $0.severity == .avoid } }

    /// True when a rule for this term already exists (case-insensitive).
    func contains(term: String) -> Bool {
        let key = DietaryRestrictionMatcher.normalize(term)
        return restrictions.contains { DietaryRestrictionMatcher.normalize($0.term) == key }
    }

    /// Adds a rule, or upgrades an existing one to "can't eat" if that is
    /// stricter than what's there. Returns false when nothing changed.
    @discardableResult
    func add(term: String, severity: DietaryRestriction.Severity, note: String = "") -> Bool {
        let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        let key = DietaryRestrictionMatcher.normalize(clean)
        if let idx = restrictions.firstIndex(where: { DietaryRestrictionMatcher.normalize($0.term) == key }) {
            guard severity == .cannot, restrictions[idx].severity == .avoid else { return false }
            restrictions[idx].severity = .cannot
            if !note.isEmpty { restrictions[idx].note = note }
            persist()
            return true
        }
        restrictions.append(DietaryRestriction(term: clean, severity: severity, note: note))
        persist()
        return true
    }

    func update(_ restriction: DietaryRestriction) {
        guard let idx = restrictions.firstIndex(where: { $0.id == restriction.id }) else { return }
        restrictions[idx] = restriction
        persist()
    }

    func remove(_ restriction: DietaryRestriction) {
        restrictions.removeAll { $0.id == restriction.id }
        persist()
    }

    func remove(term: String) {
        let key = DietaryRestrictionMatcher.normalize(term)
        restrictions.removeAll { DietaryRestrictionMatcher.normalize($0.term) == key }
        persist()
    }

    // MARK: Checking

    /// Everything that matches `name` / its ingredients, blocking flags first.
    func flags(forName name: String, ingredientsText: String? = nil) -> [DietaryFlag] {
        guard !restrictions.isEmpty || !impliedTerms.isEmpty else { return [] }
        return DietaryRestrictionMatcher.flags(
            name: name,
            ingredientsText: ingredientsText,
            restrictions: restrictions,
            impliedTerms: impliedTerms
        )
    }

    /// Where an item was just added, for the banner copy.
    enum Destination {
        case fridge, shoppingList

        var label: String {
            switch self {
            case .fridge: return "your fridge"
            case .shoppingList: return "your shopping list"
            }
        }
    }

    /// Called by FrydgeManager / ShoppingListManager after an add. Shows the
    /// app-wide banner when the item hits a restriction, so every entry path
    /// (manual, Siri, receipt / list / fridge scans, recipe "add missing")
    /// warns without each screen having to remember to.
    func notifyIfFlagged(name: String, ingredientsText: String? = nil, addedTo destination: Destination) {
        let found = flags(forName: name, ingredientsText: ingredientsText)
        guard let top = found.first else { return }

        let others = found.count - 1
        let title = others > 0 ? "\(top.headline) (+\(others) more)" : top.headline
        let message = "\(top.reason). \(name.localizedCapitalized) was still added to \(destination.label)."

        NotificationCenter.default.post(
            name: .showInAppBanner,
            object: nil,
            userInfo: [
                "title": title,
                "body": message,
                "systemImage": top.isBlocking ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill",
                "style": top.isBlocking ? "error" : "warning"
            ]
        )
    }

    // MARK: Implied terms from the GF/DF/V/VG tags

    /// What each coarse profile tag means in ingredient terms. Deliberately
    /// the obvious culprits only; the user can add anything more specific.
    static let impliedTermsByTag: [String: (label: String, terms: [String])] = [
        "DF": ("Dairy-free", ["milk", "cheese", "butter", "cream", "yoghurt", "whey", "casein", "lactose", "ghee"]),
        "GF": ("Gluten-free", ["wheat", "gluten", "barley", "rye", "spelt", "semolina", "couscous", "bulgur", "malt"]),
        "V": ("Vegetarian", ["beef", "pork", "lamb", "chicken", "bacon", "ham", "fish", "prawns", "gelatine", "anchovies"]),
        "VG": ("Vegan", ["beef", "pork", "lamb", "chicken", "bacon", "ham", "fish", "prawns", "gelatine", "anchovies",
                         "milk", "cheese", "butter", "cream", "yoghurt", "whey", "casein", "egg", "honey"])
    ]

    private var impliedTerms: [(term: String, impliedBy: String)] {
        let csv = defaults.string(forKey: Self.profileTagsKey) ?? ""
        var out: [(String, String)] = []
        var seen: Set<String> = []
        for tag in csv.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) }) {
            guard let entry = Self.impliedTermsByTag[tag] else { continue }
            for term in entry.terms where !seen.contains(term) {
                seen.insert(term)
                out.append((term, entry.label))
            }
        }
        return out
    }

    // MARK: Presets

    /// The common allergens most labelling laws require to be declared, as
    /// one-tap chips in the editor and during first-run profile setup.
    static let commonAllergens: [String] = [
        "Peanuts", "Tree nuts", "Milk", "Eggs", "Wheat", "Gluten", "Soy", "Fish",
        "Shellfish", "Sesame", "Sulphites", "Celery", "Mustard", "Lupin"
    ]

    /// Things people often choose to avoid, offered under the allergen chips.
    static let commonAvoids: [String] = [
        "Palm oil", "MSG", "Aspartame", "Added sugar", "Alcohol", "Pork", "Beef", "Caffeine"
    ]

    // MARK: Persistence

    private static func load(from defaults: UserDefaults) -> [DietaryRestriction] {
        guard let json = defaults.string(forKey: defaultsKey), let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([DietaryRestriction].self, from: data) else { return [] }
        return list
    }

    private func persist() {
        isWriting = true
        defer { isWriting = false }
        // An empty list is written as "[]" rather than removed: ProfileCloudSync
        // only mirrors non-empty strings, so clearing the list still syncs.
        guard let data = try? JSONEncoder().encode(restrictions), let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: Self.defaultsKey)
    }
}
