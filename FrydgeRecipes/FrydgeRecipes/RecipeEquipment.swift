//
//  RecipeEquipment.swift
//  FrydgeRecipes
//
//  What you need to get out before you start: the recipe's own `pan` list
//  plus everything the method mentions (oven, tray, whisk, blender…), each
//  with an emoji, a one-line note ("Preheat to 180°C", "Large, with a lid")
//  and a tick so it can be used as a get-ready checklist. Replaces the old
//  bare list of pan names on the recipe page.
//

import SwiftUI

// MARK: - Model

struct EquipmentItem: Identifiable, Hashable {
    let name: String
    let emoji: String
    /// Short hint, e.g. "Preheat to 200°C" or "Non-stick".
    var note: String?
    /// True when it came from the recipe's own equipment field rather than
    /// being inferred from the steps.
    var isExplicit: Bool

    var id: String { name.lowercased() }
}

enum RecipeEquipment {

    /// Explicit `pan` entries first (in order), then anything the steps
    /// mention that isn't already covered. Deduplicated by family, so
    /// "frying pan" and "skillet" don't both appear.
    static func items(for recipe: CloudRecipe) -> [EquipmentItem] {
        var out: [EquipmentItem] = []
        var seenFamilies = Set<String>()

        let stepsText = recipe.resolvedSteps.map(\.displayText).joined(separator: " ").lowercased()
        let allText = (recipe.instructions + " " + stepsText).lowercased()
        let temperature = firstTemperature(in: recipe)

        func add(_ name: String, explicit: Bool) {
            let family = family(for: name)
            guard seenFamilies.insert(family).inserted else { return }
            var item = EquipmentItem(name: prettify(name), emoji: emoji(forFamily: family), note: nil, isExplicit: explicit)
            item.note = note(forFamily: family, text: allText, temperature: temperature)
            out.append(item)
        }

        for raw in recipe.pan.split(separator: ",") {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            add(name, explicit: true)
        }

        for (family, keywords) in detectionOrder {
            guard !seenFamilies.contains(family) else { continue }
            if keywords.contains(where: { containsWord($0, in: allText) }) {
                add(displayName(forFamily: family), explicit: false)
            }
        }

        // An oven temperature anywhere means the oven is needed even if the
        // word "oven" never appears ("bake at 180°C").
        if temperature != nil, !seenFamilies.contains("oven"), containsAny(["bake", "roast", "°", "degrees"], in: allText) {
            add("Oven", explicit: false)
        }

        return out
    }

    // MARK: Families

    /// Detection order matters only for stable output; each family lists
    /// the words that imply it.
    private static let detectionOrder: [(String, [String])] = [
        ("oven",        ["oven", "bake", "baking", "roast", "roasting", "preheat"]),
        ("frypan",      ["frying pan", "fry pan", "frypan", "skillet", "pan-fry", "pan fry", "sauté", "saute", "sear", "fry "]),
        ("saucepan",    ["saucepan", "sauce pan", "simmer", "boil"]),
        ("pot",         ["stockpot", "stock pot", "large pot", "pot", "dutch oven", "casserole"]),
        ("wok",         ["wok", "stir-fry", "stir fry"]),
        ("tray",        ["baking tray", "baking sheet", "sheet pan", "oven tray", "tray", "roasting tin", "roasting pan"]),
        ("dish",        ["baking dish", "oven dish", "ovenproof dish", "lasagne dish", "pie dish", "gratin"]),
        ("tin",         ["cake tin", "loaf tin", "muffin tin", "muffin tray", "springform", "cake pan", "loaf pan"]),
        ("bowl",        ["mixing bowl", "large bowl", "bowl"]),
        ("whisk",       ["whisk", "beat the", "beat until", "whip"]),
        ("blender",     ["blender", "blend", "blitz", "food processor", "process until", "stick blender", "immersion blender", "purée", "puree"]),
        ("mixer",       ["stand mixer", "electric mixer", "hand mixer", "electric beater"]),
        ("knife",       ["chop", "dice", "slice", "mince the", "finely cut", "julienne", "knife"]),
        ("board",       ["chopping board", "cutting board"]),
        ("grater",      ["grate", "grated", "zest", "microplane", "grater"]),
        ("colander",    ["drain", "colander", "sieve", "strain"]),
        ("grill",       ["grill", "barbecue", "bbq", "chargrill", "griddle"]),
        ("microwave",   ["microwave"]),
        ("airfryer",    ["air fryer", "airfryer", "air-fryer"]),
        ("slowcooker",  ["slow cooker", "crockpot", "crock pot"]),
        ("pressure",    ["pressure cooker", "instant pot"]),
        ("steamer",     ["steam", "steamer"]),
        ("thermometer", ["thermometer", "internal temperature"]),
        ("scales",      ["weigh", "scales"]),
        ("rollingpin",  ["roll out", "rolling pin"]),
        ("foil",        ["foil", "baking paper", "parchment", "cling film", "plastic wrap"]),
        ("skewers",     ["skewer"]),
        ("tongs",       ["tongs", "turn the", "flip"])
    ]

    private static func family(for rawName: String) -> String {
        let n = rawName.lowercased()
        for (family, keywords) in detectionOrder where keywords.contains(where: { n.contains($0.trimmingCharacters(in: .whitespaces)) }) {
            return family
        }
        return n
    }

