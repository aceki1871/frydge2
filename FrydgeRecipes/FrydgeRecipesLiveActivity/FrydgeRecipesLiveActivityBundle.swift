//
//  FrydgeRecipesLiveActivityBundle.swift
//  FrydgeRecipesLiveActivityExtension
//
//  Created by Josh on 26/04/2025.
//
//  One Live Activity, two faces:
//  - Shopping: the list at the nearest store, styled like the Home Screen
//    widget (store badge, brand wash, rounded rows, green prices).
//  - Cooking: takes over the moment a recipe is started in cook mode —
//    current step, a live step timer, and a "still to grab" strip of unticked
//    shopping items, so the cook stays on track with the phone locked or
//    while nipping out to the shop.
//
//  Animation: Live Activities animate between content states on their own.
//  Text uses `.contentTransition(.numericText())`, step text slides in with a
//  `.transition`, progress uses `.animation(_:value:)`, and the timers use
//  `Text(timerInterval:)` / `ProgressView(timerInterval:)` so they keep
//  ticking with the app suspended.
//

import SwiftUI
import WidgetKit
import ActivityKit
import UIKit
import Foundation
import AppIntents

@main
struct FrydgeRecipesLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        FrydgeRecipesLiveActivity()
        FrydgeRecipesLiveActivityControl()
    }
}

// MARK: - App Intent

/// Simple intent for toggling shopping list items in the Live Activity
struct FrydgeTickShoppingListItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Shopping List Item"
    static let description = IntentDescription("Check or uncheck a shopping list item")
    static let openAppWhenRun: Bool = false
    static let isDiscoverable: Bool = false

    @Parameter(title: "Item ID")
    var itemID: String

    init() {
        self.itemID = ""
    }

    init(itemID: String) {
        self.itemID = itemID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Toggle the item in the shared App Group (the one both targets are
        // entitled to). The app observes this key and pushes the new state.
        guard let ud = UserDefaults(suiteName: FrydgeAppGroup.primary) else {
            return .result()
        }

        var checkedItems = ud.stringArray(forKey: FrydgeAppGroup.checkedItemsKey) ?? []

        if let index = checkedItems.firstIndex(of: itemID) {
            // Item is checked, uncheck it
            checkedItems.remove(at: index)
        } else {
            // Item is not checked, check it
            checkedItems.append(itemID)
        }

        ud.set(checkedItems, forKey: FrydgeAppGroup.checkedItemsKey)

        // WidgetCenter reloads don't touch a running Live Activity, so push
        // the new ticked state to it directly — otherwise the tap does nothing
        // visible on the Lock Screen.
        for activity in Activity<ShoppingListActivityAttributes>.activities
        where activity.activityState == .active || activity.activityState == .stale {
            var state = activity.content.state
            guard state.shoppingListItems.contains(itemID) else { continue }
            if let index = state.checkedItems.firstIndex(of: itemID) {
                state.checkedItems.remove(at: index)
            } else {
                state.checkedItems.append(itemID)
            }
            await activity.update(ActivityContent(state: state, staleDate: activity.content.staleDate))
        }

        // Refresh any widget timelines
        WidgetCenter.shared.reloadAllTimelines()

        return .result()
    }
}

// MARK: - Shopping list formatting helpers
//
// File-scope so both the Lock Screen view and the Dynamic Island can format
// names, prices, and the running total consistently.

/// Every price-looking token found in an item string (e.g. "Milk $4.50" -> ["$4.50"]).
private func extractPrices(in item: String) -> [String] {
    let patterns = [
        #"NZ\$\s*\d+(?:\.\d{1,2})?"#,
        #"\$\s*\d+(?:\.\d{1,2})?"#,
        #"\b\d+(?:\.\d{1,2})\b"#
    ]

    var results: [String] = []
    var seen: Set<String> = []
    let nsRange = NSRange(item.startIndex..<item.endIndex, in: item)

    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }

        for match in regex.matches(in: item, options: [], range: nsRange) {
            guard let range = Range(match.range(at: 0), in: item) else { continue }
            let raw = String(item[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = raw
                .replacingOccurrences(of: "NZ$", with: "$", options: .caseInsensitive)
                .replacingOccurrences(of: "$ ", with: "$")

            let lower = item.lowercased()
            let lowerRange = Range(match.range(at: 0), in: lower)
            let afterChar = lowerRange.flatMap { $0.upperBound < lower.endIndex ? lower[$0.upperBound] : nil }
            if let afterChar, afterChar.isLetter {
                continue
            }

            if !seen.contains(normalized) {
                seen.insert(normalized)
                results.append(normalized.hasPrefix("$") ? normalized : "$\(normalized)")
            }
        }
    }

    return results
}

