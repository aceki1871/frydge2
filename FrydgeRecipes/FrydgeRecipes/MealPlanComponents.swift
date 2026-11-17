//
//  MealPlanComponents.swift
//  FrydgeRecipes
//
//  Pieces shared by the personal Weekly Plan and the Household Plan so both
//  look and behave the same: the seven-day overview, the budget card, the
//  household restock list, leftover planning and the plain-text export.
//
//  Nothing here owns data. Each view takes plain values plus closures, so the
//  personal planner backs them with WeekPlanStore and the household planner
//  backs them with SharedMealPlanStore.
//

import SwiftUI
import CloudKit

// MARK: - Leftovers on the plan

/// A leftover is planned as a meal with no ingredients: nothing to buy, nothing
/// to defrost, nothing to price. It is tagged through the recipe ID so neither
/// the Core Data model nor the CloudKit schema needs a new field.
enum PlannedLeftover {
    static let idPrefix = "leftover:"

    static func recipeID(forItem itemID: String) -> String { idPrefix + itemID }

    static func isLeftover(recipeID: String) -> Bool { recipeID.hasPrefix(idPrefix) }

    /// The frydge item the planned leftover points at, if the ID is a leftover's.
    static func itemID(from recipeID: String) -> String? {
        guard recipeID.hasPrefix(idPrefix) else { return nil }
        return String(recipeID.dropFirst(idPrefix.count))
    }

    /// "2 portions" / "1 portion" from the planned meal's `serves`.
    static func portionsText(_ serves: String) -> String {
        let n = max(1, Int(serves.filter(\.isNumber)) ?? 1)
        return "\(n) portion\(n == 1 ? "" : "s")"
    }

    /// Next calendar date (today included) for a plan weekday, 0 = Monday.
    static func nextOccurrence(of dayIndex: Int, from now: Date = Date()) -> Date? {
        guard (0...6).contains(dayIndex) else { return nil }
        let calendar = Calendar.current
        let targetWeekday = ((dayIndex + 1) % 7) + 1
        let today = calendar.startOfDay(for: now)
        for offset in 0..<7 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            if calendar.component(.weekday, from: candidate) == targetWeekday { return candidate }
        }
        return nil
    }

    /// True when the leftover will already be past its use-by on that day.
    static func isAfterUseBy(dayIndex: Int, expiry: Date, now: Date = Date()) -> Bool {
        guard let day = nextOccurrence(of: dayIndex, from: now) else { return false }
        return day > Calendar.current.startOfDay(for: expiry)
    }
}

/// A leftover sitting in a frydge (personal or shared) that could be planned.
struct PlannableLeftover: Identifiable, Hashable {
    /// Personal: the StoredIngredient UUID. Shared: the CloudKit record name.
    let id: String
    let name: String
    let portions: Int
    let expiryDate: Date
    let dietaryTags: [String]

    var isExpired: Bool { expiryDate < Calendar.current.startOfDay(for: Date()) }

    var portionsText: String { "\(portions) portion\(portions == 1 ? "" : "s")" }

    /// "Use today", "Use by tomorrow", "Use within 3 days", "Expired".
    var expiryLabel: String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: expiryDate)
        ).day ?? 0
        if days < 0 { return "Expired" }
        if days == 0 { return "Use today" }
        if days == 1 { return "Use by tomorrow" }
        return "Use within \(days) days"
    }

    /// Needs eating today or tomorrow.
    var isUrgent: Bool {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: expiryDate)
        ).day ?? 0
        return days <= 1
    }

    init(id: String, name: String, portions: Int, expiryDate: Date, dietaryTags: [String]) {
        self.id = id
        self.name = name
        self.portions = portions
        self.expiryDate = expiryDate
        self.dietaryTags = dietaryTags
    }

    /// A leftover from my own frydge.
    init(stored: StoredIngredient) {
        self.init(
            id: stored.id.uuidString,
            name: stored.name,
            portions: max(1, Int(stored.quantity.filter(\.isNumber)) ?? 1),
            expiryDate: stored.expirationDate,
            dietaryTags: Array(stored.dietaryTags)
        )
    }

    /// A leftover StoredIngredient record from a shared frydge; nil for
    /// anything that isn't a leftover.
    init?(record: CKRecord) {
        guard (record["lifecycle"] as? String) == StoredIngredient.ItemLifecycle.leftover.rawValue,
              let name = record["name"] as? String, !name.isEmpty else { return nil }
        self.init(
            id: record.recordID.recordName,
            name: name,
            portions: max(1, Int(((record["quantity"] as? String) ?? "").filter(\.isNumber)) ?? 1),
            expiryDate: (record["expirationDate"] as? Date) ?? Date(),
            dietaryTags: (record["dietaryTags"] as? [String]) ?? []
        )
    }
}