    private static func displayName(forFamily family: String) -> String {
        switch family {
        case "oven":        return "Oven"
        case "frypan":      return "Frying pan"
        case "saucepan":    return "Saucepan"
        case "pot":         return "Large pot"
        case "wok":         return "Wok"
        case "tray":        return "Baking tray"
        case "dish":        return "Baking dish"
        case "tin":         return "Cake tin"
        case "bowl":        return "Mixing bowl"
        case "whisk":       return "Whisk"
        case "blender":     return "Blender"
        case "mixer":       return "Mixer"
        case "knife":       return "Sharp knife"
        case "board":       return "Chopping board"
        case "grater":      return "Grater"
        case "colander":    return "Colander"
        case "grill":       return "Grill"
        case "microwave":   return "Microwave"
        case "airfryer":    return "Air fryer"
        case "slowcooker":  return "Slow cooker"
        case "pressure":    return "Pressure cooker"
        case "steamer":     return "Steamer"
        case "thermometer": return "Thermometer"
        case "scales":      return "Kitchen scales"
        case "rollingpin":  return "Rolling pin"
        case "foil":        return "Foil / baking paper"
        case "skewers":     return "Skewers"
        case "tongs":       return "Tongs"
        default:            return family.capitalized
        }
    }

    private static func emoji(forFamily family: String) -> String {
        switch family {
        case "oven":        return "♨️"
        case "frypan":      return "🍳"
        case "saucepan":    return "🍲"
        case "pot":         return "🥘"
        case "wok":         return "🥘"
        case "tray":        return "🍪"
        case "dish":        return "🥧"
        case "tin":         return "🎂"
        case "bowl":        return "🥣"
        case "whisk":       return "🥄"
        case "blender":     return "🌀"
        case "mixer":       return "🔄"
        case "knife":       return "🔪"
        case "board":       return "🪵"
        case "grater":      return "🧀"
        case "colander":    return "🫗"
        case "grill":       return "🔥"
        case "microwave":   return "📡"
        case "airfryer":    return "💨"
        case "slowcooker":  return "🐢"
        case "pressure":    return "⏱️"
        case "steamer":     return "♨️"
        case "thermometer": return "🌡️"
        case "scales":      return "⚖️"
        case "rollingpin":  return "🪄"
        case "foil":        return "📄"
        case "skewers":     return "🍢"
        case "tongs":       return "🥢"
        default:            return "🍽️"
        }
    }

    private static func note(forFamily family: String, text: String, temperature: String?) -> String? {
        switch family {
        case "oven":
            if let temperature { return "Preheat to \(temperature)" }
            return "Preheat before you start"
        case "frypan":
            if text.contains("non-stick") || text.contains("nonstick") { return "Non-stick" }
            if text.contains("large") { return "Large" }
            return nil
        case "pot", "saucepan":
            if text.contains("lid") { return "With a lid" }
            if text.contains("large") { return "Large" }
            return nil
        case "tray":
            if text.contains("lined") || text.contains("baking paper") || text.contains("parchment") { return "Lined with baking paper" }
            return nil
        case "tin":
            if text.contains("greased") || text.contains("grease") { return "Greased and lined" }
            if let size = text.firstMatch(of: /(\d{2})\s?cm/) { return "\(size.1) cm" }
            return nil
        case "bowl":
            return text.contains("large bowl") ? "Large" : nil
        case "blender":
            return text.contains("food processor") ? "Or a food processor" : nil
        case "thermometer":
            return "Checks it's cooked through"
        default:
            return nil
        }
    }

    // MARK: Helpers

    /// "180°C" from the first step that states a temperature.
    private static func firstTemperature(in recipe: CloudRecipe) -> String? {
        for step in recipe.resolvedSteps {
            if let t = step.temperatureDisplay, !t.isEmpty { return t }
        }
        let text = recipe.instructions
        if let match = text.firstMatch(of: /(\d{2,3})\s?(?:°|degrees)\s?([CcFf])?/) {
            let unit = match.2.map { String($0).uppercased() } ?? "C"
            return "\(match.1)°\(unit)"
        }
        return nil
    }

    private static func containsWord(_ word: String, in text: String) -> Bool {
        if word.hasSuffix(" ") { return text.contains(word) }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func containsAny(_ words: [String], in text: String) -> Bool {
        words.contains { text.contains($0) }
    }

    private static func prettify(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return trimmed }
        return first.uppercased() + trimmed.dropFirst()
    }
}

// MARK: - View

/// "Get ready" equipment grid: two columns of glass tiles with an emoji,
/// the name, a hint, and a tick to check things off as you set up.
struct RecipeEquipmentSection: View {
    let items: [EquipmentItem]

    @State private var ready: Set<String> = []

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Equipment")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                if !items.isEmpty {
                    Text(ready.count == items.count ? "All set" : "\(ready.count)/\(items.count) ready")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ready.count == items.count ? Color.green : Color.secondary)
                        .monospacedDigit()
                }
            }

            if items.isEmpty {
                Text("Nothing special — a pan, a knife and a board will do.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(items) { item in
                        tile(item)
                    }
                }
            }
        }
    }

    private func tile(_ item: EquipmentItem) -> some View {
        let isReady = ready.contains(item.id)
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                if isReady { ready.remove(item.id) } else { ready.insert(item.id) }
            }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 10) {
                Text(item.emoji)
                    .font(.system(size: 22))
                    .frame(width: 38, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.orange.opacity(isReady ? 0.08 : 0.16))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if let note = item.note {
                        Text(note)
                            .font(.caption2)
                            .foregroundColor(item.name == "Oven" ? .orange : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: isReady ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isReady ? Color.green : Color.secondary.opacity(0.5))
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isReady ? Color.green.opacity(0.45) : Color.white.opacity(0.15), lineWidth: 1)
                    )
            )
            .opacity(isReady ? 0.75 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.name)\(item.note.map { ", \($0)" } ?? "")")
        .accessibilityValue(isReady ? "Ready" : "Not ready")
        .accessibilityHint("Ticks it off your get-ready list")
    }
}