/// The price to display for a single item, if any.
private func displayPrice(in item: String) -> String? {
    extractPrices(in: item).last
}

/// The item name with any embedded price tokens stripped out.
private func displayName(of item: String) -> String {
    var cleaned = item
    for price in extractPrices(in: item) {
        cleaned = cleaned.replacingOccurrences(of: price, with: "", options: [.caseInsensitive])
        cleaned = cleaned.replacingOccurrences(of: price.replacingOccurrences(of: "$", with: "NZ$"), with: "", options: [.caseInsensitive])
    }

    cleaned = cleaned.replacingOccurrences(of: "NZ$", with: "", options: [.caseInsensitive])
    cleaned = cleaned.replacingOccurrences(of: "$", with: "")
    cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    // Title Case so the Live Activity matches the app's list rows and notifications.
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines).localizedCapitalized
}

/// Numeric value of an item's display price, if it has one.
private func priceValue(in item: String) -> Double? {
    guard let price = displayPrice(in: item) else { return nil }
    let digits = price
        .replacingOccurrences(of: "$", with: "")
        .trimmingCharacters(in: .whitespaces)
    return Double(digits)
}

/// Sum of all known item prices.
private func shoppingListTotalAmount(_ items: [String]) -> Double {
    items.reduce(0) { $0 + (priceValue(in: $1) ?? 0) }
}

/// Formatted running total (e.g. "$48.50"), or nil when no item carries a price.
private func shoppingListTotalText(_ items: [String]) -> String? {
    let total = shoppingListTotalAmount(items)
    return total > 0 ? String(format: "$%.2f", total) : nil
}

/// Formatted total of the ticked items — what's already in the trolley.
private func checkedTotalText(_ checkedItems: [String]) -> String? {
    shoppingListTotalText(checkedItems)
}

/// "1 item" / "12 items".
private func itemCountText(_ count: Int) -> String {
    "\(count) item\(count == 1 ? "" : "s")"
}

/// Tapping the Live Activity (outside a button) lands on the shopping list.
let shoppingListDeepLink = URL(string: "frydgerecipes://shopping-list")

/// Cook mode taps just bring the app — and the cook-along screen — back up.
let cookModeDeepLink = URL(string: "frydgerecipes://cook")

/// Cook mode accent; the same orange the in-app cook-along screen uses.
private let cookTint = Color.orange

// MARK: - Shared pieces (mirroring the listwidget look)

/// Brand-tinted wash behind the banner — the Live Activity version of
/// `FrydgeWidgetBackground` in the widget.
private struct LiveActivityWash: View {
    let tint: Color
    let strength: Double

    var body: some View {
        LinearGradient(
            colors: [tint.opacity(strength), .clear],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// Round recipe badge for cook mode — the cooking counterpart of `StoreLogoView`.
private struct RecipeBadge: View {
    let emoji: String
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(.white)
            Circle().strokeBorder(cookTint.opacity(0.35), lineWidth: 1)
            Text(emoji)
                .font(.system(size: size * 0.55))
        }
        .frame(width: size, height: size)
    }
}

/// Live countdown while a step timer runs; elapsed cooking time otherwise.
/// Both are system-driven timers, so they tick with the app suspended.
private struct CookTimerBadge: View {
    let cooking: ShoppingListActivityAttributes.CookingState
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            if let start = cooking.timerStartedAt, let end = cooking.timerEndsAt, end > start {
                Image(systemName: "timer")
                Text(timerInterval: start...end, countsDown: true)
                    .frame(width: compact ? 44 : 52, alignment: .trailing)
            } else {
                Image(systemName: "flame.fill")
                Text(
                    timerInterval: cooking.startedAt...cooking.startedAt.addingTimeInterval(12 * 3600),
                    countsDown: false
                )
                .frame(width: compact ? 44 : 52, alignment: .trailing)
            }
        }
        .font((compact ? Font.caption : Font.footnote).weight(.bold).monospacedDigit())
        .foregroundStyle(cookTint)
        .lineLimit(1)
        .padding(.horizontal, compact ? 0 : 8)
        .padding(.vertical, compact ? 0 : 4)
        .background {
            if !compact {
                Capsule().fill(cookTint.opacity(0.15))
            }
        }
    }
}

