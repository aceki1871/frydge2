//
//  RecipeDetailSupportingViews.swift
//  FrydgeRecipes
//
//  Self-contained views and types that the recipe detail page presents but
//  that don't need its state: the ingredient thumbnail, the dietary adaptation
//  sheet, and the post-cook "update your fridge" sheet. Moved out of
//  RecipeDetailView.swift so that file is just the page itself.
//

import SwiftUI
import UIKit

// MARK: - Ingredient thumbnail

/// Square picture for an ingredient row. Resolution order: the matched
/// store product's photo, then the product the user previously picked for
/// this ingredient (IngredientProductCache), then the cached product image
/// store, and finally the food emoji on a soft tile. A small corner badge
/// says whether it's already in the fridge.
struct IngredientThumbnailView: View {
    enum Status { case none, have, partial, partialFrozen }

    let ingredientName: String
    let imageURL: URL?
    let status: Status

    @State private var resolvedURL: URL?
    @State private var localImage: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.gray.opacity(0.12))

            if let localImage {
                Image(uiImage: localImage)
                    .resizable()
                    .scaledToFill()
            } else if let url = imageURL ?? resolvedURL {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        emoji
                    default:
                        emoji.opacity(0.6)
                    }
                }
            } else {
                emoji
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .overlay(alignment: .bottomTrailing) { statusBadge }
        .task(id: ingredientName) { await resolveFallbackImage() }
        .accessibilityHidden(true)
    }

    private var emoji: some View {
        Text(FoodEmoji.emoji(for: ingredientName))
            .font(.system(size: 26))
    }

    @ViewBuilder
    private var statusBadge: some View {
        if status != .none {
            let (symbol, tint): (String, Color) = {
                switch status {
                case .have:          return ("checkmark", .green)
                case .partialFrozen: return ("snowflake", .blue)
                default:             return ("drop.fill", .blue)
                }
            }()
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(tint))
                .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
                .offset(x: 4, y: 4)
        }
    }

    /// Only runs when the row has no store-offer photo to show.
    private func resolveFallbackImage() async {
        guard imageURL == nil else { return }

        if let cached = await IngredientProductCache.shared.preferred(for: ingredientName),
           let string = cached.imageURL, let url = URL(string: string) {
            resolvedURL = url
            return
        }

        let manager = ProductImageCacheManager.shared
        let key = manager.imageCacheKey(name: ingredientName, quantity: "", unit: "")
        if let image = manager.uiImage(forKey: key) {
            localImage = image
            return
        }
        await manager.prefetchIfNeeded(for: ingredientName)
        if let image = manager.uiImage(forKey: key) {
            localImage = image
        }
    }
}

// MARK: - Recipe adaptation sheet

struct RecipeAdaptationSheet: View {
    let tag: String
    let recipeName: String
    let swaps: [(original: String, substitute: String)]
    let allIngredients: [String]

    @Environment(\.dismiss) private var dismiss

    private var tagLabel: String {
        switch tag.uppercased() {
        case "GF": return "Gluten Free"
        case "DF": return "Dairy Free"
        case "V":  return "Vegetarian"
        case "VG": return "Vegan"
        default:   return tag
        }
    }

    private var accentColor: Color {
        switch tag.uppercased() {
        case "GF": return .green
        case "DF": return .orange
        case "V":  return .teal
        case "VG": return .mint
        default:   return .blue
        }
    }

    private var swapOriginals: Set<String> { Set(swaps.map(\.original)) }

