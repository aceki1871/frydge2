//
//  ProductNutritionCard.swift
//  FrydgeRecipes
//
//  One nutrition-first product detail block, shared by every place a product
//  is inspected: the fridge item detail sheet, the search-result preview in
//  the add flow, and the product found by a barcode scan or pasted link.
//  Keeping a single component means the three entry points can't drift.
//

import SwiftUI

// MARK: - Facts model

/// Product facts normalised from whichever source answered (Frydge products
/// DB / Open Food Facts, Edamam, or a scanned label).
struct ProductNutritionFacts: Equatable {
    enum Source: String {
        case productsDB = "Open Food Facts"
        case edamam = "Edamam"
        case label = "Label scan"
        /// Built-in per-100 g reference figures for a whole food (see
        /// `GenericNutrition`). Shown when no product record has numbers.
        case typical = "Typical values"
    }

    var source: Source?
    var brand: String?
    var quantity: String?
    var imageURL: URL?

    // Per 100 g / 100 ml
    var energyKcal: Double?
    var fat: Double?
    var saturatedFat: Double?
    var carbs: Double?
    var sugars: Double?
    var fibre: Double?
    var protein: Double?
    var salt: Double?

    var nutriScore: String?
    var nova: Int?
    /// Environmental rating from whichever source had one (see
    /// `EnvironmentalImpact`). Replaces the bare Eco-Score letter so the
    /// UI can show where the grade came from and the carbon figure behind it.
    var environmental: EnvironmentalImpact?
    var ingredientsText: String?
    /// Additive tags already parsed by Open Food Facts ("en:e412"). Merged
    /// with what we detect in the ingredients text ourselves.
    var additiveTags: [String] = []

    /// Three-state flags; nil means unknown and is never shown.
    var isVegan: Bool?
    var isVegetarian: Bool?
    var isGlutenFree: Bool?
    var isDairyFree: Bool?

