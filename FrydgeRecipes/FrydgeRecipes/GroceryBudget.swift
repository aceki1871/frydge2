//
//  GroceryBudget.swift
//  FrydgeRecipes
//
//  A simple grocery budget set from the Profile tab. "Spent" comes from the
//  receipts the user has scanned this period; "planned" is the priced
//  estimate of what's on the shopping list right now. The shopping list
//  shows a compact bar of both against the budget so it's obvious before
//  checkout whether this shop stays within it.
//

import SwiftUI

// MARK: - Period

enum BudgetPeriod: String, CaseIterable, Identifiable {
    case weekly
    case fortnightly
    case monthly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .weekly:      return "Weekly"
        case .fortnightly: return "Fortnightly"
        case .monthly:     return "Monthly"
        }
    }

    /// "per week" style suffix for compact labels.
    var shortLabel: String {
        switch self {
        case .weekly:      return "wk"
        case .fortnightly: return "fortnight"
        case .monthly:     return "mo"
        }
    }

    /// "this week" / "this fortnight" / "this month".
    var thisPeriodLabel: String {
        switch self {
        case .weekly:      return "this week"
        case .fortnightly: return "this fortnight"
        case .monthly:     return "this month"
        }
    }

    /// The budget window containing `date`. Fortnights are anchored to a
    /// fixed Monday so they don't drift as the weeks roll over.
    func interval(containing date: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        switch self {
        case .weekly:
            return calendar.dateInterval(of: .weekOfYear, for: date)
                ?? DateInterval(start: date, duration: 7 * 86_400)
        case .monthly:
            return calendar.dateInterval(of: .month, for: date)
                ?? DateInterval(start: date, duration: 30 * 86_400)
        case .fortnightly:
            let week = calendar.dateInterval(of: .weekOfYear, for: date)
                ?? DateInterval(start: date, duration: 7 * 86_400)
            // 1 Jan 2024 was a Monday; count whole weeks since then.
            let anchor = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)) ?? week.start
            let weeksSinceAnchor = Int((week.start.timeIntervalSince(anchor) / (7 * 86_400)).rounded(.down))
            let start = weeksSinceAnchor.isMultiple(of: 2)
                ? week.start
                : (calendar.date(byAdding: .weekOfYear, value: -1, to: week.start) ?? week.start)
            let end = calendar.date(byAdding: .weekOfYear, value: 2, to: start) ?? start.addingTimeInterval(14 * 86_400)
            return DateInterval(start: start, end: end)
        }
    }
}

// MARK: - Budget settings

enum GroceryBudget {
    static let amountKey = "frydge.budget.amount"
    static let periodKey = "frydge.budget.period"

    static var amount: Double {
        UserDefaults.standard.double(forKey: amountKey)
    }

    static var period: BudgetPeriod {
        BudgetPeriod(rawValue: UserDefaults.standard.string(forKey: periodKey) ?? "") ?? .weekly
    }

    /// A budget is "on" once an amount has been entered.
    static var isSet: Bool { amount > 0 }

    /// Receipt spend inside the current budget window. Main-actor because
    /// `ReceiptStore` is.
    @MainActor
    static func spent(period: BudgetPeriod, receipts: ReceiptStore) -> Double {
        receipts.total(in: period.interval())
    }

    /// "$150" / "$62.50" — whole dollars drop the cents.
    static func money(_ value: Double, currencyCode: String = "NZD") -> String {
        let isWhole = value.truncatingRemainder(dividingBy: 1) == 0
        return value.formatted(.currency(code: currencyCode).precision(.fractionLength(isWhole ? 0 : 2)))
    }

    /// Traffic-light colour for how much of the budget is committed.
    static func tint(fraction: Double) -> Color {
        if fraction >= 1 { return .red }
        if fraction >= 0.8 { return .orange }
        return .green
    }
}

// MARK: - Progress bar

/// Spent (solid) and planned (lighter) stacked against the budget.
struct BudgetProgressBar: View {
    let budget: Double
    let spent: Double
    let planned: Double
    var compact = false

    private var spentFraction: Double { budget > 0 ? min(spent / budget, 1) : 0 }
    private var plannedFraction: Double { budget > 0 ? min((spent + planned) / budget, 1) : 0 }
    private var committedFraction: Double { budget > 0 ? (spent + planned) / budget : 0 }