// MARK: - Lock Screen: shopping

/// Rendered on the Lock Screen via `ActivityConfiguration` below while no
/// recipe is being cooked.
///
/// NOTE: Live Activities cannot directly mutate your app data from the lock screen.
/// Interactions must deep-link into the app.
struct ShoppingListLiveActivityView: View {
    let storeName: String
    let shoppingListItems: [String]
    let checkedItems: [String]
    let emojis: [String: String]
    /// Items this store doesn't sell (from the app's in-store check). Drawn
    /// greyed out and sorted after the ones you can pick up here.
    var unavailableItems: [String] = []

    private var brand: StoreBrand { StoreBrand.resolve(storeName) }

    private var remainingItems: [String] {
        shoppingListItems.filter { !checkedItems.contains($0) }
    }

    /// Unticked items you can get here.
    private var remainingHere: [String] {
        remainingItems.filter { !unavailableItems.contains($0) }
    }

    /// Unticked items this store doesn't sell.
    private var remainingNotHere: [String] {
        remainingItems.filter { unavailableItems.contains($0) }
    }

    /// Unticked-and-available first, then unticked-but-not-sold-here, then
    /// ticked — so a tick never leaves a hole at the top and the greyed rows
    /// don't push real items off the bottom.
    private var orderedItems: [String] {
        remainingHere + remainingNotHere + shoppingListItems.filter { checkedItems.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            // Shopping list — adaptive rows. The Live Activity has a hard height
            // budget (160pt); anything taller gets clipped and vertically
            // centered by the system, which cuts the header off the top.
            // ViewThatFits measures each candidate and shows the largest one
            // that genuinely fits, so the header can never be pushed out.
            if shoppingListItems.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "cart")
                        .foregroundStyle(.secondary)
                    Text("Shopping list is empty")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ViewThatFits(in: .vertical) {
                    itemsList(maxItems: 10)
                    itemsList(maxItems: 8)
                    itemsList(maxItems: 7)
                    itemsList(maxItems: 6)
                    itemsList(maxItems: 5)
                    itemsList(maxItems: 4)
                    itemsList(maxItems: 3)
                    itemsList(maxItems: 2)
                    itemsList(maxItems: 1)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 14)
        .background(LiveActivityWash(tint: brand.tint, strength: brand.assetName == nil ? 0 : 0.22))
        .widgetURL(shoppingListDeepLink)
    }