/// "Leftovers to use up": every unplanned, unexpired leftover in the frydge
/// with a day picker, so nothing gets forgotten at the back of the shelf.
struct LeftoversToUseSection: View {
    let leftovers: [PlannableLeftover]
    let onPlan: (PlannableLeftover, Int) -> Void

    var body: some View {
        if !leftovers.isEmpty {
            Section {
                ForEach(leftovers) { leftover in
                    HStack(spacing: 12) {
                        FoodItemThumbnail(name: leftover.name, width: 40, height: 40, cornerRadius: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(leftover.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text("\(leftover.portionsText) · \(leftover.expiryLabel)")
                                .font(.caption)
                                .foregroundStyle(leftover.isUrgent ? .orange : .secondary)
                        }
                        Spacer()
                        LeftoverDayMenu(leftover: leftover) { day in onPlan(leftover, day) }
                    }
                }
            } header: {
                Label("Leftovers to use up", systemImage: "takeoutbag.and.cup.and.straw")
            } footer: {
                Text("Pick a night for these before they go off. Leftovers don't add anything to the shopping list.")
            }
        }
    }
}

/// Day picker for one leftover. Days after its use-by are flagged.
struct LeftoverDayMenu: View {
    let leftover: PlannableLeftover
    let onPick: (Int) -> Void

    var body: some View {
        Menu {
            ForEach(0..<7, id: \.self) { day in
                Button {
                    onPick(day)
                } label: {
                    if PlannedLeftover.isAfterUseBy(dayIndex: day, expiry: leftover.expiryDate) {
                        Label(PlannedRecipe.dayNames[day], systemImage: "exclamationmark.triangle")
                    } else {
                        Text(PlannedRecipe.dayNames[day])
                    }
                }
            }
        } label: {
            Label("Plan", systemImage: "calendar.badge.plus")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.blue)
    }
}

/// Submenu for the per-day "Add recipe" menu listing leftovers in the frydge.
struct LeftoverPickMenu: View {
    let leftovers: [PlannableLeftover]
    let dayIndex: Int
    let onPick: (PlannableLeftover) -> Void

    var body: some View {
        if !leftovers.isEmpty {
            Menu {
                ForEach(leftovers) { leftover in
                    Button {
                        onPick(leftover)
                    } label: {
                        let late = PlannedLeftover.isAfterUseBy(dayIndex: dayIndex, expiry: leftover.expiryDate)
                        Label(
                            "\(leftover.name) · \(leftover.portionsText)",
                            systemImage: late ? "exclamationmark.triangle" : "takeoutbag.and.cup.and.straw"
                        )
                    }
                }
            } label: {
                Label("Leftovers in the frydge", systemImage: "takeoutbag.and.cup.and.straw")
            }
        }
    }
}

/// A planned leftover inside a day section. `live` is the matching item still
/// in the frydge, if any, so the row can show portions and use-by.
struct PlannedLeftoverRow: View {
    let name: String
    let serves: String
    let dayIndex: Int
    let live: PlannableLeftover?
    var addedBy: String? = nil

    private var statusText: String {
        guard let live else { return "No longer in the frydge" }
        if PlannedLeftover.isAfterUseBy(dayIndex: dayIndex, expiry: live.expiryDate) {
            return "Use-by is before \(PlannedRecipe.dayNames[dayIndex])"
        }
        return live.expiryLabel
    }

    private var statusColor: Color {
        guard let live else { return .secondary }
        if PlannedLeftover.isAfterUseBy(dayIndex: dayIndex, expiry: live.expiryDate) { return .orange }
        return live.isUrgent ? .orange : .secondary
    }