    var body: some View {
        let tint = GroceryBudget.tint(fraction: committedFraction)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint.opacity(0.35))
                    .frame(width: geo.size.width * plannedFraction)
                Capsule()
                    .fill(tint)
                    .frame(width: geo.size.width * spentFraction)
            }
            .animation(.easeInOut(duration: 0.3), value: spent + planned)
        }
        .frame(height: compact ? 4 : 8)
        .accessibilityElement()
        .accessibilityLabel("Budget progress")
        .accessibilityValue("\(Int((committedFraction * 100).rounded())) percent committed")
    }
}

// MARK: - Settings screen (Profile → Grocery Budget)

struct BudgetSettingsView: View {
    @AppStorage(GroceryBudget.amountKey) private var amount: Double = 0
    @AppStorage(GroceryBudget.periodKey) private var periodRaw: String = BudgetPeriod.weekly.rawValue
    @ObservedObject private var receipts = ReceiptStore.shared
    @FocusState private var amountFocused: Bool

    private var period: BudgetPeriod {
        BudgetPeriod(rawValue: periodRaw) ?? .weekly
    }

    private var currencyCode: String {
        receipts.receipts.first?.currencyCode ?? "NZD"
    }

    private var spent: Double {
        GroceryBudget.spent(period: period, receipts: receipts)
    }

    /// Priced estimate of the current shopping list, from the widget snapshot
    /// the app keeps up to date.
    private var planned: Double {
        WidgetSnapshot.read().estimatedTotal?.value ?? 0
    }

    private var remaining: Double { amount - spent - planned }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Budget")
                    Spacer()
                    TextField("0", value: $amount, format: .number.precision(.fractionLength(0...2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($amountFocused)
                        .frame(maxWidth: 140)
                        .accessibilityLabel("Budget amount")
                }
                Picker("Period", selection: $periodRaw) {
                    ForEach(BudgetPeriod.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Grocery budget")
            } footer: {
                Text("How much you'd like to spend on groceries each \(period.shortLabel == "mo" ? "month" : period.shortLabel == "wk" ? "week" : "fortnight"). Set it to 0 to turn the budget off.")
            }

            if amount > 0 {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            statCard(title: "Spent", value: spent, caption: "from receipts")
                            statCard(title: "On your list", value: planned, caption: "priced estimate")
                            statCard(
                                title: remaining >= 0 ? "Left" : "Over",
                                value: abs(remaining),
                                caption: remaining >= 0 ? "after this shop" : "if you buy it all",
                                tint: remaining >= 0 ? nil : .red
                            )
                        }

                        BudgetProgressBar(budget: amount, spent: spent, planned: planned)

                        Text(statusLine)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("\(period.thisPeriodLabel.capitalized) · \(GroceryBudget.money(amount, currencyCode: currencyCode))")
                } footer: {
                    Text("Spent counts the receipts you've scanned \(period.thisPeriodLabel). Your shopping list total is the estimate at the nearest store with prices, so it changes as you add or tick off items.")
                }

                Section("Ways to stay under") {
                    ForEach(tips, id: \.self) { tip in
                        Label(tip, systemImage: "lightbulb")
                            .font(.subheadline)
                    }
                }
            }
        }
        .navigationTitle("Grocery Budget")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { amountFocused = false }
            }
        }
        .task { await receipts.load() }
    }

    private func statCard(title: String, value: Double, caption: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(GroceryBudget.money(value, currencyCode: currencyCode))
                .font(.headline.monospacedDigit())
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var statusLine: String {
        let committed = amount > 0 ? (spent + planned) / amount : 0
        if committed >= 1 {
            return "This shop would take you \(GroceryBudget.money(abs(remaining), currencyCode: currencyCode)) over budget."
        }
        if committed >= 0.8 {
            return "Close to the line — \(GroceryBudget.money(remaining, currencyCode: currencyCode)) to spare once the list is bought."
        }
        if spent == 0 && planned == 0 {
            return "Nothing spent or planned yet \(period.thisPeriodLabel)."
        }
        return "On track — \(GroceryBudget.money(remaining, currencyCode: currencyCode)) left \(period.thisPeriodLabel) after this list."
    }

    /// Short, situational nudges rather than a lecture.
    private var tips: [String] {
        var tips: [String] = []
        if planned > 0 && spent + planned > amount {
            tips.append("Sort the shopping list by price, high to low, to spot the few items doing most of the damage.")
        }
        tips.append("Scan each receipt after a shop so \"Spent\" stays accurate.")
        tips.append("Check the Frydge tab before adding to the list — Use it up suggests recipes from what you already have.")
        tips.append("Tap a priced item on the list to compare stores before you buy.")
        return tips
    }
}