    /// `badge — name ————— total`. The store name is never truncated: it wraps
    /// to a second line, and only then scales down. The total never shrinks.
    private var header: some View {
        HStack(spacing: 10) {
            StoreLogoView(storeName: storeName, size: 44)

            VStack(alignment: .leading, spacing: 0) {
                Text(brand.displayName)
                    .font(.headline.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.55)
                    .fixedSize(horizontal: false, vertical: true)
                if let branch = StoreBrand.branch(from: storeName) {
                    Text(branch)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if let total = shoppingListTotalText(shoppingListItems) {
                Text(total)
                    .font(.title2.weight(.bold).monospacedDigit())
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /// The first `maxItems` items, one per full-width row.
    /// Non-lazy so ViewThatFits can measure its true height.
    private func itemsList(maxItems: Int) -> some View {
        let visible = Array(orderedItems.prefix(maxItems))
        let overflow = orderedItems.count - visible.count

        return VStack(alignment: .leading, spacing: 4) {
            ForEach(visible, id: \.self) { item in
                itemRow(item)
                    .transition(.opacity)
            }

            if overflow > 0 {
                Text("+\(overflow) more")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
    }

    /// One row: tick, pic, name, price. Fixed point sizes, not text styles —
    /// the 160pt budget can't absorb Dynamic Type on top of a wrapping name.
    @ViewBuilder
    private func itemRow(_ item: String) -> some View {
        let isChecked = checkedItems.contains(item)
        // Not sold at this store: whole row fades (tick still works, in case
        // the shopper finds it anyway).
        let isUnavailable = !isChecked && unavailableItems.contains(item)

        HStack(alignment: .center, spacing: 7) {
            Button(intent: FrydgeTickShoppingListItemIntent(itemID: item)) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : (isUnavailable ? "xmark.circle" : "circle"))
                    .font(.system(size: 16))
                    .foregroundStyle(isChecked ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            if let emoji = emojis[item], !emoji.isEmpty {
                Text(emoji)
                    .font(.system(size: 15))
            }

            // The name takes the remaining width and wraps to a second line
            // rather than truncating.
            Text(displayName(of: item))
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .strikethrough(isChecked, color: .secondary)
                .foregroundStyle(isChecked || isUnavailable ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let price = displayPrice(in: item), !price.isEmpty {
                // fixedSize + layoutPriority: the price always renders in full;
                // the name gives way before the cost does.
                Text(price)
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
                    .foregroundStyle(isChecked || isUnavailable ? Color.secondary : Color.green)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(isChecked ? 0.04 : 0.08))
        )
        .opacity(isUnavailable ? 0.45 : 1)
    }
}

// MARK: - Lock Screen: cooking

/// Cook mode face of the Live Activity: recipe, current step, live timer and
/// whatever is still unticked on the shopping list.
struct CookingLiveActivityView: View {
    let cooking: ShoppingListActivityAttributes.CookingState
    /// Unticked shopping items — what still needs grabbing from the shop.
    let toGrab: [String]
    let emojis: [String: String]

    private var hasTimer: Bool {
        if let start = cooking.timerStartedAt, let end = cooking.timerEndsAt { return end > start }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            progressBars

            // Step text takes whatever height is left; drop to fewer lines
            // rather than letting the system clip the header off the top.
            ViewThatFits(in: .vertical) {
                stepBody(lineLimit: 3)
                stepBody(lineLimit: 2)
                stepBody(lineLimit: 1)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(LiveActivityWash(tint: cookTint, strength: 0.22))
        .widgetURL(cookModeDeepLink)
    }

    private var header: some View {
        HStack(spacing: 8) {
            RecipeBadge(emoji: cooking.recipeEmoji, size: 30)

            VStack(alignment: .leading, spacing: 0) {
                Text(cooking.recipeName)
                    .font(.footnote.weight(.bold))
                    .lineLimit(1)
                Text("Step \(cooking.stepIndex + 1) of \(cooking.stepCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 4)

            CookTimerBadge(cooking: cooking)
        }
    }

    /// Step progress (animates between steps) plus, while a timer runs, a
    /// second bar that fills in real time.
    private var progressBars: some View {
        VStack(spacing: 4) {
            ProgressView(
                value: Double(cooking.stepIndex + 1),
                total: Double(max(cooking.stepCount, 1))
            )
            .animation(.easeInOut(duration: 0.4), value: cooking.stepIndex)

            if let start = cooking.timerStartedAt, let end = cooking.timerEndsAt, end > start {
                ProgressView(
                    timerInterval: start...end,
                    countsDown: false,
                    label: { EmptyView() },
                    currentValueLabel: { EmptyView() }
                )
                .transition(.opacity)
            }
        }
        .progressViewStyle(.linear)
        .tint(cookTint)
    }

    private func stepBody(lineLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Keyed by step so a new step slides in from the right as the old
            // one leaves to the left.
            Text(cooking.stepText.isEmpty ? "Let's get cooking" : cooking.stepText)
                .font(.subheadline.weight(.medium))
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(cooking.stepIndex)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))

            if !toGrab.isEmpty {
                grabStrip
            }
        }
    }

    /// The unticked shopping items, as chips — so a dash to the shop mid-recipe
    /// still shows what to pick up without leaving cook mode.
    private var grabStrip: some View {
        HStack(spacing: 5) {
            Image(systemName: "cart.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Still to grab")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(toGrab.prefix(3), id: \.self) { item in
                HStack(spacing: 3) {
                    if let emoji = emojis[item], !emoji.isEmpty {
                        Text(emoji)
                    }
                    Text(displayName(of: item))
                        .lineLimit(1)
                }
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .transition(.opacity)
            }

            if toGrab.count > 3 {
                Text("+\(toGrab.count - 3)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

// MARK: - Lock Screen router

/// Picks the cooking or shopping face for the current state, with a slide
/// between the two when cook mode takes over or hands back.
private struct LiveActivityLockScreenView: View {
    let state: ShoppingListActivityAttributes.ContentState
    let fallbackStoreName: String

    var body: some View {
        let emojis = state.itemEmojis ?? [:]
        if let cooking = state.cooking {
            let notHere = Set(state.unavailableItems ?? [])
            CookingLiveActivityView(
                cooking: cooking,
                // "Still to grab" only lists what this store actually sells.
                toGrab: state.shoppingListItems.filter { !state.checkedItems.contains($0) && !notHere.contains($0) },
                emojis: emojis
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            ShoppingListLiveActivityView(
                // State's store follows the shopper between stores; attributes
                // hold whichever store originally started the activity.
                storeName: state.storeName ?? fallbackStoreName,
                shoppingListItems: state.shoppingListItems,
                checkedItems: state.checkedItems,
                emojis: emojis,
                unavailableItems: state.unavailableItems ?? []
            )
            .transition(.opacity)
        }
    }
}

// MARK: - Widget

struct FrydgeRecipesLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ShoppingListActivityAttributes.self) { context in
            LiveActivityLockScreenView(
                state: context.state,
                fallbackStoreName: context.attributes.storeName
            )
        } dynamicIsland: { context in
            let state = context.state
            let storeName = state.storeName ?? context.attributes.storeName
            let emojis = state.itemEmojis ?? [:]
            // Items this store doesn't sell are left out of the island's
            // "left to get" count and preview; the lock screen shows them greyed.
            let notHere = Set(state.unavailableItems ?? [])
            let remaining = state.shoppingListItems.filter { !state.checkedItems.contains($0) && !notHere.contains($0) }

            // Long-press expands into an organised summary; tapping anywhere
            // (island or lock screen) deep-links into the app.
            return DynamicIsland {
                // Leading — recipe badge + name while cooking, else brand badge + store.
                DynamicIslandExpandedRegion(.leading) {
                    if let cooking = state.cooking {
                        HStack(spacing: 6) {
                            RecipeBadge(emoji: cooking.recipeEmoji, size: 24)
                            Text(cooking.recipeName)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    } else {
                        HStack(spacing: 6) {
                            StoreLogoView(storeName: storeName, size: 24)
                            Text(StoreBrand.resolve(storeName).displayName)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                }
                // Trailing — live timer while cooking, else total over the item count.
                DynamicIslandExpandedRegion(.trailing) {
                    if let cooking = state.cooking {
                        CookTimerBadge(cooking: cooking, compact: true)
                    } else {
                        VStack(alignment: .trailing, spacing: 1) {
                            if let total = shoppingListTotalText(state.shoppingListItems) {
                                Text(total)
                                    .font(.subheadline.weight(.bold).monospacedDigit())
                                    .contentTransition(.numericText())
                            }
                            Text(itemCountText(remaining.count))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                    }
                }
                // Bottom — the current step while cooking, else progress plus
                // the next few unchecked items.
                DynamicIslandExpandedRegion(.bottom) {
                    if let cooking = state.cooking {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Step \(cooking.stepIndex + 1) of \(cooking.stepCount)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())

                            Text(cooking.stepText.isEmpty ? "Let's get cooking" : cooking.stepText)
                                .font(.caption)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(cooking.stepIndex)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)
                                ))

                            ProgressView(
                                value: Double(cooking.stepIndex + 1),
                                total: Double(max(cooking.stepCount, 1))
                            )
                            .tint(cookTint)
                            .animation(.easeInOut(duration: 0.4), value: cooking.stepIndex)

                            if !remaining.isEmpty {
                                let names = remaining.prefix(3).map { item in
                                    [emojis[item], displayName(of: item)].compactMap { $0 }.joined(separator: " ")
                                }
                                let more = remaining.count > 3 ? " +\(remaining.count - 3)" : ""
                                Text("Still to grab: \(names.joined(separator: ", "))\(more)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    } else if state.shoppingListItems.isEmpty {
                        Text("Shopping list empty")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            if !state.checkedItems.isEmpty {
                                let trolley = checkedTotalText(state.checkedItems).map { " · \($0) in trolley" } ?? ""
                                Text("\(state.checkedItems.count) of \(state.shoppingListItems.count) ticked\(trolley)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .contentTransition(.numericText())
                            }

                            ForEach(remaining.prefix(3), id: \.self) { item in
                                HStack(spacing: 6) {
                                    Image(systemName: "circle")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if let emoji = emojis[item], !emoji.isEmpty {
                                        Text(emoji)
                                            .font(.caption2)
                                    }
                                    Text(displayName(of: item))
                                        .font(.caption)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    if let price = displayPrice(in: item) {
                                        Text(price)
                                            .font(.caption2.weight(.semibold).monospacedDigit())
                                            .foregroundStyle(.green)
                                    }
                                }
                                .transition(.opacity)
                            }

                            if remaining.count > 3 {
                                Text("+\(remaining.count - 3) more to grab")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .contentTransition(.numericText())
                            } else if remaining.isEmpty {
                                Text("All done — nice work!")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }
            } compactLeading: {
                if let cooking = state.cooking {
                    Text(cooking.recipeEmoji)
                        .font(.caption)
                } else {
                    Image(systemName: "cart.fill")
                }
            } compactTrailing: {
                if let cooking = state.cooking {
                    if let start = cooking.timerStartedAt, let end = cooking.timerEndsAt, end > start {
                        Text(timerInterval: start...end, countsDown: true)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(cookTint)
                            .frame(width: 40, alignment: .trailing)
                    } else {
                        Text("\(cooking.stepIndex + 1)/\(cooking.stepCount)")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(cookTint)
                            .contentTransition(.numericText())
                    }
                } else {
                    Text("\(remaining.count)")
                        .font(.caption2.monospacedDigit())
                        .contentTransition(.numericText(countsDown: true))
                }
            } minimal: {
                if let cooking = state.cooking {
                    Text(cooking.recipeEmoji)
                        .font(.caption2)
                } else {
                    Image(systemName: "cart")
                }
            }
            .widgetURL(state.cooking == nil ? shoppingListDeepLink : cookModeDeepLink)
            .keylineTint(state.cooking == nil ? StoreBrand.resolve(storeName).tint : cookTint)
        }
    }
}

// MARK: - Previews

#Preview("Lock Screen", as: .content, using: ShoppingListActivityAttributes(storeName: "Woolworths Whitianga")) {
    FrydgeRecipesLiveActivity()
} contentStates: {
    // A long, fully priced list — the case that was clipping the header.
    ShoppingListActivityAttributes.ContentState(
        shoppingListItems: [
            "Milk $4.50", "Wholegrain Bread $3.20", "Free Range Eggs $8.90",
            "Butter $6.40", "Cheddar Cheese $9.20", "Bananas $2.80",
            "Chicken Breast $12.50", "Greek Yoghurt $5.60", "Tomatoes $4.10",
            "Pasta $2.20", "Olive Oil $11.00", "Coffee Beans $14.50",
        ],
        checkedItems: ["Milk $4.50", "Butter $6.40"],
        itemEmojis: [
            "Milk $4.50": "🥛", "Wholegrain Bread $3.20": "🍞", "Free Range Eggs $8.90": "🥚",
            "Butter $6.40": "🧈", "Cheddar Cheese $9.20": "🧀", "Bananas $2.80": "🍌",
            "Chicken Breast $12.50": "🍗", "Greek Yoghurt $5.60": "🥣", "Tomatoes $4.10": "🍅",
            "Pasta $2.20": "🍝", "Olive Oil $11.00": "🫒", "Coffee Beans $14.50": "☕️",
        ]
    )
    // Short list, one item this store doesn't sell (greyed, sorted last).
    ShoppingListActivityAttributes.ContentState(
        shoppingListItems: ["Milk $4.50", "Bread $3.20", "Eggs $8.90"],
        checkedItems: [],
        unavailableItems: ["Bread $3.20"]
    )
    // Cook mode with a running timer and two items still to grab.
    ShoppingListActivityAttributes.ContentState(
        shoppingListItems: ["Milk $4.50", "Bread $3.20", "Eggs $8.90"],
        checkedItems: ["Bread $3.20"],
        itemEmojis: ["Milk $4.50": "🥛", "Bread $3.20": "🍞", "Eggs $8.90": "🥚"],
        cooking: ShoppingListActivityAttributes.CookingState(
            recipeName: "Creamy Chicken Pasta",
            recipeEmoji: "🍝",
            stepIndex: 2,
            stepCount: 7,
            stepText: "Simmer the sauce gently, stirring now and then, until it coats the back of a spoon.",
            startedAt: Date().addingTimeInterval(-9 * 60),
            timerStartedAt: Date(),
            timerEndsAt: Date().addingTimeInterval(8 * 60)
        )
    )
}
