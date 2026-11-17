//
//  SharedMealPlanSections.swift
//  FrydgeRecipes
//
//  The household half of the Weekly Plan sheet. Shows one shared frydge's meal
//  plan (everyone who shares the frydge sees the same week), works out which
//  ingredients are already in that frydge versus what needs buying, lets the
//  shortfall be reviewed and pushed onto a shopping list, and posts a notice so
//  every member gets a notification describing the split.
//
//  Mirrors the personal planner feature for feature — week overview, costs
//  and budget, leftovers, household restock staples, review-before-add — by
//  reusing the same components (MealPlanComponents.swift) backed by
//  SharedMealPlanStore instead of WeekPlanStore.
//
//  Designed to sit inside the planner's List, so the body is a Group of
//  Sections rather than its own container.
//

import SwiftUI
import CloudKit

struct SharedMealPlanSections: View {
    let anchor: CKRecord
    let scope: SharedFridgeManager.ShareScope
    @ObservedObject var recipeListModel: RecipeListModel
    /// Shared with the personal planner so prices fetched once serve both.
    @ObservedObject var costModel: MealPlanCostModel

    @EnvironmentObject var sharedFridgeManager: SharedFridgeManager
    @EnvironmentObject var sharedShoppingListManager: SharedShoppingListManager
    @EnvironmentObject var shoppingListManager: ShoppingListManager
    @ObservedObject private var store = SharedMealPlanStore.shared

    /// Where the "to buy" items go.
    enum ListTarget: Hashable {
        case mine
        case shared(CKRecord.ID)
    }

    private struct DaySelection: Identifiable {
        let dayIndex: Int
        var id: Int { dayIndex }
    }

    @State private var listTarget: ListTarget? = nil
    @State private var pickerDay: DaySelection? = nil
    // Which day a recipe imported from a link is being added to.
    @State private var linkDay: DaySelection? = nil
    @State private var isSending = false
    @State private var resultMessage: String? = nil
    @State private var showBreakdown = false
    @State private var showReviewSheet = false

    private let frydgeNoun = "the household frydge"

    // MARK: - Body

    var body: some View {
        Group {
            overviewSection
            LeftoversToUseSection(leftovers: unplannedLeftovers) { leftover, dayIndex in
                Task { await add(leftover, to: dayIndex) }
            }
            MealPlanBudgetSection(
                toBuyCost: toBuyCost,
                isPricing: costModel.isLoading,
                priciest: priciestMeals,
                frydgeNoun: frydgeNoun
            )
            ForEach(0..<7, id: \.self) { dayIndex in
                daySection(dayIndex)
            }
            restockSection
        }
    }

    // MARK: - Overview / actions

    private var overviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                WeekOverviewPills(
                    counts: (0..<7).map { store.meals(for: anchor.recordID, dayIndex: $0).count },
                    dayCosts: (0..<7).map { dayCost($0) }
                ) { dayIndex in
                    pickerDay = DaySelection(dayIndex: dayIndex)
                }

