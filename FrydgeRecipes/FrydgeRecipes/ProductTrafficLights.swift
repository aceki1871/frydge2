//
//  ProductTrafficLights.swift
//  FrydgeRecipes
//
//  The "at a glance" verdict on a product: three circles — green (good
//  news), orange (worth knowing) and red (a problem) — each with a count.
//  Tap a circle to drop down the list behind the number. Everything is
//  derived from facts the app already has (Nutri-Score, NOVA, environmental
//  grade, additives, per-100 g macros) plus the user's own can't / won't eat
//  rules, so "it's an onion" and "very low carbon footprint" sit side by side.
//
//  Also home to `UsageChipPicker`, the "half the bag" style replacement for
//  the old usage percentage slider on the item detail sheet.
//

import SwiftUI

// MARK: - Signals

struct ProductSignal: Identifiable, Hashable {
    enum Tone: Int, Comparable {
        case good, caution, bad
        static func < (lhs: Tone, rhs: Tone) -> Bool { lhs.rawValue < rhs.rawValue }

        var color: Color {
            switch self {
            case .good:    return .green
            case .caution: return .orange
            case .bad:     return .red
            }
        }

        var title: String {
            switch self {
            case .good:    return "Good"
            case .caution: return "Worth knowing"
            case .bad:     return "Watch out"
            }
        }

        var emptyText: String {
            switch self {
            case .good:    return "Nothing stood out as a plus yet."
            case .caution: return "Nothing to flag."
            case .bad:     return "No problems found."
            }
        }
    }

    let tone: Tone
    let systemImage: String
    let title: String
    let detail: String?

    var id: String { "\(tone.rawValue)|\(title)" }
}

enum ProductSignals {

    /// Builds the full list for a product. Blocking dietary flags come
    /// first so the most important thing is always at the top of the red list.
    static func build(facts: ProductNutritionFacts?, flags: [DietaryFlag]) -> [ProductSignal] {
        var out: [ProductSignal] = []

        // 1. The user's own rules ("it's an onion").
        for flag in flags {
            out.append(ProductSignal(
                tone: flag.isBlocking ? .bad : .caution,
                systemImage: flag.isBlocking ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill",
                title: flag.headline,
                detail: flag.reason
            ))
        }

        guard let facts else { return out }

        // 2. Nutri-Score
        if let nutri = ProductNutritionFacts.letterGrade(facts.nutriScore) {
            let tone: ProductSignal.Tone = ["a", "b"].contains(nutri) ? .good : (nutri == "c" ? .caution : .bad)
            out.append(ProductSignal(
                tone: tone,
                systemImage: "heart.text.square",
                title: "Nutri-Score \(nutri.uppercased())",
                detail: ProductRatingsView.nutriLabel(nutri)
            ))
        }

        // 3. Processing (NOVA)
        if let nova = facts.nova {
            let tone: ProductSignal.Tone = nova <= 1 ? .good : (nova == 4 ? .bad : .caution)
            out.append(ProductSignal(
                tone: tone,
                systemImage: nova <= 1 ? "leaf.circle" : "gearshape.2",
                title: ProductRatingsView.novaLabel(nova),
                detail: "NOVA group \(nova) of 4"
            ))
        }

        // 4. Environmental impact
        if let env = facts.environmental {
            let tone: ProductSignal.Tone = ["a", "b"].contains(env.grade) ? .good : (env.grade == "c" ? .caution : .bad)
            var detail = env.source.isEstimate ? "Estimated for this kind of food" : env.source.label
            if let co2 = env.co2Label { detail += " · \(co2)" }
            out.append(ProductSignal(
                tone: tone,
                systemImage: "leaf",
                title: "\(env.impactLabel) on the environment",
                detail: detail
            ))
        }

        // 5. Additives
        let additives = facts.additives
        if facts.hasIngredients && additives.isEmpty {
            out.append(ProductSignal(tone: .good, systemImage: "checkmark.shield", title: "No additives listed", detail: nil))
        }
        let flagged = additives.filter { $0.concern >= .moderate }
        if !additives.isEmpty && flagged.isEmpty {
            out.append(ProductSignal(
                tone: .good,
                systemImage: "checkmark.shield",
                title: additives.count == 1 ? "1 additive, no known concern" : "\(additives.count) additives, no known concerns",
                detail: nil
            ))
        }
        for additive in flagged {
            out.append(ProductSignal(
                tone: additive.concern == .high ? .bad : .caution,
                systemImage: "flask",
                title: "\(additive.name) (\(additive.code))",
                detail: additive.concern.label
            ))
        }

        // 6. Per-100 g traffic lights (UK FSA thresholds). Each figure stands
        //    on its own — a label scan may know the sugar but not the energy.
        if let sugars = facts.sugars {
            out.append(level(sugars, low: 5, high: 22.5, name: "sugar", unit: "g", image: "cube"))
        }
        if let sat = facts.saturatedFat {
            out.append(level(sat, low: 1.5, high: 5, name: "saturated fat", unit: "g", image: "drop"))
        }
        if let salt = facts.salt {
            out.append(level(salt, low: 0.3, high: 1.5, name: "salt", unit: "g", image: "sparkles"))
        }
        if let fibre = facts.fibre, fibre >= 6 {
            out.append(ProductSignal(tone: .good, systemImage: "leaf.arrow.circlepath", title: "High in fibre",
                                     detail: "\(ProductNutritionCard.format(fibre, unit: "g")) per 100 g"))
        }
        if let protein = facts.protein, protein >= 12 {
            out.append(ProductSignal(tone: .good, systemImage: "bolt.heart", title: "Good source of protein",
                                     detail: "\(ProductNutritionCard.format(protein, unit: "g")) per 100 g"))
        }

        // Blocking first within each tone, otherwise keep the order above.
        return out.sorted { a, b in
            if a.tone == b.tone { return false }
            return a.tone > b.tone
        }
    }

