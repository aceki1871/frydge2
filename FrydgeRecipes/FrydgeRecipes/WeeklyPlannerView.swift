//
//  WeeklyPlannerView.swift
//  FrydgeRecipes
//
//  Plan the week: assign recipes to days, keep a list of recurring household
//  staples (cleaning products etc.), and push everything you're missing to the
//  shopping list. The week is summarised up top (tap a day to add a meal),
//  and "Review & add" shows exactly what will land on the list — merged
//  across recipes and reduced by what the frydge already holds — so items can
//  be unticked before anything is added.
//

import SwiftUI
import CloudKit

struct WeeklyPlannerView: View {
    @EnvironmentObject var frydgeManager: FrydgeManager
    @EnvironmentObject var shoppingListManager: ShoppingListManager
    @EnvironmentObject var sharedFridgeManager: SharedFridgeManager
    @ObservedObject private var store = WeekPlanStore.shared
    @ObservedObject private var sharedPlanStore = SharedMealPlanStore.shared
    @StateObject private var recipeListModel = RecipeListModel()
    /// Live prices for the week's ingredients — per recipe, per day, and for
    /// what still needs buying — so the plan can be weighed against the budget.
    @StateObject private var costModel = MealPlanCostModel()
    @ObservedObject private var receiptStore = ReceiptStore.shared
    @AppStorage(GroceryBudget.amountKey) private var budgetAmount: Double = 0
    @AppStorage(GroceryBudget.periodKey) private var budgetPeriodRaw: String = BudgetPeriod.weekly.rawValue
    @Environment(\.dismiss) private var dismiss

    /// Whose week is being planned: just me (private, synced across my
    /// devices) or a household that shares a frydge (shared plan everyone sees).
    enum PlanTarget: Hashable {
        case mine
        case shared(CKRecord.ID)
    }
    @State private var planTarget: PlanTarget = .mine

    private var isSharedPlan: Bool {
        if case .shared = planTarget { return true }
        return false
    }

    private var sharedAnchor: CKRecord? {
        guard case .shared(let id) = planTarget else { return nil }
        return sharedFridgeManager.sharedFrydgeAnchors.first { $0.recordID == id }
    }

    private func scope(for anchor: CKRecord) -> SharedFridgeManager.ShareScope {
        sharedFridgeManager.owned.contains { $0.recordID == anchor.recordID } ? .owned : .incoming
    }

    // Which day the recipe picker is adding to.
    private struct DaySelection: Identifiable {
        let dayIndex: Int
        var id: Int { dayIndex }
    }
    @State private var pickerDay: DaySelection? = nil
    // Which day a recipe imported from a link is being added to.
    @State private var linkDay: DaySelection? = nil

    // Review-before-add sheet
    @State private var showReviewSheet = false

    // Result feedback
    @State private var addedSummary: String? = nil