    var hasNutrition: Bool { energyKcal != nil || fat != nil || carbs != nil || protein != nil }
    var hasFoodQuality: Bool { Self.letterGrade(nutriScore) != nil || nova != nil }
    var hasRatings: Bool { hasFoodQuality || environmental != nil }
    var hasDietary: Bool { isVegan != nil || isVegetarian != nil || isGlutenFree != nil || isDairyFree != nil }
    var hasIngredients: Bool { !(ingredientsText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isEmpty: Bool { !hasNutrition && !hasRatings && !hasIngredients }

    /// Additives recognised in the ingredients list plus OFF's tags, in
    /// label order. "Gum (412)", "E412" and "guar gum" all land on one row.
    var additives: [FoodAdditive] { FoodAdditives.merged(text: ingredientsText, tags: additiveTags) }

    init() {}

    init(product: FrydgeProduct) {
        source = .productsDB
        brand = product.brand?.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        quantity = product.quantity
        imageURL = (product.imageURL ?? product.imageSmallURL).flatMap(URL.init(string:))
        energyKcal = product.nutrition?.energyKcal100g
        fat = product.nutrition?.fat100g
        saturatedFat = product.nutrition?.saturatedFat100g
        carbs = product.nutrition?.carbohydrates100g
        sugars = product.nutrition?.sugars100g
        fibre = product.nutrition?.fiber100g
        protein = product.nutrition?.proteins100g
        salt = product.nutrition?.salt100g
        nutriScore = product.nutriscore
        nova = product.nova
        environmental = EnvironmentalImpact(grade: product.ecoscore, source: .ecoScore)
        ingredientsText = product.ingredientsText
        isVegan = product.dietary?.isVegan
        isVegetarian = product.dietary?.isVegetarian
        isGlutenFree = product.dietary?.isGlutenFree
        isDairyFree = product.dietary?.isDairyFree
    }

    init(product: OFFProduct) {
        source = .productsDB
        quantity = product.quantity
        imageURL = product.imageUrl.flatMap(URL.init(string:))
        energyKcal = product.nutriments?.energyKcal
        fat = product.nutriments?.fat
        carbs = product.nutriments?.carbs
        protein = product.nutriments?.proteins
        ingredientsText = product.ingredientsText
    }

    init(edamam: EdamamFoodResult) {
        source = .edamam
        imageURL = edamam.imageURL
        energyKcal = edamam.calories
        fat = edamam.fatG
        carbs = edamam.carbsG
        protein = edamam.proteinG
        fibre = edamam.fiberG
    }

    /// Normalises an OFF letter grade, nil for unknown / not applicable.
    static func letterGrade(_ raw: String?) -> String? {
        guard let g = raw?.lowercased().trimmingCharacters(in: .whitespaces),
              !g.isEmpty, g != "unknown", g != "not-applicable", g != "not-computed" else { return nil }
        return g
    }

    // MARK: Enrichment

    /// Fills in the ratings the Worker couldn't supply. With a barcode, asks
    /// Open Food Facts directly for its live Green-Score, carbon figure,
    /// Nutri-Score / NOVA and additive tags; then, if there is still no
    /// environmental grade, falls back to a typical-impact estimate for the
    /// kind of food. Never overwrites a value that is already present.
    func enriched(name: String, barcode: String?) async -> ProductNutritionFacts {
        var out = self
        let wantsScores = out.environmental == nil || Self.letterGrade(out.nutriScore) == nil || out.nova == nil
        if let code = barcode?.filter(\.isNumber), !code.isEmpty,
           wantsScores || out.additiveTags.isEmpty || out.environmental?.co2PerKg == nil,
           let extras = await OpenFoodFactsPublicAPI.shared.extras(for: code) {
            if out.environmental == nil {
                out.environmental = extras.environmental
            } else if out.environmental?.co2PerKg == nil, let kg = extras.co2PerKg {
                out.environmental?.co2PerKg = kg
            }
            if Self.letterGrade(out.nutriScore) == nil { out.nutriScore = extras.nutriScore }
            if out.nova == nil { out.nova = extras.nova }
            if out.additiveTags.isEmpty { out.additiveTags = extras.additiveTags }
            if !out.hasIngredients { out.ingredientsText = extras.ingredientsText }
        }
        if out.environmental == nil, let estimate = GenericEnvironmentalImpact.impact(for: name) {
            out.environmental = estimate
        }
        return out
    }

    // MARK: Lookup

    /// Finds the best facts for a product: exact barcode first, then a name
    /// search in the products DB (raw name, then the brand-stripped food
    /// word), then Edamam, then the built-in typical-values table. Every
    /// recognised food therefore gets the four macro boxes; nil only comes
    /// back for names nothing recognises at all. The result is then
    /// enriched with ratings (see `enriched(name:barcode:)`).
    static func lookup(name: String, barcode: String? = nil) async -> ProductNutritionFacts? {
        guard let base = await baseLookup(name: name, barcode: barcode) else { return nil }
        return await base.enriched(name: name, barcode: barcode)
    }

    private static func baseLookup(name: String, barcode: String?) async -> ProductNutritionFacts? {
        if let code = barcode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty,
           let rich = try? await OpenFoodFactsService.shared.fetchRich(code) {
            let facts = ProductNutritionFacts(product: rich)
            if facts.hasNutrition { return facts }
            if !facts.isEmpty { return GenericNutrition.fillingGaps(in: facts, for: name) }
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Query variants, most specific first. "Anchor Butter 500g" is tried
        // as written, then as "butter" so a brand the DB doesn't know still
        // lands on the right food.
        var queries: [String] = [trimmed]
        let stripped = FoodEmoji.searchTerm(for: trimmed)
        if !stripped.isEmpty, stripped.caseInsensitiveCompare(trimmed) != .orderedSame {
            queries.append(stripped)
        }

        // Best product record: the first hit *with nutrition* wins; failing
        // that, the first hit at all (for brand / ratings / ingredients).
        var partial: ProductNutritionFacts? = nil
        for query in queries {
            guard let hits = try? await OpenFoodFactsService.shared.searchRich(query), !hits.isEmpty else { continue }
            let all = hits.map(ProductNutritionFacts.init(product:))
            if let withNumbers = all.first(where: \.hasNutrition) {
                return withNumbers
            }
            if partial == nil, let first = all.first(where: { !$0.isEmpty }) {
                partial = first
            }
        }

        // Edamam knows generic foods; merge its numbers over any partial record.
        for query in queries {
            guard let edamam = await EdamamService.shared.fetchFood(for: query) else { continue }
            let e = ProductNutritionFacts(edamam: edamam)
            guard e.hasNutrition else { continue }
            guard var merged = partial else { return e }
            merged.source = .edamam
            merged.energyKcal = e.energyKcal; merged.fat = e.fat; merged.carbs = e.carbs
            merged.protein = e.protein; merged.fibre = e.fibre
            if merged.imageURL == nil { merged.imageURL = e.imageURL }
            return merged
        }

        // Last resort: typical values for the food itself.
        if let partial {
            return GenericNutrition.fillingGaps(in: partial, for: trimmed)
        }
        return GenericNutrition.facts(for: trimmed)
    }
}

// MARK: - Card

/// Nutrition-first product details. Pass `facts == nil` with `isLoading`
/// for the loading state; `facts == nil` otherwise shows "not available".
struct ProductNutritionCard: View {
    let facts: ProductNutritionFacts?
    var isLoading: Bool = false
    var showsIngredients: Bool = true
    /// The product's name. When set, the card checks the name and the
    /// ingredients list against the user's can't / won't eat rules
    /// (Profile → Dietary) and leads with a warning if anything matches.
    var productName: String? = nil

    @State private var showAllIngredients = false
    @ObservedObject private var restrictions = DietaryRestrictionStore.shared

    private var dietaryFlags: [DietaryFlag] {
        guard let productName, !productName.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return restrictions.flags(forName: productName, ingredientsText: facts?.ingredientsText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Safety first: above the nutrition numbers, so a scan of
            // something the user can't eat is impossible to miss.
            DietaryFlagCard(flags: dietaryFlags)

            HStack(alignment: .firstTextBaseline) {
                Text("Nutrition")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView().scaleEffect(0.7)
                } else if let source = facts?.source {
                    Text("via \(source.rawValue)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }

            if isLoading && facts == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading product info…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                // The four macro boxes are always drawn so every product reads
                // the same way; unknown values show as a dash.
                let shown = facts ?? ProductNutritionFacts()
                if shown.hasRatings { ProductRatingsView(facts: shown) }
                macroGrid(shown)
                if !shown.hasNutrition {
                    Text("Nutrition data not available for this product")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if shown.hasDietary { dietaryRow(shown) }
                if showsIngredients, shown.hasIngredients { ingredientsBlock(shown) }

                // Green / orange / red verdict circles — after food quality
                // and the ingredients, before the additive list. Tap a
                // circle to see what's behind the number.
                let signals = ProductSignals.build(facts: facts, flags: dietaryFlags)
                if !signals.isEmpty {
                    ProductTrafficLightsView(signals: signals)
                        .padding(.top, 4)
                }

                if showsIngredients {
                    let additives = shown.additives
                    if !additives.isEmpty { ProductAdditivesBlock(additives: additives) }
                }
            }
        }
    }

    // MARK: Macros

    private func macroGrid(_ facts: ProductNutritionFacts) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                macroTile("Energy", facts.energyKcal, unit: "kcal", decimals: 0)
                macroTile("Protein", facts.protein, unit: "g")
                macroTile("Fat", facts.fat, unit: "g")
                macroTile("Carbs", facts.carbs, unit: "g")
            }

            let secondary: [(String, Double?)] = [
                ("Saturated fat", facts.saturatedFat),
                ("Sugars", facts.sugars),
                ("Fibre", facts.fibre),
                ("Salt", facts.salt)
            ]
            let present: [(String, Double)] = secondary.compactMap { label, value in
                value.map { (label, $0) }
            }
            if !present.isEmpty {
                VStack(spacing: 4) {
                    ForEach(present, id: \.0) { label, value in
                        HStack {
                            Text(label)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(Self.format(value, unit: "g"))
                                .font(.subheadline.weight(.medium))
                        }
                    }
                }
                .padding(.top, 2)
            }

            Text("Per 100 g / 100 ml")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func macroTile(_ label: String, _ value: Double?, unit: String, decimals: Int = 1) -> some View {
        VStack(spacing: 2) {
            Text(value.map { Self.format($0, decimals: decimals) } ?? "–")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value.map { Self.format($0, decimals: decimals) } ?? "unknown") \(unit)")
    }

    // MARK: Dietary

    private func dietaryRow(_ facts: ProductNutritionFacts) -> some View {
        let flags: [(String, Bool?)] = [
            ("Vegan", facts.isVegan),
            ("Vegetarian", facts.isVegetarian),
            ("Gluten free", facts.isGlutenFree),
            ("Dairy free", facts.isDairyFree)
        ]
        return HStack(spacing: 8) {
            ForEach(flags.filter { $0.1 != nil }, id: \.0) { label, value in
                let ok = value == true
                HStack(spacing: 4) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                        .font(.caption2)
                    Text(label)
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(ok ? Color.green : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background((ok ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Ingredients

    private func ingredientsBlock(_ facts: ProductNutritionFacts) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ingredients")
                .font(.subheadline.weight(.semibold))
            Text(facts.ingredientsText ?? "")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(showAllIngredients ? nil : 3)
            if (facts.ingredientsText ?? "").count > 160 {
                Button(showAllIngredients ? "Show less" : "Show more") {
                    withAnimation(.easeInOut(duration: 0.2)) { showAllIngredients.toggle() }
                }
                .font(.footnote.weight(.semibold))
            }
        }
        .padding(.top, 4)
    }

    // MARK: Helpers

    static func format(_ value: Double, unit: String? = nil, decimals: Int = 1) -> String {
        let number = value == value.rounded() || decimals == 0
            ? String(Int(value.rounded()))
            : String(format: "%.\(decimals)f", value)
        guard let unit else { return number }
        return "\(number) \(unit)"
    }

    static func gradeColor(_ grade: String) -> Color {
        switch grade.lowercased() {
        case "a": return .green
        case "b": return Color(red: 0.5, green: 0.75, blue: 0.2)
        case "c": return .yellow
        case "d": return .orange
        case "e": return .red
        default:  return .gray
        }
    }

    static func novaColor(_ group: Int) -> Color {
        switch group {
        case 1:  return .green
        case 2:  return .yellow
        case 3:  return .orange
        case 4:  return .red
        default: return .gray
        }
    }

    static func concernColor(_ concern: FoodAdditive.Concern) -> Color {
        switch concern {
        case .none:     return .green
        case .low:      return Color(red: 0.75, green: 0.65, blue: 0.0)
        case .moderate: return .orange
        case .high:     return .red
        }
    }
}

// MARK: - Ratings

/// Two tiles side by side: food quality (Nutri-Score + NOVA) on the left,
/// environmental impact on the right. Either tile says so when it has no
/// rating, so the layout never shifts between products.
struct ProductRatingsView: View {
    let facts: ProductNutritionFacts

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            tile(title: "Food quality", icon: "heart.text.square") { foodQuality }
            tile(title: "Environmental impact", icon: "leaf") { environmental }
        }
    }

    private func tile<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            content()
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: Food quality

    @ViewBuilder
    private var foodQuality: some View {
        let nutri = ProductNutritionFacts.letterGrade(facts.nutriScore)
        if nutri == nil && facts.nova == nil {
            notRated
        } else {
            HStack(spacing: 10) {
                if let nutri {
                    gradeCircle(nutri.uppercased(), color: ProductNutritionCard.gradeColor(nutri), caption: "Nutri-Score")
                }
                if let nova = facts.nova {
                    gradeCircle("\(nova)", color: ProductNutritionCard.novaColor(nova), caption: "NOVA")
                }
            }
            Text(foodQualitySummary(nutri: nutri, nova: facts.nova))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func foodQualitySummary(nutri: String?, nova: Int?) -> String {
        var parts: [String] = []
        if let nutri { parts.append(Self.nutriLabel(nutri)) }
        if let nova { parts.append(Self.novaLabel(nova)) }
        return parts.joined(separator: " · ")
    }

    static func nutriLabel(_ grade: String) -> String {
        switch grade.lowercased() {
        case "a": return "Very good nutrition"
        case "b": return "Good nutrition"
        case "c": return "Average nutrition"
        case "d": return "Poor nutrition"
        default:  return "Very poor nutrition"
        }
    }

    static func novaLabel(_ group: Int) -> String {
        switch group {
        case 1:  return "Unprocessed"
        case 2:  return "Processed ingredient"
        case 3:  return "Processed"
        default: return "Ultra-processed"
        }
    }

    // MARK: Environmental

    @ViewBuilder
    private var environmental: some View {
        if let env = facts.environmental {
            HStack(alignment: .top, spacing: 10) {
                gradeCircle(env.grade.uppercased(), color: ProductNutritionCard.gradeColor(env.grade), caption: env.source.label)
                VStack(alignment: .leading, spacing: 2) {
                    Text(env.impactLabel)
                        .font(.caption.weight(.semibold))
                    if let co2 = env.co2Label {
                        Text(co2)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if case .estimated(let basis) = env.source {
                Text("Estimated from \(basis)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            notRated
        }
    }

    // MARK: Pieces

    private var notRated: some View {
        Text("No rating yet")
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .frame(maxHeight: .infinity, alignment: .center)
    }

    private func gradeCircle(_ value: String, color: Color, caption: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color, in: Circle())
            Text(caption)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Additives

/// The additives found in the ingredients, each with a colour-coded code
/// pill. Tap a row for what it is and why (if at all) it is flagged.
struct ProductAdditivesBlock: View {
    let additives: [FoodAdditive]

    @State private var expanded: Set<String> = []
    /// The whole section is a drop-down: closed by default, the header shows
    /// the count and the worst concern; open it to see (and tap) each one.
    @State private var isListOpen = false

    private var worst: FoodAdditive.Concern { additives.map(\.concern).max() ?? .none }
    private var flaggedCount: Int { additives.filter { $0.concern >= .moderate }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isListOpen.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("Additives")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(additives.count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    Spacer()
                    summaryChip
                    Image(systemName: isListOpen ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Additives, \(additives.count)")
            .accessibilityHint(isListOpen ? "Collapses the list" : "Expands the list")

            if isListOpen {
                VStack(spacing: 0) {
                    ForEach(additives) { additive in
                        row(additive)
                        if additive.id != additives.last?.id {
                            Divider().padding(.leading, 4)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 4)
    }

    private var summaryChip: some View {
        let color = ProductNutritionCard.concernColor(worst)
        let text: String = flaggedCount == 0
            ? (worst == .none ? "No known concerns" : "Limited concern")
            : "\(flaggedCount) to check"
        return HStack(spacing: 4) {
            Image(systemName: flaggedCount == 0 ? "checkmark.shield" : "exclamationmark.triangle")
                .font(.caption2)
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }

    private func row(_ additive: FoodAdditive) -> some View {
        let isOpen = expanded.contains(additive.id)
        let color = ProductNutritionCard.concernColor(additive.concern)
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isOpen { expanded.remove(additive.id) } else { expanded.insert(additive.id) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(additive.code)
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(additive.name)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(additive.function)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                if isOpen {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(additive.concern.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color)
                        Text(additive.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Also written as E\(additive.code) or INS \(additive.code)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(additive.code), \(additive.name), \(additive.function), \(additive.concern.label)")
        .accessibilityHint(isOpen ? "Collapses details" : "Expands details")
    }
}