    private static func level(_ value: Double, low: Double, high: Double, name: String, unit: String, image: String) -> ProductSignal {
        let amount = "\(ProductNutritionCard.format(value, unit: unit)) per 100 g"
        if value <= low {
            return ProductSignal(tone: .good, systemImage: image, title: "Low in \(name)", detail: amount)
        }
        if value > high {
            return ProductSignal(tone: .bad, systemImage: image, title: "High in \(name)", detail: amount)
        }
        return ProductSignal(tone: .caution, systemImage: image, title: "Medium \(name)", detail: amount)
    }
}

// MARK: - View

/// Three numbered circles; tap one to expand its list underneath.
struct ProductTrafficLightsView: View {
    let signals: [ProductSignal]

    @State private var expandedTone: ProductSignal.Tone?

    private func count(_ tone: ProductSignal.Tone) -> Int { signals.filter { $0.tone == tone }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("At a glance")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 12) {
                ForEach([ProductSignal.Tone.good, .caution, .bad], id: \.rawValue) { tone in
                    circle(for: tone)
                }
                Spacer(minLength: 0)
            }

            if let tone = expandedTone {
                dropdown(for: tone)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: expandedTone)
    }

    private func circle(for tone: ProductSignal.Tone) -> some View {
        let n = count(tone)
        let isOpen = expandedTone == tone
        return Button {
            guard n > 0 else { return }
            expandedTone = isOpen ? nil : tone
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(tone.color.opacity(n == 0 ? 0.18 : 1))
                        .frame(width: 44, height: 44)
                    if isOpen {
                        Circle()
                            .strokeBorder(tone.color.opacity(0.35), lineWidth: 4)
                            .frame(width: 54, height: 54)
                    }
                    Text("\(n)")
                        .font(.headline.weight(.bold).monospacedDigit())
                        .foregroundStyle(n == 0 ? tone.color : .white)
                }
                .frame(width: 54, height: 54)
                HStack(spacing: 2) {
                    Text(tone.title)
                        .font(.caption2.weight(.semibold))
                    if n > 0 {
                        Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                }
                .foregroundStyle(n == 0 ? .tertiary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(n == 0)
        .accessibilityLabel("\(tone.title): \(n) item\(n == 1 ? "" : "s")")
        .accessibilityHint(n == 0 ? "" : (isOpen ? "Collapses the list" : "Shows the list"))
    }

    private func dropdown(for tone: ProductSignal.Tone) -> some View {
        let rows = signals.filter { $0.tone == tone }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { signal in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: signal.systemImage)
                        .font(.subheadline)
                        .foregroundStyle(tone.color)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(signal.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        if let detail = signal.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                if signal.id != rows.last?.id {
                    Divider().padding(.leading, 32)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(tone.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tone.color.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Usage chips ("half the bag")

/// How much of an item has gone, as a row of friendly chips instead of a
/// percentage slider. Chips snap to fixed usage values; the chosen one is
/// the nearest to the current usage so it also reflects stepper changes made
/// on the fridge row.
struct UsageChipPicker: View {
    let itemName: String
    @Binding var usagePercentage: Double

    private struct Step: Identifiable {
        let value: Double
        let label: String
        let emoji: String
        var id: Double { value }
    }

    private var steps: [Step] {
        let w = UsageChipPicker.containerWord(for: itemName)
        return [
            Step(value: 0,   label: "Untouched",             emoji: "✨"),
            Step(value: 10,  label: "Just a nibble",         emoji: "🤏"),
            Step(value: 25,  label: "A quarter of the \(w)", emoji: "🍽️"),
            Step(value: 50,  label: "Half the \(w)",         emoji: "😋"),
            Step(value: 75,  label: "Three-quarters gone",   emoji: "😅"),
            Step(value: 90,  label: "Scraping the bottom",   emoji: "🥄"),
            Step(value: 100, label: "Whole \(w) gone",       emoji: "👋")
        ]
    }

    private var nearest: Double {
        steps.min { abs($0.value - usagePercentage) < abs($1.value - usagePercentage) }?.value ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("How much is left?")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int((100 - usagePercentage).rounded()))% left")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundColor(.blue)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(steps) { step in
                            let isSelected = nearest == step.value
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    usagePercentage = step.value
                                }
                                UISelectionFeedbackGenerator().selectionChanged()
                            } label: {
                                HStack(spacing: 6) {
                                    Text(step.emoji)
                                    Text(step.label)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(
                                    Capsule().fill(isSelected ? Color.blue : Color(.tertiarySystemFill))
                                )
                                .foregroundStyle(isSelected ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                            .id(step.value)
                            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onAppear {
                    proxy.scrollTo(nearest, anchor: .center)
                }
            }
        }
    }

    /// "bag", "bottle", "jar", "bunch", "block", "pack" … from the name.
    static func containerWord(for name: String) -> String {
        let n = name.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { n.contains($0) } }
        if has(["milk", "juice", "oil", "sauce", "vinegar", "water", "wine", "beer", "cream", "syrup", "dressing", "drink", "kombucha", "soda"]) {
            return "bottle"
        }
        if has(["jam", "honey", "peanut butter", "nut butter", "marmalade", "pickle", "olives", "pesto", "mayo", "mustard", "relish", "chutney", "yoghurt", "yogurt", "hummus"]) {
            return "jar"
        }
        // Dry goods that come in a bag, before anything that could also be tinned.
        if has(["chips", "crisps", "flour", "rice", "sugar", "pasta", "lollies", "nuts", "oats", "cereal", "frozen"]) {
            return "bag"
        }
        if has(["tin", "can ", "canned", "baked beans", "chickpeas", "canned tomatoes", "tuna", "coconut milk", "sweetcorn", "creamed corn"]) {
            return "tin"
        }
        if has(["butter", "cheese", "cheddar", "tofu", "chocolate", "halloumi", "feta"]) {
            return "block"
        }
        if has(["banana", "carrot", "spring onion", "herb", "parsley", "coriander", "basil", "mint", "celery", "grapes", "asparagus", "kale", "silverbeet", "spinach"]) {
            return "bunch"
        }
        if has(["egg", "bacon", "sausage", "chicken", "beef", "mince", "pork", "lamb", "salmon", "fish", "prawn", "ham", "steak", "tortilla", "wraps"]) {
            return "pack"
        }
        if has(["bread", "loaf", "baguette"]) {
            return "loaf"
        }
        if has(["lettuce", "cabbage", "broccoli", "cauliflower"]) {
            return "head"
        }
        if has(["punnet", "berries", "strawberr", "blueberr", "raspberr", "cherry tomato", "mushroom"]) {
            return "punnet"
        }
        return "bag"
    }
}