    private var alreadySuitable: [String] {
        allIngredients.filter { !swapOriginals.contains($0) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if swaps.isEmpty {
                    ContentUnavailableView {
                        Label("Already \(tagLabel)!", systemImage: "checkmark.seal.fill")
                    } description: {
                        Text("All ingredients in \"\(recipeName)\" are suitable for a \(tagLabel) diet — no changes needed.")
                    }
                } else {
                    List {
                        Section {
                            ForEach(Array(swaps.enumerated()), id: \.offset) { _, swap in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.red.opacity(0.75))
                                            .font(.caption)
                                        Text(swap.original)
                                            .font(.subheadline)
                                            .strikethrough(color: .secondary)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    HStack(alignment: .top, spacing: 6) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(accentColor)
                                            .font(.caption)
                                        Text(swap.substitute)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(3)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        } header: {
                            Label("Swap These", systemImage: "arrow.2.squarepath")
                        } footer: {
                            Text("Swapping these ingredients makes this recipe \(tagLabel)-friendly.")
                        }

                        if !alreadySuitable.isEmpty {
                            Section {
                                ForEach(alreadySuitable, id: \.self) { ingredient in
                                    Label {
                                        Text(ingredient)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    } icon: {
                                        Image(systemName: "checkmark.circle")
                                            .foregroundStyle(accentColor.opacity(0.6))
                                    }
                                }
                            } header: {
                                Label("Already Suitable", systemImage: "checkmark.seal")
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Make \(tagLabel)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Auto-calculated cook usage

/// How much of a fridge item a recipe uses, worked out from the parsed recipe
/// amount (scaled to serves) plus a wastage buffer.
struct CookUsageEstimate {
    /// Percentage of the item to mark used this cook (delta on current usage).
    var percent: Double
    /// Human-readable breakdown, e.g. "≈150 g of 500 g · incl. ~10% waste".
    var detail: String?
    /// True when derived from real quantities; false when we fell back to a default.
    var isEstimated: Bool
}

// MARK: - Mark Cooked confirmation sheet

/// Shown after cooking. Amounts are auto-calculated from the recipe (plus wastage)
/// and pre-selected; the user can fine-tune or untick before the fridge updates,
/// instead of silently deleting every fuzzy match.
struct MarkCookedSheet: View {
    let recipeName: String
    let items: [StoredIngredient]
    let estimates: [UUID: CookUsageEstimate]
    let onConfirm: ([(id: UUID, percent: Double)]) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Per-item chosen usage percentage; a missing key means "don't touch this item".
    @State private var usage: [UUID: Double]

    init(recipeName: String,
         items: [StoredIngredient],
         estimates: [UUID: CookUsageEstimate],
         onConfirm: @escaping ([(id: UUID, percent: Double)]) -> Void) {
        self.recipeName = recipeName
        self.items = items
        self.estimates = estimates
        self.onConfirm = onConfirm
        // Default each item to its auto-calculated amount, snapped to the 10–100 scale.
        _usage = State(initialValue: Dictionary(uniqueKeysWithValues: items.map {
            ($0.id, Self.snapToScale(estimates[$0.id]?.percent ?? max(0, 100 - $0.quantityUsed)))
        }))
    }

    /// The 10 → 100% scale steps offered per item.
    private static let scale: [Int] = Array(stride(from: 10, through: 100, by: 10))

    private static func snapToScale(_ value: Double) -> Double {
        let rounded = (value / 10).rounded() * 10
        return min(100, max(10, rounded))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header

                    ForEach(items) { item in
                        itemCard(item)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Cooked \(recipeName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Update") {
                        onConfirm(usage.map { (id: $0.key, percent: $0.value) })
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "refrigerator.fill")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.blue.opacity(0.12)))

            VStack(alignment: .leading, spacing: 3) {
                Text("Update your fridge")
                    .font(.headline)
                Text("Amounts are auto-calculated from the recipe plus ~10% wastage. Tune the scale or untick anything that's off — items at 100% leave the fridge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    // MARK: Item card

    @ViewBuilder
    private func itemCard(_ item: StoredIngredient) -> some View {
        let included = usage[item.id] != nil
        let suggested = estimates[item.id].map { Int(Self.snapToScale($0.percent)) }

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(FoodEmoji.emoji(for: item.name))
                    .font(.system(size: 30))
                    .frame(width: 46, height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let detail = estimates[item.id]?.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Amount not detected — set how much you used.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                Toggle("", isOn: includedBinding(for: item.id))
                    .labelsHidden()
            }

            if included {
                usageScale(for: item.id, suggested: suggested)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(included ? 0.06 : 0.03), lineWidth: 1)
        )
        .opacity(included ? 1 : 0.6)
    }

    // MARK: 10–100% scale

    private func usageScale(for id: UUID, suggested: Int?) -> some View {
        let current = Int(usage[id] ?? 0)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(current)%")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.blue)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.scale, id: \.self) { pct in
                        let isSelected = current == pct
                        Button {
                            usage[id] = Double(pct)
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            Text("\(pct)")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(isSelected ? .white : .primary)
                                .frame(width: 42, height: 38)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(isSelected ? Color.blue : Color(.tertiarySystemFill))
                                )
                                .overlay(alignment: .topTrailing) {
                                    if suggested == pct {
                                        Circle()
                                            .fill(Color.orange)
                                            .frame(width: 6, height: 6)
                                            .padding(4)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            if suggested != nil {
                Text("● Suggested from the recipe")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func includedBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { usage[id] != nil },
            set: { isOn in
                usage[id] = isOn
                    ? (usage[id] ?? Self.snapToScale(estimates[id]?.percent ?? 100))
                    : nil
            }
        )
    }
}