    var body: some View {
        NavigationStack {
            List {
                if !sharedFridgeManager.sharedFrydgeAnchors.isEmpty {
                    planTargetSection
                }
                switch planTarget {
                case .mine:
                    weekOverviewSection
                    leftoversSection
                    budgetSection
                    weekSections
                    restockSection
                case .shared:
                    if let anchor = sharedAnchor {
                        SharedMealPlanSections(
                            anchor: anchor,
                            scope: scope(for: anchor),
                            recipeListModel: recipeListModel,
                            costModel: costModel
                        )
                    } else {
                        Section {
                            Text("That shared frydge isn't available right now.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(isSharedPlan ? "Household Plan" : "Weekly Plan")
            .onChange(of: sharedFridgeManager.sharedFrydgeAnchors.map(\.recordID)) { _, ids in
                // Fall back to "just me" if the selected frydge disappears
                // (share revoked, frydge deleted).
                if case .shared(let id) = planTarget, !ids.contains(id) {
                    planTarget = .mine
                }
            }
            .alert("Household plan", isPresented: Binding(
                get: { sharedPlanStore.errorMessage != nil },
                set: { if !$0 { sharedPlanStore.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { sharedPlanStore.errorMessage = nil }
            } message: {
                Text(sharedPlanStore.errorMessage ?? "")
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .secondaryAction) {
                    ShareLink(
                        item: exportText(),
                        subject: Text(isSharedPlan ? "Household Meal Plan" : "Weekly Meal Plan"),
                        preview: SharePreview(isSharedPlan ? "Household Meal Plan" : "Weekly Meal Plan",
                                              image: Image(systemName: "calendar"))
                    ) {
                        Label("Export plan", systemImage: "square.and.arrow.up")
                    }
                    .disabled(clearWeekDisabled)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Clear week", role: .destructive) {
                        if let anchor = sharedAnchor {
                            Task { await sharedPlanStore.clearWeek(for: anchor, scope: scope(for: anchor)) }
                        } else {
                            store.clearWeek()
                        }
                    }
                    .disabled(clearWeekDisabled)
                }
            }
            .safeAreaInset(edge: .bottom) {
                // The household plan has its own "add & notify" button inline.
                if !isSharedPlan {
                    reviewButton
                }
            }
            .sheet(item: $pickerDay) { day in
                RecipePickerSheet(
                    model: recipeListModel,
                    title: "Add to \(PlannedRecipe.dayNames[day.dayIndex])"
                ) { recipe in
                    store.addRecipe(recipe, to: day.dayIndex)
                }
            }
            .sheet(item: $linkDay) { day in
                RecipeLinkImportSheet(
                    title: "Add to \(PlannedRecipe.dayNames[day.dayIndex])"
                ) { recipe in
                    store.addRecipe(recipe, to: day.dayIndex)
                    // Pull the freshly saved recipe into the list so its photo resolves.
                    Task { await recipeListModel.fetchRecipesFromCloud() }
                }
            }
            .sheet(isPresented: $showReviewSheet) {
                let needs = computeNeeds()
                PlanReviewSheet(
                    lines: needs.toBuy,
                    covered: needs.inFrydge,
                    alreadyListed: needs.onList,
                    staples: dueStaplesNotOnList(),
                    currencyCode: costModel.currencyCode,
                    priceFor: { costModel.price(for: $0) }
                ) { lines, staples in
                    addToShoppingList(lines: lines, staples: staples)
                }
            }
            .alert("Added to Shopping List", isPresented: Binding(
                get: { addedSummary != nil },
                set: { if !$0 { addedSummary = nil } }
            )) {
                Button("OK", role: .cancel) { addedSummary = nil }
            } message: {
                Text(addedSummary ?? "")
            }
            .task {
                costModel.refresh(ingredientLines: store.plannedRecipes.flatMap(\.ingredients))
                await receiptStore.load()
                await recipeListModel.fetchIfStale()
            }
            // Price anything newly added to the week; already-priced
            // ingredients are skipped inside the model.
            .onChange(of: store.plannedRecipes) { _, plans in
                costModel.refresh(ingredientLines: plans.flatMap(\.ingredients))
            }
        }
    }

    private var clearWeekDisabled: Bool {
        if let anchor = sharedAnchor {
            return sharedPlanStore.meals(for: anchor.recordID).isEmpty
        }
        return store.plannedRecipes.isEmpty
    }

    // MARK: - Plan target (me vs. a household)

    private var planTargetSection: some View {
        Section {
            Picker(selection: $planTarget) {
                Label("Just me", systemImage: "person").tag(PlanTarget.mine)
                ForEach(sharedFridgeManager.sharedFrydgeAnchors, id: \.recordID) { anchor in
                    let name = sharedFridgeManager.namesByFridge[anchor.recordID]
                        ?? (anchor["name"] as? String ?? "Shared Frydge")
                    let emoji = sharedFridgeManager.emojiByFridge[anchor.recordID]
                        ?? (anchor["emoji"] as? String ?? "🧊")
                    Text("\(emoji) \(name)").tag(PlanTarget.shared(anchor.recordID))
                }
            } label: {
                Label("Plan for", systemImage: "person.2")
            }
            .pickerStyle(.menu)
        } footer: {
            if isSharedPlan {
                Text("Everyone who shares this frydge sees and can edit this week.")
            }
        }
    }

    // MARK: - Week overview

    /// Seven day pills with meal counts plus a one-line summary of what the
    /// plan needs. Tapping a pill jumps straight to the recipe picker for
    /// that day, so filling the week doesn't mean scrolling seven sections.
    private var weekOverviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                WeekOverviewPills(
                    counts: (0..<7).map { store.recipes(for: $0).count },
                    dayCosts: (0..<7).map { costModel.cost(of: store.recipes(for: $0)) }
                ) { dayIndex in
                    pickerDay = DaySelection(dayIndex: dayIndex)
                }

                Text(overviewSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !store.plannedRecipes.isEmpty {
                    WeekCostRow(
                        weekCost: costModel.cost(of: store.plannedRecipes),
                        toBuyCost: toBuyCost,
                        isPricing: costModel.isLoading
                    )
                }
            }
            .padding(.vertical, 4)
        } footer: {
            if store.plannedRecipes.isEmpty {
                Text("Tap a day to add a recipe, or use \"Add recipe\" under each day.")
            }
        }
    }

    private var overviewSummary: String {
        let meals = store.plannedRecipes.count
        guard meals > 0 else { return "No meals planned yet." }

        let needs = computeNeeds()
        let due = dueStaplesNotOnList().count
        let leftoverNights = store.plannedRecipes.filter(\.isLeftover).count
        var parts = ["\(meals) meal\(meals == 1 ? "" : "s") planned"]
        if leftoverNights > 0 {
            parts.append("\(leftoverNights) leftover night\(leftoverNights == 1 ? "" : "s")")
        }
        if !needs.toBuy.isEmpty {
            parts.append("\(needs.toBuy.count) to buy")
        }
        if !needs.inFrydge.isEmpty {
            parts.append("\(needs.inFrydge.count) in your frydge")
        }
        if due > 0 {
            parts.append("\(due) staple\(due == 1 ? "" : "s") due")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Costs & budget

    private var budgetPeriod: BudgetPeriod {
        BudgetPeriod(rawValue: budgetPeriodRaw) ?? .weekly
    }

    /// What the week's "to buy" lines would cost: merged across recipes and
    /// reduced by the frydge, so it's the number that actually hits the budget.
    private var toBuyCost: MealPlanCostModel.Cost {
        costModel.cost(ofNeeds: computeNeeds().toBuy)
    }

    /// The three dearest meals this week — the quickest place to save if the
    /// plan is running over.
    private var priciestMeals: [MealPlanBudgetSection.PriciestMeal] {
        store.plannedRecipes
            .map { (plan: $0, cost: costModel.cost(of: $0)) }
            .filter { $0.cost.hasAnyPrice }
            .sorted { $0.cost.total > $1.cost.total }
            .prefix(3)
            .map { entry in
                MealPlanBudgetSection.PriciestMeal(
                    id: entry.plan.id.uuidString,
                    name: entry.plan.recipeName,
                    dayName: entry.plan.dayName,
                    cost: entry.cost
                ) {
                    store.removePlanned(id: entry.plan.id)
                }
            }
    }

    /// Budget vs. receipts spent this period plus what this plan still needs
    /// buying. Shared with the household plan (MealPlanBudgetSection).
    private var budgetSection: some View {
        MealPlanBudgetSection(
            toBuyCost: toBuyCost,
            isPricing: costModel.isLoading,
            priciest: priciestMeals
        )
    }

    // MARK: - Week sections

    @ViewBuilder
    private var weekSections: some View {
        ForEach(0..<7, id: \.self) { dayIndex in
            Section {
                let planned = store.recipes(for: dayIndex)
                ForEach(planned) { plan in
                    Group {
                        if plan.isLeftover {
                            PlannedLeftoverRow(
                                name: plan.recipeName,
                                serves: plan.serves,
                                dayIndex: dayIndex,
                                live: liveLeftover(for: plan)
                            )
                        } else {
                            recipeRow(plan)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.removePlanned(id: plan.id)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
                Menu {
                    Button {
                        pickerDay = DaySelection(dayIndex: dayIndex)
                    } label: {
                        Label("From my recipes", systemImage: "book")
                    }
                    Button {
                        linkDay = DaySelection(dayIndex: dayIndex)
                    } label: {
                        Label("From a link", systemImage: "link")
                    }
                    LeftoverPickMenu(leftovers: frydgeLeftovers, dayIndex: dayIndex) { leftover in
                        store.addLeftover(leftover, to: dayIndex)
                    }
                } label: {
                    Label("Add meal", systemImage: "plus.circle")
                        .font(.subheadline)
                }
            } header: {
                dayHeader(dayIndex)
            }
        }
    }

    private func recipeRow(_ plan: PlannedRecipe) -> some View {
        HStack(spacing: 12) {
            RecipeThumbnailView(
                recipeID: plan.recipeID,
                recipeName: plan.recipeName,
                imageSourceURL: imageSourceURL(for: plan),
                size: 64
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(plan.recipeName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text("\(plan.ingredients.count) ingredient\(plan.ingredients.count == 1 ? "" : "s") · serves \(plan.serves)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let costText = costLine(for: plan) {
                    Text(costText)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.green)
                        .contentTransition(.numericText())
                }
                HealthScoreBadge(
                    rating: RecipeHealthScore.rating(
                        ingredients: plan.ingredients,
                        dietaryTags: plan.dietaryTags
                    )
                )
            }
        }
    }

    // MARK: - Leftovers

    /// Unexpired leftovers in my frydge, soonest use-by first.
    private var frydgeLeftovers: [PlannableLeftover] {
        frydgeManager.leftovers
            .map(PlannableLeftover.init(stored:))
            .filter { !$0.isExpired }
    }

    /// Leftovers that aren't on the plan yet.
    private var unplannedLeftovers: [PlannableLeftover] {
        let planned = store.plannedLeftoverItemIDs
        return frydgeLeftovers.filter { !planned.contains($0.id) }
    }

    private var leftoversSection: some View {
        LeftoversToUseSection(leftovers: unplannedLeftovers) { leftover, dayIndex in
            store.addLeftover(leftover, to: dayIndex)
        }
    }

    /// The frydge item a planned leftover points at, if it's still there.
    private func liveLeftover(for plan: PlannedRecipe) -> PlannableLeftover? {
        guard let itemID = plan.leftoverItemID else { return nil }
        return frydgeManager.leftovers
            .first { $0.id.uuidString == itemID }
            .map(PlannableLeftover.init(stored:))
    }

    /// Day name with the day's estimated cost on the trailing edge.
    private func dayHeader(_ dayIndex: Int) -> some View {
        let cost = costModel.cost(of: store.recipes(for: dayIndex))
        return HStack {
            Text(PlannedRecipe.dayNames[dayIndex])
            Spacer()
            if cost.hasAnyPrice {
                Text(cost.text)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
    }

    /// "≈ $14.20 · $3.55 a serve" for a planned recipe, "Pricing…" while the
    /// feed is still answering, nil when nothing could be priced.
    private func costLine(for plan: PlannedRecipe) -> String? {
        let cost = costModel.cost(of: plan)
        if cost.hasAnyPrice {
            var parts = [cost.text]
            if let perServe = costModel.perServeText(for: plan) {
                parts.append(perServe)
            }
            return parts.joined(separator: " · ")
        }
        return costModel.isLoading ? "Pricing…" : nil
    }

    /// The plan snapshot doesn't store the photo; resolve it from the live
    /// recipe list by ID (falls back to the emoji placeholder if the recipe
    /// was deleted or hasn't synced yet).
    private func imageSourceURL(for plan: PlannedRecipe) -> String? {
        recipeListModel.recipes.first { $0.id == plan.recipeID }?.imageSourceURL
    }

    // MARK: - Export

    /// Plain-text dump of the week, shareable to any app or device (AirDrop,
    /// Notes, Messages, email…) so the plan can move out of Frydge.
    private func exportText() -> String {
        let title: String
        let entries: [MealPlanExport.Entry]
        let weekCost: MealPlanCostModel.Cost
        let buyCost: MealPlanCostModel.Cost?
        let dueStaples: [String]

        if let anchor = sharedAnchor {
            let meals = sharedPlanStore.meals(for: anchor.recordID)
            let fridgeName = sharedFridgeManager.namesByFridge[anchor.recordID]
                ?? (anchor["name"] as? String)
                ?? "Household"
            title = "\(fridgeName) Meal Plan"
            entries = meals.map { meal in
                let cost = costModel.cost(ofLines: meal.ingredients)
                return MealPlanExport.Entry(
                    dayIndex: meal.dayIndex,
                    name: meal.recipeName,
                    serves: meal.serves,
                    ingredients: meal.ingredients,
                    dietaryTags: meal.dietaryTags,
                    isLeftover: meal.isLeftover,
                    costText: cost.hasAnyPrice ? cost.text : nil
                )
            }
            weekCost = costModel.cost(ofLines: meals.flatMap(\.ingredients))
            // "Still to buy" depends on the shared frydge's stock, which the
            // household sections compute; the export keeps to what it knows.
            buyCost = nil
            dueStaples = sharedPlanStore.dueStaples(for: anchor.recordID).map(\.name)
        } else {
            title = "Weekly Meal Plan"
            entries = store.plannedRecipes.map { plan in
                let cost = costModel.cost(of: plan)
                return MealPlanExport.Entry(
                    dayIndex: plan.dayIndex,
                    name: plan.recipeName,
                    serves: plan.serves,
                    ingredients: plan.ingredients,
                    dietaryTags: plan.dietaryTags,
                    isLeftover: plan.isLeftover,
                    costText: cost.hasAnyPrice ? cost.text : nil
                )
            }
            weekCost = costModel.cost(of: store.plannedRecipes)
            buyCost = toBuyCost
            dueStaples = store.dueRecurringItems().map(\.name)
        }

        let budgetLine = budgetAmount > 0
            ? "Budget: \(GroceryBudget.money(budgetAmount)) \(budgetPeriod.label.lowercased())"
            : nil

        return MealPlanExport.text(
            title: title,
            entries: entries,
            weekCostText: weekCost.hasAnyPrice ? weekCost.text : nil,
            toBuyCostText: buyCost.flatMap { $0.hasAnyPrice ? $0.text : nil },
            budgetLine: budgetLine,
            dueStaples: dueStaples
        )
    }

    // MARK: - Household restock section

    /// Shared with the household plan (HouseholdRestockSection); here it is
    /// backed by my own synced WeekPlanStore list.
    private var restockSection: some View {
        HouseholdRestockSection(
            items: store.recurringItems,
            footer: "Staples like cleaning products are re-added to your shopping list when they fall due.",
            onAdd: { name, interval in store.addRecurring(name: name, interval: interval) },
            onUpdateInterval: { id, interval in store.updateInterval(id: id, interval: interval) },
            onRemove: { id in store.removeRecurring(id: id) }
        )
    }

    // MARK: - Review & add button

    private var reviewButton: some View {
        let needs = computeNeeds()
        let due = dueStaplesNotOnList()
        let total = needs.toBuy.count + due.count

        return Button {
            showReviewSheet = true
        } label: {
            Label(
                total == 0 ? "Everything covered" : "Review & add \(total) item\(total == 1 ? "" : "s")",
                systemImage: "cart.badge.plus"
            )
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .disabled(total == 0)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    // MARK: - Aggregation

    /// The week's recipes in the shape the needs calculator wants.
    private var plannedMeals: [MealPlanNeeds.Meal] {
        store.plannedRecipes.map {
            MealPlanNeeds.Meal(
                recipeName: $0.recipeName,
                dayIndex: $0.dayIndex,
                ingredients: $0.ingredients,
                dietaryTags: $0.dietaryTags
            )
        }
    }

    /// What's in my frydge right now. Leftovers are skipped: they're meals,
    /// not ingredients.
    private var fridgeStock: [MealPlanNeeds.StockItem] {
        frydgeManager.storedIngredients
            .filter { $0.lifecycle == .fridge }
            .map {
                MealPlanNeeds.StockItem(
                    name: $0.name,
                    quantity: $0.quantity,
                    unit: $0.unit,
                    quantityUsed: $0.quantityUsed,
                    isExpired: $0.isExpired
                )
            }
    }

    /// Ingredients merged across the week (two recipes wanting 200 g and
    /// 300 g of mince become 500 g), split into covered / to buy / on list.
    /// Same calculator the household plan uses, so both agree.
    private func computeNeeds() -> MealPlanNeeds.Result {
        MealPlanNeeds.compute(
            meals: plannedMeals,
            stock: fridgeStock,
            shoppingListNames: shoppingListManager.shoppingListItems.map(\.name)
        )
    }

    private func dueStaplesNotOnList() -> [RecurringHouseholdItem] {
        store.dueRecurringItems().filter { !shoppingListManager.isInShoppingList($0.name) }
    }

    private func addToShoppingList(lines: [MealPlanNeeds.Line], staples: [RecurringHouseholdItem]) {
        for line in lines {
            // ShoppingListManager rounds this up to a purchasable pack size.
            shoppingListManager.addToShoppingList(
                name: line.name,
                quantity: line.purchaseQuantity,
                unit: line.purchaseUnit,
                dietaryTags: line.dietaryTags
            )
        }
        for staple in staples {
            shoppingListManager.addToShoppingList(
                name: staple.name,
                quantity: staple.quantity,
                unit: staple.unit
            )
        }
        store.markAddedToList(ids: Set(staples.map { $0.id }))

        var parts: [String] = []
        if !lines.isEmpty { parts.append("\(lines.count) recipe ingredient\(lines.count == 1 ? "" : "s")") }
        if !staples.isEmpty { parts.append("\(staples.count) household item\(staples.count == 1 ? "" : "s")") }
        guard !parts.isEmpty else { return }
        addedSummary = "Added " + parts.joined(separator: " and ") + "."
    }
}

// MARK: - Review sheet

/// Shows exactly what "Review & add" will put on the shopping list, with a
/// photo and the merged amount per ingredient. Everything starts ticked;
/// untick anything you don't want before confirming. Used by both the
/// personal and the household plan.
struct PlanReviewSheet: View {
    let lines: [MealPlanNeeds.Line]
    let covered: [MealPlanNeeds.Line]
    let alreadyListed: [MealPlanNeeds.Line]
    let staples: [RecurringHouseholdItem]
    let currencyCode: String
    /// Best known price for a line, so the sheet can total what's ticked.
    let priceFor: (MealPlanNeeds.Line) -> Double?
    /// Where the items are going, for the confirm button ("to Shopping List").
    var destinationName: String = "Shopping List"
    /// "your frydge" / "the household frydge" in the skipped-items notes.
    var frydgeNoun: String = "your frydge"
    let onConfirm: (_ lines: [MealPlanNeeds.Line], _ staples: [RecurringHouseholdItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var excludedLineKeys: Set<String> = []
    @State private var excludedStapleIDs: Set<UUID> = []
    @State private var showCovered = false

    private var selectedLines: [MealPlanNeeds.Line] {
        lines.filter { !excludedLineKeys.contains($0.key) }
    }

    private var selectedStaples: [RecurringHouseholdItem] {
        staples.filter { !excludedStapleIDs.contains($0.id) }
    }

    private var selectedCount: Int { selectedLines.count + selectedStaples.count }

    /// Estimated spend for the ticked recipe lines; nil when none are priced.
    private var selectedTotalText: String? {
        let priced = selectedLines.compactMap(priceFor)
        guard !priced.isEmpty else { return nil }
        let total = priced.reduce(0, +)
        let prefix = priced.count < selectedLines.count ? "≈ " : ""
        let suffix = priced.count < selectedLines.count ? "+" : ""
        return prefix + GroceryBudget.money(total, currencyCode: currencyCode) + suffix
    }

    var body: some View {
        NavigationStack {
            List {
                if !lines.isEmpty {
                    Section {
                        ForEach(lines) { line in
                            reviewRow(isOn: !excludedLineKeys.contains(line.key)) {
                                toggle(line.key, in: &excludedLineKeys)
                            } content: {
                                FoodItemThumbnail(name: line.name, width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.name)
                                        .font(.subheadline.weight(.medium))
                                    Text(detail(for: line))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                if case .partial = line.status {
                                    Text("Top up")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Color.orange.opacity(0.15), in: Capsule())
                                }
                                if let price = priceFor(line) {
                                    Text(GroceryBudget.money(price, currencyCode: currencyCode))
                                        .font(.caption.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Recipe ingredients")
                            Spacer()
                            if let total = selectedTotalText {
                                Text(total)
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                            }
                        }
                    } footer: {
                        Text("Amounts are merged across the week's recipes and reduced by what's already in \(frydgeNoun). Prices are the best known offer per item.")
                    }
                }

                if !staples.isEmpty {
                    Section("Household restock due") {
                        ForEach(staples) { staple in
                            reviewRow(isOn: !excludedStapleIDs.contains(staple.id)) {
                                toggle(staple.id, in: &excludedStapleIDs)
                            } content: {
                                FoodItemThumbnail(name: staple.name, width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(staple.name)
                                        .font(.subheadline.weight(.medium))
                                    Text(staple.interval.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                            }
                        }
                    }
                }

                if !covered.isEmpty || !alreadyListed.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showCovered) {
                            ForEach(covered) { line in
                                skippedRow(line, note: "In \(frydgeNoun)", systemImage: "refrigerator")
                            }
                            ForEach(alreadyListed) { line in
                                skippedRow(line, note: "Already on the list", systemImage: "checklist")
                            }
                        } label: {
                            Text("Skipped · \(covered.count + alreadyListed.count) already covered")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Review items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onConfirm(selectedLines, selectedStaples)
                    dismiss()
                } label: {
                    Label(
                        selectedCount == 0
                            ? "Nothing selected"
                            : "Add \(selectedCount) item\(selectedCount == 1 ? "" : "s")"
                              + (selectedTotalText.map { " · \($0)" } ?? "")
                              + " to \(destinationName)",
                        systemImage: "cart.badge.plus"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCount == 0)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .background(.ultraThinMaterial)
            }
        }
    }

    @ViewBuilder
    private func reviewRow<Content: View>(
        isOn: Bool,
        onToggle: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? Color.blue : Color.secondary)
                content()
            }
            .contentShape(Rectangle())
            .opacity(isOn ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func skippedRow(_ line: MealPlanNeeds.Line, note: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(line.name)
                .font(.subheadline)
            Spacer()
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func detail(for line: MealPlanNeeds.Line) -> String {
        var parts: [String] = []
        let amount = [line.purchaseQuantity, line.purchaseUnit]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !amount.isEmpty { parts.append(amount) }
        if !line.recipeNames.isEmpty {
            let shown = line.recipeNames.prefix(2).joined(separator: ", ")
            let extra = line.recipeNames.count - min(2, line.recipeNames.count)
            parts.append("for " + shown + (extra > 0 ? " +\(extra)" : ""))
        }
        return parts.joined(separator: " · ")
    }

    private func toggle<T: Hashable>(_ value: T, in set: inout Set<T>) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }
}