    var body: some View {
        HStack(spacing: 12) {
            FoodItemThumbnail(name: name, width: 64, height: 64, cornerRadius: 12, emojiFont: .title)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text("Leftovers")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.teal.opacity(0.15), in: Capsule())
                        .foregroundStyle(.teal)
                    Text(live?.portionsText ?? PlannedLeftover.portionsText(serves))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                if let addedBy, !addedBy.isEmpty {
                    Text("Added by \(addedBy)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Week overview

/// Seven day pills with meal counts and the day's estimated cost. Tapping a
/// pill jumps straight to the recipe picker for that day.
struct WeekOverviewPills: View {
    /// Meals planned per day, index 0 = Monday.
    let counts: [Int]
    /// Estimated cost per day; `nil` or an unpriced cost leaves the slot blank.
    let dayCosts: [MealPlanCostModel.Cost?]
    let onTap: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { dayIndex in
                let count = dayIndex < counts.count ? counts[dayIndex] : 0
                Button {
                    onTap(dayIndex)
                } label: {
                    VStack(spacing: 5) {
                        Text(String(PlannedRecipe.dayNames[dayIndex].prefix(3)))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(count > 0 ? .primary : .secondary)
                        ZStack {
                            Circle()
                                .fill(count > 0 ? Color.blue : Color(.systemGray5))
                                .frame(width: 28, height: 28)
                            if count > 0 {
                                Text("\(count)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            } else {
                                Image(systemName: "plus")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // Day's estimated cost; a blank keeps the pills level.
                        let dayCost = dayIndex < dayCosts.count ? dayCosts[dayIndex] : nil
                        Text(Self.costLabel(dayCost))
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    count > 0
                        ? "\(PlannedRecipe.dayNames[dayIndex]), \(count) meal\(count == 1 ? "" : "s"). Add another."
                        : "\(PlannedRecipe.dayNames[dayIndex]), nothing planned. Add a recipe."
                )
            }
        }
    }

    /// A blank (not empty) string keeps unpriced pills the same height.
    private static func costLabel(_ cost: MealPlanCostModel.Cost?) -> String {
        guard let cost, cost.hasAnyPrice else { return " " }
        return GroceryBudget.money(cost.total, currencyCode: cost.currencyCode)
    }
}

/// "Week's meals ≈ $82 · Still to buy ≈ $31" stat pair.
struct WeekCostRow: View {
    let weekCost: MealPlanCostModel.Cost
    let toBuyCost: MealPlanCostModel.Cost
    let isPricing: Bool

    var body: some View {
        HStack(spacing: 10) {
            stat(title: "Week's meals", cost: weekCost)
            stat(title: "Still to buy", cost: toBuyCost)
        }
    }

    private func stat(title: String, cost: MealPlanCostModel.Cost) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(cost.hasAnyPrice ? cost.text : (isPricing ? "Pricing…" : "No prices yet"))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(cost.hasAnyPrice ? Color.primary : Color.secondary)
                    .contentTransition(.numericText())
                if isPricing && !cost.isComplete {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

// MARK: - Budget

/// Budget vs. receipts spent this period plus what this plan still needs
/// buying. Without a budget, a one-tap link to set one. The budget itself is
/// personal (it lives in my settings and counts my receipts), which is why
/// the household plan shows it too: the shopping still comes out of my wallet.
struct MealPlanBudgetSection: View {

    /// One of the dearest meals, offered as the quickest place to save.
    struct PriciestMeal: Identifiable {
        let id: String
        let name: String
        let dayName: String
        let cost: MealPlanCostModel.Cost
        let onRemove: () -> Void
    }

    let toBuyCost: MealPlanCostModel.Cost
    let isPricing: Bool
    let priciest: [PriciestMeal]
    /// "your frydge" / "the household frydge".
    var frydgeNoun: String = "your frydge"

    @AppStorage(GroceryBudget.amountKey) private var budgetAmount: Double = 0
    @AppStorage(GroceryBudget.periodKey) private var budgetPeriodRaw: String = BudgetPeriod.weekly.rawValue
    @ObservedObject private var receiptStore = ReceiptStore.shared

    private var budgetPeriod: BudgetPeriod {
        BudgetPeriod(rawValue: budgetPeriodRaw) ?? .weekly
    }

    var body: some View {
        if budgetAmount > 0 {
            let spent = receiptStore.total(in: budgetPeriod.interval())
            let planned = toBuyCost.total
            let remaining = budgetAmount - spent - planned
            let tint = GroceryBudget.tint(fraction: (spent + planned) / budgetAmount)

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(
                            "\(GroceryBudget.money(budgetAmount)) \(budgetPeriod.label.lowercased())",
                            systemImage: "target"
                        )
                        .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(remaining >= 0
                             ? "\(GroceryBudget.money(remaining)) left"
                             : "\(GroceryBudget.money(-remaining)) over")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(remaining >= 0 ? Color.green : Color.red)
                            .contentTransition(.numericText())
                    }

                    BudgetProgressBar(budget: budgetAmount, spent: spent, planned: planned)

                    HStack(spacing: 14) {
                        legend(color: tint, text: "Spent \(GroceryBudget.money(spent))")
                        legend(color: tint.opacity(0.35), text: "This plan \(GroceryBudget.money(planned))")
                    }

                    Text(statusLine(spent: spent, planned: planned, remaining: remaining))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                if remaining < 0, !priciest.isEmpty {
                    ForEach(priciest) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.down.right.circle")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(entry.dayName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(entry.cost.text)
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive, action: entry.onRemove) {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }

                NavigationLink {
                    BudgetSettingsView()
                } label: {
                    Label("Adjust budget", systemImage: "slider.horizontal.3")
                        .font(.subheadline)
                }
            } header: {
                Text("Budget")
            } footer: {
                if remaining < 0, !priciest.isEmpty {
                    Text("Spent counts receipts scanned \(budgetPeriod.thisPeriodLabel). The dearest meals are listed above — swipe one away or swap it for something from \(frydgeNoun) to get back under.")
                } else {
                    Text("Spent counts receipts scanned \(budgetPeriod.thisPeriodLabel); this plan is what the week still needs buying after \(frydgeNoun) is taken off.")
                }
            }
        } else {
            Section {
                NavigationLink {
                    BudgetSettingsView()
                } label: {
                    Label("Set a grocery budget", systemImage: "target")
                }
            } footer: {
                Text("See how the week's meals stack up against a weekly, fortnightly or monthly budget before anything goes on the list.")
            }
        }
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func statusLine(spent: Double, planned: Double, remaining: Double) -> String {
        if isPricing && !toBuyCost.hasAnyPrice {
            return "Pricing the week's ingredients…"
        }
        if remaining < 0 {
            return "This plan would take you \(GroceryBudget.money(-remaining)) over \(budgetPeriod.thisPeriodLabel)."
        }
        let fraction = budgetAmount > 0 ? (spent + planned) / budgetAmount : 0
        if fraction >= 0.8 {
            return "Close to the line — \(GroceryBudget.money(remaining)) to spare once the week is bought."
        }
        if planned == 0 && spent == 0 {
            return "Nothing spent or planned yet \(budgetPeriod.thisPeriodLabel)."
        }
        return "On track — \(GroceryBudget.money(remaining)) left \(budgetPeriod.thisPeriodLabel) after this plan."
    }
}

// MARK: - Household restock

/// Recurring staples (cleaning products, foil, bin liners…) with interval
/// editing, a free-text add row and one-tap suggestions.
struct HouseholdRestockSection: View {
    let items: [RecurringHouseholdItem]
    let footer: String
    let onAdd: (_ name: String, _ interval: RestockInterval) -> Void
    let onUpdateInterval: (_ id: UUID, _ interval: RestockInterval) -> Void
    let onRemove: (_ id: UUID) -> Void

    @State private var newItemName = ""
    @State private var newItemInterval: RestockInterval = .monthly

    /// Common staples offered as one-tap adds when not already tracked.
    static let suggestions: [(name: String, interval: RestockInterval)] = [
        ("Dishwashing liquid", .monthly),
        ("Dishwasher tablets", .twoMonths),
        ("Sponges", .monthly),
        ("Bin liners", .monthly),
        ("Paper towels", .monthly),
        ("Toilet paper", .fortnightly),
        ("Laundry detergent", .twoMonths),
        ("Surface spray", .threeMonths),
        ("Aluminium foil", .threeMonths),
        ("Cling wrap", .threeMonths),
        ("Baking paper", .threeMonths)
    ]

    private var remainingSuggestions: [(name: String, interval: RestockInterval)] {
        let tracked = Set(items.map { $0.name.lowercased() })
        return Self.suggestions.filter { !tracked.contains($0.name.lowercased()) }
    }

    var body: some View {
        Section {
            ForEach(items) { item in
                HStack(spacing: 12) {
                    FoodItemThumbnail(name: item.name, width: 40, height: 40, cornerRadius: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.subheadline.weight(.medium))
                        Text(item.dueLabel())
                            .font(.caption)
                            .foregroundStyle(item.isDue() ? .red : .secondary)
                    }
                    Spacer()
                    Menu {
                        ForEach(RestockInterval.allCases) { interval in
                            Button {
                                onUpdateInterval(item.id, interval)
                            } label: {
                                if interval == item.interval {
                                    Label(interval.displayName, systemImage: "checkmark")
                                } else {
                                    Text(interval.displayName)
                                }
                            }
                        }
                    } label: {
                        Text(item.interval.displayName)
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        onRemove(item.id)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }

            // Add a custom recurring item
            HStack(spacing: 8) {
                TextField("Add item (e.g. Dish soap)", text: $newItemName)
                    .textFieldStyle(.plain)
                Menu {
                    ForEach(RestockInterval.allCases) { interval in
                        Button(interval.displayName) { newItemInterval = interval }
                    }
                } label: {
                    Text(newItemInterval.displayName)
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                Button {
                    onAdd(newItemName, newItemInterval)
                    newItemName = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.blue)
                }
                .disabled(newItemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !remainingSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(remainingSuggestions, id: \.name) { suggestion in
                            Button {
                                onAdd(suggestion.name, suggestion.interval)
                            } label: {
                                HStack(spacing: 6) {
                                    Text(FoodEmoji.emoji(for: suggestion.name))
                                        .font(.caption)
                                    Text(suggestion.name)
                                        .font(.caption)
                                    Image(systemName: "plus")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.blue)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.blue.opacity(0.1), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listRowSeparator(.hidden)
            }
        } header: {
            Text("Household Restock")
        } footer: {
            Text(footer)
        }
    }
}

// MARK: - Export

/// Plain-text dump of a week, shareable to any app or device (AirDrop,
/// Notes, Messages, email…) so the plan can move out of Frydge.
enum MealPlanExport {

    struct Entry {
        let dayIndex: Int
        let name: String
        let serves: String
        let ingredients: [String]
        let dietaryTags: [String]
        let isLeftover: Bool
        let costText: String?
    }

    static func text(
        title: String,
        entries: [Entry],
        weekCostText: String?,
        toBuyCostText: String?,
        budgetLine: String?,
        dueStaples: [String]
    ) -> String {
        var lines: [String] = [title]

        for dayIndex in 0..<7 {
            let planned = entries.filter { $0.dayIndex == dayIndex }
            guard !planned.isEmpty else { continue }
            lines.append("")
            lines.append("\(PlannedRecipe.dayNames[dayIndex]):")
            for entry in planned {
                if entry.isLeftover {
                    lines.append("• Leftovers: \(entry.name) — \(PlannedLeftover.portionsText(entry.serves))")
                    continue
                }
                let rating = RecipeHealthScore.rating(
                    ingredients: entry.ingredients,
                    dietaryTags: entry.dietaryTags
                )
                let costNote = entry.costText.map { ", \($0)" } ?? ""
                lines.append("• \(entry.name) — serves \(entry.serves), health \(rating.score)/10\(costNote)")
                for ingredient in entry.ingredients {
                    lines.append("    - \(ingredient)")
                }
            }
        }

        if weekCostText != nil || toBuyCostText != nil {
            lines.append("")
            if let weekCostText { lines.append("Week's meals: \(weekCostText)") }
            if let toBuyCostText { lines.append("Still to buy: \(toBuyCostText)") }
            if let budgetLine { lines.append(budgetLine) }
        }

        if !dueStaples.isEmpty {
            lines.append("")
            lines.append("Household restock due:")
            for name in dueStaples {
                lines.append("• \(name)")
            }
        }

        lines.append("")
        lines.append("Sent from Frydge")
        return lines.joined(separator: "\n")
    }
}