                Text(overviewSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !meals.isEmpty {
                    WeekCostRow(
                        weekCost: weekCost,
                        toBuyCost: toBuyCost,
                        isPricing: costModel.isLoading
                    )

                    let result = needs
                    HStack(spacing: 14) {
                        statPill(count: result.inFrydge.count, label: "in the frydge", color: .green, icon: "refrigerator")
                        statPill(count: result.toBuy.count, label: "to buy", color: .orange, icon: "cart")
                        if !result.onList.isEmpty {
                            statPill(count: result.onList.count, label: "on list", color: .blue, icon: "checklist")
                        }
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showBreakdown.toggle() }
                    } label: {
                        Label(showBreakdown ? "Hide breakdown" : "Show breakdown",
                              systemImage: showBreakdown ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)

                    if showBreakdown {
                        breakdown(result)
                    }
                }
            }
            .padding(.vertical, 4)
            // One anchor for loading and presentation. Attaching these to the
            // Group would run them once per section.
            .task(id: anchor.recordID) {
                await sharedFridgeManager.loadItems(for: anchor, scope: scope)
                await store.loadMeals(for: anchor, scope: scope)
                await store.loadStaples(for: anchor, scope: scope)
                if sharedShoppingListManager.sharedAnchors.isEmpty {
                    await sharedShoppingListManager.refreshSharedLists()
                }
                if listTarget == nil {
                    // Default to the first shared list so the whole household sees it.
                    if let first = sharedShoppingListManager.sharedAnchors.first {
                        listTarget = .shared(first.recordID)
                    } else {
                        listTarget = .mine
                    }
                }
                costModel.refresh(ingredientLines: meals.flatMap(\.ingredients))
            }
            // Price anything newly planned; already-priced ingredients are
            // skipped inside the model.
            .onChange(of: meals) { _, plans in
                costModel.refresh(ingredientLines: plans.flatMap(\.ingredients))
            }
            .sheet(item: $pickerDay) { day in
                RecipePickerSheet(
                    model: recipeListModel,
                    title: "Add to \(PlannedRecipe.dayNames[day.dayIndex])"
                ) { recipe in
                    Task { await add(recipe, to: day.dayIndex) }
                }
            }
            .sheet(item: $linkDay) { day in
                RecipeLinkImportSheet(
                    title: "Add to \(PlannedRecipe.dayNames[day.dayIndex])"
                ) { recipe in
                    Task {
                        await add(recipe, to: day.dayIndex)
                        await recipeListModel.fetchRecipesFromCloud()
                    }
                }
            }
            .sheet(isPresented: $showReviewSheet) {
                let result = needs
                PlanReviewSheet(
                    lines: result.toBuy,
                    covered: result.inFrydge,
                    alreadyListed: result.onList,
                    staples: dueStaplesNotOnList,
                    currencyCode: costModel.currencyCode,
                    priceFor: { costModel.price(for: $0) },
                    destinationName: selectedListName,
                    frydgeNoun: frydgeNoun
                ) { lines, staples in
                    Task { await sendToShoppingList(lines: lines, staples: staples) }
                }
            }
            .alert("Household plan updated", isPresented: Binding(
                get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil } }
            )) {
                Button("OK", role: .cancel) { resultMessage = nil }
            } message: {
                Text(resultMessage ?? "")
            }

            if !meals.isEmpty {
                listTargetRow
                sendButton
            }
        } header: {
            Text("\(fridgeEmoji) \(fridgeName) · Household plan")
        } footer: {
            if meals.isEmpty {
                Text("Tap a day to add a recipe, or use \"Add meal\" under each day. Frydge works out what the household already has and what needs buying.")
            } else {
                Text("Everyone sharing this frydge will get a notification with what's in the frydge and what was added to the list.")
            }
        }
    }

    private var overviewSummary: String {
        let count = meals.count
        guard count > 0 else { return "No meals planned yet." }

        let result = needs
        let leftoverNights = meals.filter(\.isLeftover).count
        let due = dueStaplesNotOnList.count
        var parts = ["\(count) meal\(count == 1 ? "" : "s") planned"]
        if leftoverNights > 0 {
            parts.append("\(leftoverNights) leftover night\(leftoverNights == 1 ? "" : "s")")
        }
        if !result.toBuy.isEmpty {
            parts.append("\(result.toBuy.count) to buy")
        }
        if !result.inFrydge.isEmpty {
            parts.append("\(result.inFrydge.count) in the frydge")
        }
        if due > 0 {
            parts.append("\(due) staple\(due == 1 ? "" : "s") due")
        }
        return parts.joined(separator: " · ")
    }

    private func statPill(count: Int, label: String, color: Color, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text("\(count)").fontWeight(.bold)
            Text(label)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color)
    }

    @ViewBuilder
    private func breakdown(_ result: MealPlanNeeds.Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            breakdownGroup("In the frydge", lines: result.inFrydge, color: .green) { _ in nil }
            breakdownGroup("To buy", lines: result.toBuy, color: .orange) { line in
                if case .partial(let short, let unit) = line.status {
                    return "need \(short) \(unit) more"
                }
                return nil
            }
            breakdownGroup("Already on the list", lines: result.onList, color: .blue) { _ in nil }
        }
        .font(.caption)
    }

    @ViewBuilder
    private func breakdownGroup(_ title: String, lines: [MealPlanNeeds.Line], color: Color,
                                note: @escaping (MealPlanNeeds.Line) -> String?) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold).foregroundStyle(color)
                ForEach(lines) { line in
                    HStack(spacing: 4) {
                        Text(FoodEmoji.emoji(for: line.name))
                        Text(line.name)
                        Text("\(line.quantity) \(line.unit)".trimmingCharacters(in: .whitespaces))
                            .foregroundStyle(.secondary)
                        if let n = note(line) {
                            Text("· \(n)").foregroundStyle(.orange)
                        }
                    }
                    .lineLimit(1)
                }
            }
        }
    }

    private var listTargetRow: some View {
        HStack {
            Label("Add to", systemImage: "cart.badge.plus")
                .font(.subheadline)
            Spacer()
            Menu {
                ForEach(sharedShoppingListManager.sharedAnchors, id: \.recordID) { list in
                    Button {
                        listTarget = .shared(list.recordID)
                    } label: {
                        let name = sharedShoppingListManager.namesByAnchorID[list.recordID] ?? "Shared list"
                        let emoji = sharedShoppingListManager.emojisByAnchorID[list.recordID] ?? "🛒"
                        if listTarget == .shared(list.recordID) {
                            Label("\(emoji) \(name)", systemImage: "checkmark")
                        } else {
                            Text("\(emoji) \(name)")
                        }
                    }
                }
                Button {
                    listTarget = .mine
                } label: {
                    if listTarget == .mine {
                        Label("My shopping list", systemImage: "checkmark")
                    } else {
                        Text("My shopping list")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedListName)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.blue)
            }
        }
    }

    /// Opens the review sheet when there's something to buy; when the frydge
    /// already covers the week it just tells everyone.
    private var sendButton: some View {
        let total = needs.toBuy.count + dueStaplesNotOnList.count
        return Button {
            if total == 0 {
                Task { await sendToShoppingList(lines: [], staples: []) }
            } else {
                showReviewSheet = true
            }
        } label: {
            HStack {
                if isSending {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: total == 0 ? "bell.badge" : "cart.badge.plus")
                }
                Text(total == 0
                     ? "Everything's in the frydge · Notify everyone"
                     : "Review & add \(total) item\(total == 1 ? "" : "s")")
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isSending || listTarget == nil)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
        .listRowBackground(Color.clear)
    }

    // MARK: - Day sections

    private func daySection(_ dayIndex: Int) -> some View {
        Section {
            ForEach(store.meals(for: anchor.recordID, dayIndex: dayIndex)) { meal in
                Group {
                    if meal.isLeftover {
                        PlannedLeftoverRow(
                            name: meal.recipeName,
                            serves: meal.serves,
                            dayIndex: dayIndex,
                            live: liveLeftover(for: meal),
                            addedBy: meal.addedBy
                        )
                    } else {
                        recipeRow(meal)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task { await store.removeMeal(meal, scope: scope) }
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
                    Task { await add(leftover, to: dayIndex) }
                }
            } label: {
                Label("Add meal", systemImage: "plus.circle")
                    .font(.subheadline)
            }
        } header: {
            dayHeader(dayIndex)
        }
    }

    private func recipeRow(_ meal: SharedPlannedMeal) -> some View {
        HStack(spacing: 12) {
            RecipeThumbnailView(
                recipeID: meal.recipeID,
                recipeName: meal.recipeName,
                imageSourceURL: recipeListModel.recipes.first { $0.id == meal.recipeID }?.imageSourceURL,
                size: 64
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(meal.recipeName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text("\(meal.ingredients.count) ingredient\(meal.ingredients.count == 1 ? "" : "s") · serves \(meal.serves)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let costText = costLine(for: meal) {
                    Text(costText)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.green)
                        .contentTransition(.numericText())
                }
                HealthScoreBadge(
                    rating: RecipeHealthScore.rating(
                        ingredients: meal.ingredients,
                        dietaryTags: meal.dietaryTags
                    )
                )
                if !meal.addedBy.isEmpty {
                    Text("Added by \(meal.addedBy)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Day name with the day's estimated cost on the trailing edge.
    private func dayHeader(_ dayIndex: Int) -> some View {
        let cost = dayCost(dayIndex)
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

    // MARK: - Household restock

    private var restockSection: some View {
        HouseholdRestockSection(
            items: store.staples(for: anchor.recordID),
            footer: "Staples everyone in \(fridgeName) shares. Due items are offered when the week's shopping is reviewed, and the next due date rolls forward for the whole household.",
            onAdd: { name, interval in
                Task { await store.addStaple(name: name, interval: interval, to: anchor, scope: scope) }
            },
            onUpdateInterval: { id, interval in
                Task { await store.updateStapleInterval(id: id, interval: interval, for: anchor, scope: scope) }
            },
            onRemove: { id in
                Task { await store.removeStaple(id: id, for: anchor, scope: scope) }
            }
        )
    }

    // MARK: - Derived data

    private var meals: [SharedPlannedMeal] { store.meals(for: anchor.recordID) }

    private var fridgeName: String {
        sharedFridgeManager.namesByFridge[anchor.recordID]
            ?? (anchor["name"] as? String)
            ?? "Shared Frydge"
    }

    private var fridgeEmoji: String {
        sharedFridgeManager.emojiByFridge[anchor.recordID]
            ?? (anchor["emoji"] as? String)
            ?? "🧊"
    }

    private var fridgeRecords: [CKRecord] {
        sharedFridgeManager.itemsByFridge[anchor.recordID] ?? []
    }

    /// What this frydge holds right now, as the calculator wants it. Leftovers
    /// are skipped: they're meals, not ingredients.
    private var stock: [MealPlanNeeds.StockItem] {
        fridgeRecords.compactMap { rec in
            guard let name = rec["name"] as? String, !name.isEmpty else { return nil }
            if (rec["lifecycle"] as? String) == StoredIngredient.ItemLifecycle.leftover.rawValue { return nil }
            let expiry = rec["expirationDate"] as? Date
            return MealPlanNeeds.StockItem(
                name: name,
                quantity: (rec["quantity"] as? String) ?? "",
                unit: (rec["unit"] as? String) ?? "",
                quantityUsed: (rec["quantityUsed"] as? Double) ?? 0,
                isExpired: expiry.map { $0 < Date() } ?? false
            )
        }
    }

    /// Every leftover in the shared frydge, including expired ones (so a
    /// planned row can still say what happened to it).
    private var allLeftovers: [PlannableLeftover] {
        fridgeRecords
            .compactMap(PlannableLeftover.init(record:))
            .sorted { $0.expiryDate < $1.expiryDate }
    }

    /// Leftovers still worth planning.
    private var frydgeLeftovers: [PlannableLeftover] {
        allLeftovers.filter { !$0.isExpired }
    }

    /// Leftovers that aren't on the plan yet.
    private var unplannedLeftovers: [PlannableLeftover] {
        let planned = store.plannedLeftoverItemIDs(for: anchor.recordID)
        return frydgeLeftovers.filter { !planned.contains($0.id) }
    }

    private func liveLeftover(for meal: SharedPlannedMeal) -> PlannableLeftover? {
        guard let itemID = meal.leftoverItemID else { return nil }
        return allLeftovers.first { $0.id == itemID }
    }

    private var mealInputs: [MealPlanNeeds.Meal] {
        meals.map {
            MealPlanNeeds.Meal(recipeName: $0.recipeName, dayIndex: $0.dayIndex,
                               ingredients: $0.ingredients, dietaryTags: $0.dietaryTags)
        }
    }

    private var targetListAnchor: CKRecord? {
        guard case .shared(let id) = listTarget else { return nil }
        return sharedShoppingListManager.sharedAnchors.first { $0.recordID == id }
    }

    private var shoppingListNames: [String] {
        if let list = targetListAnchor {
            return sharedShoppingListManager.itemsDetailed(for: list).map(\.name)
        }
        return shoppingListManager.shoppingListItems.map(\.name)
    }

    private var selectedListName: String {
        switch listTarget {
        case .shared(let id):
            let name = sharedShoppingListManager.namesByAnchorID[id] ?? "Shared list"
            let emoji = sharedShoppingListManager.emojisByAnchorID[id] ?? "🛒"
            return "\(emoji) \(name)"
        case .mine:
            return "My shopping list"
        case nil:
            return "Choose list"
        }
    }

    private var needs: MealPlanNeeds.Result {
        MealPlanNeeds.compute(meals: mealInputs, stock: stock, shoppingListNames: shoppingListNames)
    }

    /// Household staples that are due and not already on the chosen list.
    private var dueStaplesNotOnList: [RecurringHouseholdItem] {
        let onList = Set(shoppingListNames.map { $0.lowercased() })
        return store.dueStaples(for: anchor.recordID).filter { !onList.contains($0.name.lowercased()) }
    }

    // MARK: Costs

    private func dayCost(_ dayIndex: Int) -> MealPlanCostModel.Cost {
        costModel.cost(ofLines: store.meals(for: anchor.recordID, dayIndex: dayIndex).flatMap(\.ingredients))
    }

    private var weekCost: MealPlanCostModel.Cost {
        costModel.cost(ofLines: meals.flatMap(\.ingredients))
    }

    /// What the week's "to buy" lines would cost: merged across recipes and
    /// reduced by the household frydge, so it's the number that hits the budget.
    private var toBuyCost: MealPlanCostModel.Cost {
        costModel.cost(ofNeeds: needs.toBuy)
    }

    /// "≈ $14.20 · $3.55 a serve", "Pricing…" while the feed is answering,
    /// nil when nothing could be priced.
    private func costLine(for meal: SharedPlannedMeal) -> String? {
        let cost = costModel.cost(ofLines: meal.ingredients)
        if cost.hasAnyPrice {
            var parts = [cost.text]
            if let serves = Int(meal.serves.filter(\.isNumber)), serves > 0 {
                parts.append("\(GroceryBudget.money(cost.total / Double(serves), currencyCode: cost.currencyCode)) a serve")
            }
            return parts.joined(separator: " · ")
        }
        return costModel.isLoading ? "Pricing…" : nil
    }

    /// The three dearest meals this week — the quickest place to save if the
    /// plan is running over.
    private var priciestMeals: [MealPlanBudgetSection.PriciestMeal] {
        meals
            .filter { !$0.isLeftover }
            .map { (meal: $0, cost: costModel.cost(ofLines: $0.ingredients)) }
            .filter { $0.cost.hasAnyPrice }
            .sorted { $0.cost.total > $1.cost.total }
            .prefix(3)
            .map { entry in
                MealPlanBudgetSection.PriciestMeal(
                    id: entry.meal.id,
                    name: entry.meal.recipeName,
                    dayName: entry.meal.dayName,
                    cost: entry.cost
                ) {
                    Task { await store.removeMeal(entry.meal, scope: scope) }
                }
            }
    }

    /// The current user's name as the share knows it, for "Added by" and the
    /// notification title.
    private var authorName: String {
        if let me = sharedFridgeManager.sharesByFridge[anchor.recordID]?.currentUserParticipant {
            let name = ShareManagementModel.displayName(for: me)
            if name != "Unknown member" { return name }
        }
        return "A household member"
    }

    // MARK: - Actions

    private func add(_ recipe: CloudRecipe, to dayIndex: Int) async {
        do {
            try await store.addMeal(recipe, dayIndex: dayIndex, to: anchor, scope: scope, addedBy: authorName)
        } catch {
            store.errorMessage = "Couldn't add \(recipe.name): \(error.localizedDescription)"
        }
    }

    private func add(_ leftover: PlannableLeftover, to dayIndex: Int) async {
        do {
            try await store.addLeftover(leftover, dayIndex: dayIndex, to: anchor, scope: scope, addedBy: authorName)
        } catch {
            store.errorMessage = "Couldn't plan \(leftover.name): \(error.localizedDescription)"
        }
    }

    /// Push the ticked lines and staples to the chosen list, roll the staples'
    /// due dates forward for everyone, then tell the household.
    private func sendToShoppingList(lines: [MealPlanNeeds.Line], staples: [RecurringHouseholdItem]) async {
        guard !isSending, let target = listTarget else { return }
        isSending = true
        defer { isSending = false }

        let result = needs
        let listName: String

        switch target {
        case .shared(let id):
            guard let listAnchor = targetListAnchor else { return }
            var items = sharedShoppingListManager.itemsDetailed(for: listAnchor)
            for line in lines {
                items.append(SharedShoppingListItem(
                    name: line.name,
                    quantity: line.purchaseQuantity,
                    unit: line.purchaseUnit,
                    location: "Shopping",
                    dietaryTags: Array(line.dietaryTags)
                ))
            }
            for staple in staples {
                items.append(SharedShoppingListItem(
                    name: staple.name,
                    quantity: staple.quantity,
                    unit: staple.unit,
                    location: "Shopping",
                    dietaryTags: []
                ))
            }
            if !lines.isEmpty || !staples.isEmpty {
                await sharedShoppingListManager.setItemsDetailed(items, for: listAnchor)
            }
            listName = sharedShoppingListManager.namesByAnchorID[id] ?? "the shared list"

        case .mine:
            for line in lines {
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
            listName = "\(authorName)'s list"
        }

        await store.markStaplesAdded(ids: Set(staples.map(\.id)), for: anchor, scope: scope)

        // The notice describes what actually went on the list, not what the
        // calculator proposed, so unticked lines aren't announced.
        let sent = MealPlanNeeds.Result(inFrydge: result.inFrydge, toBuy: lines, onList: result.onList)
        var summary = MealPlanNeeds.summary(meals: mealInputs, result: sent, listName: listName)
        if !staples.isEmpty {
            let names = staples.prefix(3).map { $0.name.lowercased() }.joined(separator: ", ")
            let extra = staples.count - min(3, staples.count)
            summary += " · Restock: " + names + (extra > 0 ? " +\(extra) more" : "")
        }

        let title = "\(authorName) updated the \(fridgeName) meal plan"
        do {
            try await store.postNotice(title: title, body: summary, to: anchor, scope: scope, authorName: authorName)
        } catch {
            store.errorMessage = "Shopping list updated, but the household couldn't be notified: \(error.localizedDescription)"
        }
        resultMessage = summary
    }
}
