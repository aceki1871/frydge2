//
//  RecipeDetailView.swift
//  FrydgeRecipes
//

import SwiftUI
import CloudKit
import UserNotifications
import UIKit

struct RecipeDetailView: View {
    var recipeListModel: RecipeListModel
    @State var recipe: CloudRecipe

    /// Steps shown under "Instructions". Legacy recipes only have prose
    /// instructions, so these are inferred once here (not per body pass, which
    /// would hand every step a fresh identity each time).
    @State private var displaySteps: [RecipeStep]

    init(recipeListModel: RecipeListModel, recipe: CloudRecipe) {
        self.recipeListModel = recipeListModel
        _recipe = State(initialValue: recipe)
        _displaySteps = State(initialValue: recipe.resolvedSteps)
    }

    // Serves scaling (base is what the recipe was authored for; servingSize is the live toggle)
    @State private var baseServes: Int = 1
    @State private var servingSize: Int = 1

    @Environment(\.colorScheme) private var colorScheme

    @EnvironmentObject private var shoppingListManager: ShoppingListManager
    @EnvironmentObject private var sharedShoppingListManager: SharedShoppingListManager
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var frydgeManager: FrydgeManager

    @State private var isEditorPresented = false

    /// Local UI-only cache for "in shopping list" state so the row updates immediately.
    /// IMPORTANT: this must be kept in sync with ShoppingListManager.shoppingListItems
    @State private var shoppingSet: Set<String> = []

    /// Debounce/guard: prevents duplicate actions caused by rapid taps or state refreshes.
    @State private var shoppingActionInFlight: Set<String> = []

    /// Optional convenience action: lets user explicitly add missing ingredients to shopping list.
    @State private var bulkAddInFlight: Bool = false

    // Sharing lives in RecipeShareMenu (toolbar); no local share state needed.
    @StateObject private var imageLoader = RecipeImageLoader()
    @State private var extraImageURLs: [URL] = []
    @State private var showingSuggestSheet = false
    @State private var suggestionMessage: String?
    @State private var showCookMode = false

    /// Chef techniques used anywhere in this recipe, deduplicated, in step order.
    private var recipeTechniques: [ChefTechnique] {
        var seen = Set<String>()
        var out: [ChefTechnique] = []
        for step in recipe.resolvedSteps {
            for technique in ChefTechniqueLibrary.relevant(to: step) where seen.insert(technique.id).inserted {
                out.append(technique)
            }
        }
        return out
    }

    // MARK: - Recipe cost
    @State private var recipeCostEstimate: RecipeCostEstimate?
    @State private var isLoadingRecipeCost = false
    @State private var recipeCostTask: Task<Void, Never>?
    /// Best live product match per ingredient (same offer feed as the recipe
    /// cost total), keyed by normalized ingredient line. Lets each row show
    /// its own price and lets the list sort "ready to buy" items first.
    @State private var ingredientPriceMatches: [String: IngredientPriceMatch] = [:]
    /// Every priced, probably-matching offer per ingredient line (normalized
    /// key), kept so switching the preferred store re-picks each row's price
    /// and the total without another network round trip.
    @State private var ingredientOffers: [String: [StockAvailability.StoreOffer]] = [:]
    @State private var didLoadOffers = false
    /// The supermarket the user would rather buy from (PreferredStore).
    /// Empty means "cheapest offer wins".
    @AppStorage(PreferredStore.key) private var preferredStoreName: String = ""

    // MARK: - Favourites (local)
    @AppStorage("favoriteRecipeIDs") private var favoriteRecipeIDsCSV: String = ""

    // MARK: - Dietary alternatives
    @State private var showingDietaryAlternatives = false
    @State private var selectedDietaryTag: String?
    @State private var ingredientSubstitutions: [(original: String, substitute: String)] = []
    @State private var tappedIngredient: IngredientDetailItem? = nil

    // MARK: - Allergen safety (Profile → Dietary → Can't & won't eat)
    @ObservedObject private var restrictions = DietaryRestrictionStore.shared
    /// Which lines trip the user's rules, recomputed when the recipe or the
    /// rules change (never per body pass).
    @State private var allergenVerdict = RecipeAllergenVerdict()

    // MARK: - Cook confirmation
    @State private var showCookConfirmation = false
    @State private var cookMatches: [StoredIngredient] = []

    // MARK: - Post-cook loop (cook-along → deduct → store leftovers → back to fridge)
    @State private var pendingLeftoverAfterCook = false
    @State private var showLeftoverSheet = false
    @State private var depletedIngredientNames: [String] = []
    /// Auto-calculated usage per matched fridge item, keyed by item id.
    @State private var cookEstimates: [UUID: CookUsageEstimate] = [:]

    private struct IngredientDetailItem: Identifiable {
        let name: String
        var id: String { name }
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var usesColumns = false

    private var sectionLayout: AnyLayout {
        usesColumns && !dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionLayout {
                    imageView
                        .background(Color.black.opacity(0.2))
                        .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 16) {
                        headerInfoPanel
                        ownVersionSection
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Split into two sub-views so the type checker stays fast:
                // ingredients (with the allergen card), then equipment →
                // chef's tips → method.
                sectionLayout {
                    VStack(alignment: .leading, spacing: 16) {
                        ingredientsSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 16) {
                        methodSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(.horizontal)
                .padding(.bottom, 30)
            }
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
            .onAppear {
                syncShoppingSetFromManager()

                // Default to serving 4 when a recipe doesn't state its own yield.
                let authored = max(1, Int(recipe.serves.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 4)
                baseServes = authored

                if servingSize <= 1 {
                    servingSize = authored
                } else {
                    servingSize = max(1, servingSize)
                }

                imageLoader.load(recipe: recipe)
                buildExtraImageURLs()
                allergenVerdict = RecipeAllergenCheck.evaluate(recipe)
                Task {
                    async let sharedTargets: Void = sharedShoppingListManager.refreshSharedLists()
                    async let recipes: Void = recipeListModel.fetchRecipesFromCloud()
                    _ = await (sharedTargets, recipes)
                }
                refreshRecipeCostEstimate()
            }
        }
        .onGeometryChange(for: Bool.self) { geometry in
            geometry.size.width >= 760
        } action: { usesColumns = $0 }
        .onChange(of: shoppingListManager.shoppingListItems) {
            syncShoppingSetFromManager()
        }
        // Rules edited in Profile while this page is open apply straight away.
        .onReceive(restrictions.$restrictions) { _ in
            allergenVerdict = RecipeAllergenCheck.evaluate(recipe)
        }
        .onChange(of: recipe.id) {
            recipeCostEstimate = nil
            imageLoader.load(recipe: recipe)
            buildExtraImageURLs()
            refreshRecipeCostEstimate()
        }
        .onChange(of: recipe) { _, newRecipe in
            imageLoader.load(recipe: newRecipe)
            displaySteps = newRecipe.resolvedSteps
            allergenVerdict = RecipeAllergenCheck.evaluate(newRecipe)
        }
        .onChange(of: servingSize) {
            refreshRecipeCostEstimate()
        }
        .onChange(of: preferredStoreName) {
            // Re-pick each ingredient's offer for the new store; no refetch needed.
            rebuildPriceMatches()
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationBarBackButtonHidden(false)
        .navigationTitle(horizontalSizeClass == .regular ? recipe.displayName : "")
        .navigationBarTitleDisplayMode(.inline)
        // The editor role leading-aligns the title and any principal item.
        // That suits iPad, where the recipe name sits top-left, but on iPhone
        // it pushed the share button into the back button's slot. Compact
        // keeps the system back button top-left and the share button centred.
        .toolbarRole(horizontalSizeClass == .regular ? .editor : .automatic)
        .toolbar {
            // Center button (same row as system back + trailing edit)
            ToolbarItem(placement: horizontalSizeClass == .regular ? .primaryAction : .principal) {
                // Native share menu: link / text / card / copy. Publishes the
                // public preview + payload in the background on appear.
                // The menu draws its own Liquid Glass circle, so opt out of
                // the bar's shared glass grouping to avoid glass-on-glass.
                RecipeShareMenu(recipe: recipe, style: .toolbar)
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .navigationBarTrailing) {
                // Owners edit in place; everyone else gets their own version.
                Button(action: { isEditorPresented = true }) {
                    if horizontalSizeClass == .regular {
                        Label(recipe.isOwnedByCurrentUser ? "Edit" : "Make a Copy", systemImage: recipe.isOwnedByCurrentUser ? "square.and.pencil" : "doc.on.doc")
                    } else {
                        toolbarGlassIcon(recipe.isOwnedByCurrentUser ? "square.and.pencil" : "doc.on.doc")
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(recipe.isOwnedByCurrentUser ? "Edit recipe" : "Make my own version")
                .keyboardShortcut("e", modifiers: .command)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .sheet(isPresented: $showingSuggestSheet) {
            RecipeSuggestionSheet(
                recipe: recipe,
                sharedManager: sharedShoppingListManager,
                onSuggested: { listName in
                    suggestionMessage = "Suggested \(recipe.name) to \(listName)."
                    appState.showBanner(
                        title: "Recipe suggested",
                        message: listName,
                        systemImage: "bubble.left.and.bubble.right",
                        style: .success
                    )
                }
            )
        }
        .alert("Recipe Suggested", isPresented: Binding(
            get: { suggestionMessage != nil },
            set: { if !$0 { suggestionMessage = nil } }
        )) {
            Button("OK", role: .cancel) { suggestionMessage = nil }
        } message: {
            Text(suggestionMessage ?? "")
        }
        .sheet(isPresented: $isEditorPresented) {
            RecipeEditorView(recipe: .constant(recipe), onSave: { updatedRecipe in
                if let updatedRecipe = updatedRecipe {
                    saveEditedRecipe(updatedRecipe)
                }
            })
        }
        .fullScreenCover(isPresented: $showCookMode) {
            CookAlongView(recipe: recipe) {
                startPostCookFlow()
            }
        }
        .sheet(isPresented: $showCookConfirmation) {
            MarkCookedSheet(recipeName: recipe.name, items: cookMatches, estimates: cookEstimates) { usages in
                var depleted: [String] = []
                for usage in usages {
                    let item = cookMatches.first(where: { $0.id == usage.id })
                    frydgeManager.incrementQuantityUsed(for: usage.id, by: usage.percent)
                    // Depleted when this cook takes the item to (near) fully used.
                    if let item, item.quantityUsed + usage.percent >= 99.5 {
                        depleted.append(item.name)
                    }
                }
                depletedIngredientNames = depleted
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showLeftoverSheet) {
            LeftoverReminderSheet(
                recipeName: recipe.name,
                restockSuggestions: depletedIngredientNames,
                onRestock: { names in addRestockToShoppingList(names) }
            )
        }
        // Continue the cook loop as each sheet closes: deduction → leftovers → fridge.
        .onChange(of: showCookConfirmation) { _, isShown in
            guard !isShown, pendingLeftoverAfterCook else { return }
            presentLeftoverSheet()
        }
        .onChange(of: showLeftoverSheet) { _, isShown in
            guard !isShown, pendingLeftoverAfterCook else { return }
            pendingLeftoverAfterCook = false
            appState.returnToFridgeAfterCook()
        }
        .sheet(isPresented: $showingDietaryAlternatives) {
            RecipeAdaptationSheet(
                tag: selectedDietaryTag ?? "",
                recipeName: recipe.name,
                swaps: ingredientSubstitutions,
                allIngredients: recipe.ingredients
            )
        }
        .sheet(item: $tappedIngredient) { item in
            if let stored = matchedStoredIngredient(for: item.name) {
                IngredientDetailSheet(ingredient: stored) { newUsage in
                    Task { await frydgeManager.updateIngredientUsage(stored.id, quantityUsed: newUsage) }
                }
                .environmentObject(frydgeManager)
            } else if let shoppingItem = matchedShoppingListItem(for: item.name) {
                ShoppingListItemDetailSheet(item: shoppingItem)
                    .environmentObject(shoppingListManager)
            } else {
                FoodInfoView(ingredient: item.name)
            }
        }
    }

    // MARK: - Page sections

    /// Allergen card (when something trips the user's rules), the
    /// Ingredients title, then one compact row per ingredient.
    @ViewBuilder
    private var ingredientsSection: some View {
        // Safety first: anything that trips the user's can't / won't eat
        // rules, with what to swap in, above the ingredient list.
        if !allergenVerdict.isClean {
            RecipeAllergenCard(verdict: allergenVerdict)
        }

        // Ingredients title (the serves control lives in the header)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ingredients")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Text(readyCount == totalIngredientCount
                     ? "All in your frydge"
                     : "\(totalIngredientCount - readyCount) to get")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(readyCount == totalIngredientCount ? Color.green : Color.secondary)
            }

            Divider()
                .opacity(0.25)
        }

        // Index-based identity: a recipe can legitimately list the same
        // ingredient twice (e.g. marmalade's sugar), and duplicate
        // `id: \.self` values are a hard crash in ForEach.
        ForEach(Array(sortedIngredientsForDisplay.enumerated()), id: \.offset) { _, ingredient in
            ingredientRow(ingredient)
        }
    }

    /// Required items first; among those, ones cross-referenced to a
    /// confident product/price match (ready to buy as-is) come before ones
    /// with no match, so shopping is easier.
    private var sortedIngredientsForDisplay: [String] {
        recipe.ingredients.sorted { a, b in
            let aAvailable = isIngredientInFridge(a)
            let bAvailable = isIngredientInFridge(b)
            if aAvailable != bAvailable {
                return !aAvailable && bAvailable // required first
            }
            if !aAvailable {
                let aMatched = ingredientPriceMatches[norm(a)] != nil
                let bMatched = ingredientPriceMatches[norm(b)] != nil
                if aMatched != bMatched {
                    return aMatched && !bMatched
                }
            }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    /// Equipment (get-ready checklist), then chef's tips, then the method —
    /// so everything you need to know before you start comes before the steps.
    @ViewBuilder
    private var methodSection: some View {
        RecipeEquipmentSection(items: RecipeEquipment.items(for: recipe))

        chefTipsCard

        // Instructions title (no underline) + faint full-width divider line
        VStack(alignment: .leading, spacing: 8) {
            Text("Instructions")
                .font(.title2)
                .fontWeight(.semibold)

            Divider()
                .opacity(0.25)
        }

        if !displaySteps.isEmpty {
            stepsView
        } else {
            // Nothing to show at all: say so instead of leaving a
            // blank heading, and point at where to fix it.
            Text("No instructions yet. Tap the pencil to add steps.")
                .foregroundColor(.secondary)
                .padding(.top, 5)
        }
    }

    // MARK: - Cooking actions (under the readiness bar, from 95% ready)

    /// "Start Cooking" (cook-along, deducts when you finish) plus a quick
    /// "Cook" that logs it straight away. Only offered once the fridge covers
    /// almost everything, so the page never nags before you can actually cook.
    private var cookActionsRow: some View {
        HStack(spacing: 10) {
            Button {
                showCookMode = true
            } label: {
                Label("Start Cooking", systemImage: "flame.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(.orange)

            Button {
                cookRecipe()
            } label: {
                Label("Cook", systemImage: "fork.knife")
                    .font(.headline)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.glass)
            .tint(.green)
            .accessibilityLabel("Cook recipe")
        }
        .padding(.top, 6)
    }

    /// Circular Liquid Glass icon used by the navigation bar buttons.
    private func toolbarGlassIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.blue)
            .frame(width: 38, height: 38)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: Circle())
    }

    // MARK: - Own version strip (between the title panel and ingredients)

    /// Make (or edit) your own copy of the recipe, and suggest it to a shared
    /// shopping list. Lives in its own row so the header can give the dietary
    /// tags the whole width.
    private var ownVersionSection: some View {
        HStack(spacing: 10) {
            Button {
                isEditorPresented = true
            } label: {
                Label(
                    recipe.isOwnedByCurrentUser ? "Edit my recipe" : "Make my own version",
                    systemImage: recipe.isOwnedByCurrentUser ? "square.and.pencil" : "doc.on.doc"
                )
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(.orange)

            Button {
                showingSuggestSheet = true
            } label: {
                Label(
                    "Suggest",
                    systemImage: sharedShoppingListManager.isLoading ? "hourglass" : "bubble.left.and.bubble.right"
                )
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }
            .buttonStyle(.glass)
            .tint(.teal)
        }
    }

    // MARK: - Serves Control (person + count + live −/+)

    private var servesControl: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("\(servingSize)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundColor(.primary)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.15), value: servingSize)

            Button {
                servingSize = max(1, servingSize - 1)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Decrease serves")

            Button {
                servingSize = min(50, servingSize + 1)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Increase serves")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Serves \(servingSize)")
    }

    private var portionMultiplier: Double {
        let base = max(1, baseServes)
        return Double(servingSize) / Double(base)
    }

    /// Single source of truth for "do I have it": the shared matcher
    /// (RecipeReadiness), amount-aware and scaled to the chosen serves, so
    /// this page, the recipe list rows and cook-time deductions all agree.
    private var readiness: RecipeReadiness.Summary {
        RecipeReadiness.evaluate(
            lines: recipe.ingredients,
            fridgeItems: frydgeManager.storedIngredients,
            shoppingListNames: shoppingListManager.shoppingListItems.map(\.name),
            scale: portionMultiplier
        )
    }

    /// Which step each ingredient is added at (explicit step tags first,
    /// otherwise inferred from the step wording).
    private var stagePlan: RecipeStagePlan {
        RecipeStagePlan.build(ingredients: recipe.ingredients, steps: displaySteps)
    }

    private var readyCount: Int { readiness.haveCount }

    private var cartCount: Int {
        recipe.ingredients.filter { isInShoppingLocal($0) }.count
    }

    private var totalIngredientCount: Int {
        max(0, recipe.ingredients.count)
    }

    /// Share of ingredient lines the fridge covers at the chosen serves (0…1).
    private var readinessFraction: Double {
        let total = max(1, totalIngredientCount)
        return Double(min(readyCount, total)) / Double(total)
    }

    /// Cooking actions appear once the readiness bar reaches 95%.
    private var canCookRecipe: Bool { readiness.canMakeNow || readinessFraction >= 0.95 }

    private var metricsRow: some View {
        // One wrapping flow instead of two horizontal scrollers: favourite,
        // serves (live scaling), cost and store first, then the dietary tags
        // (lit when the recipe already meets the need; tap any to adapt the
        // recipe to it). Chips fall onto new lines as needed, so everything
        // is visible without swiping. The cook buttons sit under the
        // readiness bar once it reaches 95%; the progress bar at the foot of
        // the panel carries the old cart/fridge counts.
        WrappingHStack(spacing: 8, lineSpacing: 8) {
            favouriteMetricBadge

            servesControl

            recipeCostBadge

            preferredStoreChip

            ForEach(["GF", "DF", "V", "VG"], id: \.self) { tag in
                dietaryTagButton(tag)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One tappable dietary chip: abbreviation badge + readable name. Active
    /// (coloured) when the recipe is already tagged or this adaptation is
    /// selected; otherwise neutral glass inviting a tap.
    private func dietaryTagButton(_ tag: String) -> some View {
        let isOn = normalizedRecipeDietaryTags.contains(tag) || selectedDietaryTag == tag
        return Button {
            if selectedDietaryTag == tag {
                selectedDietaryTag = nil
                ingredientSubstitutions = []
            } else {
                selectedDietaryTag = tag
                ingredientSubstitutions = computeSubstitutions(tag: tag)
                showingDietaryAlternatives = true
            }
        } label: {
            Text(tag)
                .font(.caption.weight(.bold))
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            isOn ? .regular.tint(dietaryHeaderColor(for: tag)).interactive() : .regular.interactive(),
            in: Capsule()
        )
        .accessibilityLabel("Adapt recipe to \(dietaryTagName(tag))")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }

    private func dietaryTagName(_ tag: String) -> String {
        switch tag.uppercased() {
        case "GF": return "Gluten free"
        case "DF": return "Dairy free"
        case "V":  return "Vegetarian"
        case "VG": return "Vegan"
        default:   return tag
        }
    }

    private func dietaryHeaderColor(for tag: String) -> Color {
        switch dietaryHeaderTone(for: tag) {
        case .green:  return .green
        case .orange: return .orange
        case .teal:   return .teal
        case .gray:   return .gray
        case .brand:  return .blue
        }
    }

    private var headerInfoPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(recipe.displayName)
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.primary)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)

            metricsRow

            ingredientProgressBar

            // Cooking actions appear once the readiness bar hits 95%.
            if canCookRecipe {
                cookActionsRow
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: canCookRecipe)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemBackground).opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.12), radius: 18, x: 0, y: 8)
    }

    // MARK: - Ingredient progress (foot of the title panel)

    /// How much of the recipe the fridge already covers, scaled to the chosen
    /// serves, with how many lines are still to get. Replaces the old cart /
    /// fridge count badges.
    private var ingredientProgressBar: some View {
        let total = max(1, totalIngredientCount)
        let have = min(readyCount, total)
        let remaining = max(0, total - have)
        let onList = cartCount
        let fraction = Double(have) / Double(total)
        let tint: Color = remaining == 0 ? .green : (fraction >= 0.5 ? .blue : .orange)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: remaining == 0 ? "checkmark.circle.fill" : "basket")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(remaining == 0
                     ? "You have everything — ready to cook"
                     : "\(remaining) ingredient\(remaining == 1 ? "" : "s") still to get")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if remaining > 0, onList > 0 {
                    Text("\(min(onList, remaining)) on your list")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                }
                Text("\(have)/\(total)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(6, geo.size.width * fraction))
                    // Items already on the shopping list, shown as the next segment.
                    if remaining > 0, onList > 0 {
                        Capsule()
                            .fill(Color.blue.opacity(0.35))
                            .frame(width: geo.size.width * Double(min(onList, remaining)) / Double(total))
                            .offset(x: geo.size.width * fraction)
                    }
                }
            }
            .frame(height: 8)
            .animation(.easeInOut(duration: 0.25), value: fraction)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(remaining == 0 ? "All ingredients in your frydge" : "\(remaining) ingredients still to get, \(have) of \(total) in your frydge")
    }

    // MARK: - Chef's tips (between equipment and the method)

    /// The techniques this recipe uses, with the Chef button to open them.
    private var chefTipsCard: some View {
        let techniques = recipeTechniques
        return HStack(spacing: 12) {
            Image(systemName: "graduationcap.fill")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.orange.opacity(0.14)))

            VStack(alignment: .leading, spacing: 3) {
                Text("Chef's tips")
                    .font(.headline)
                if techniques.isEmpty {
                    Text("Knife skills, timing and technique for every step.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(techniques.prefix(3).map { "\($0.emoji) \($0.title)" }.joined(separator: " · ")
                         + (techniques.count > 3 ? " +\(techniques.count - 3)" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 4)

            ChefButton(relevant: techniques, context: recipe.name, style: .pill)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
                )
        )
    }

    // MARK: - Preferred store

    /// Distinct store brands seen across this recipe's offers, most common first.
    private var storesWithOffers: [String] {
        var counts: [String: Int] = [:]
        for offers in ingredientOffers.values {
            for offer in offers where offer.price != nil {
                counts[PreferredStore.brand(of: offer.store), default: 0] += 1
            }
        }
        return counts.sorted { a, b in
            if a.value != b.value { return a.value > b.value }
            return a.key.localizedCaseInsensitiveCompare(b.key) == .orderedAscending
        }.map(\.key)
    }

    /// "Cheapest" / "New World ▾": which supermarket the prices come from.
    /// Choosing one re-prices every ingredient (and the total) from that store
    /// where it stocks the item, falling back to the cheapest elsewhere.
    private var preferredStoreChip: some View {
        let current = PreferredStore.name
        let stores = storesWithOffers

        return Menu {
            Button {
                preferredStoreName = ""
            } label: {
                Label("Cheapest anywhere", systemImage: current == nil ? "checkmark" : "tag")
            }
            if !stores.isEmpty {
                Section("Shop at") {
                    ForEach(stores, id: \.self) { store in
                        Button {
                            preferredStoreName = store
                        } label: {
                            Label(store, systemImage: PreferredStore.matches(store, preferred: current) ? "checkmark" : "storefront")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "storefront")
                    .font(.caption)
                Text(current ?? "Cheapest")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .opacity(0.7)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.purple.opacity(0.15))
            )
            .foregroundColor(.purple)
        }
        .accessibilityLabel("Preferred store: \(current ?? "cheapest anywhere")")
    }

    // Equipment now comes from RecipeEquipment.items(for:) (explicit pan list
    // plus anything the method mentions) and renders via RecipeEquipmentSection.

    private var recipeCostBadge: some View {
        HStack(spacing: 6) {
            if isLoadingRecipeCost {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "dollarsign.circle")
                    .font(.caption)
            }

            Text(recipeCostBadgeText)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.green.opacity(0.15))
        )
        .foregroundColor(.green)
        .accessibilityLabel("Estimated recipe cost")
    }

    private var recipeCostBadgeText: String {
        if let estimate = recipeCostEstimate {
            let base = formatCurrency(estimate.total, currencyCode: estimate.currencyCode)
            if estimate.pricedIngredientCount < estimate.totalIngredientCount {
                return "\(base)+"
            }
            return base
        }

        return isLoadingRecipeCost ? "Pricing" : "Price --"
    }

    private struct RecipeCostEstimate: Equatable {
        let total: Double
        let currencyCode: String
        let pricedIngredientCount: Int
        let totalIngredientCount: Int
    }

    /// One ingredient line's chosen live offer (cheapest at the preferred
    /// store, else cheapest anywhere), from the same feed as the cost total.
    private struct IngredientPriceMatch: Equatable {
        let offer: StockAvailability.StoreOffer

        var price: Double { offer.price ?? 0 }
        var currencyCode: String { offer.currencyCode }
        var store: String? { offer.store.isEmpty ? nil : offer.store }
        var imageURL: URL? { offer.imageURL }
    }

    // MARK: - Recipe cost

    /// Fetches every priced offer per ingredient, then lets
    /// `rebuildPriceMatches` pick one per line for the current store choice.
    @MainActor
    private func refreshRecipeCostEstimate() {
        recipeCostTask?.cancel()

        let currentRecipeID = recipe.id
        let currentServingSize = servingSize
        let pairs = recipe.ingredients.compactMap { raw -> (raw: String, query: String)? in
            let query = scaledIngredientDisplayString(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return nil }
            return (raw, query)
        }

        guard !pairs.isEmpty else {
            recipeCostEstimate = nil
            ingredientPriceMatches = [:]
            ingredientOffers = [:]
            didLoadOffers = false
            isLoadingRecipeCost = false
            return
        }

        isLoadingRecipeCost = true
        didLoadOffers = false
        recipeCostTask = Task {
            let fetched = await withTaskGroup(of: (raw: String, offers: [StockAvailability.StoreOffer]).self) { group in
                for pair in pairs {
                    group.addTask {
                        let offers = await StockAvailability.fetchPricedOffersOnly(for: pair.query)
                            .filter { $0.isProbablyMatch && $0.price != nil }
                        return (pair.raw, offers)
                    }
                }

                var out: [(raw: String, offers: [StockAvailability.StoreOffer])] = []
                for await entry in group where !entry.offers.isEmpty {
                    out.append(entry)
                }
                return out
            }

            guard !Task.isCancelled else { return }

            let offersByIngredient = Dictionary(
                fetched.map { (norm($0.raw), $0.offers) },
                uniquingKeysWith: { first, _ in first }
            )

            await MainActor.run {
                guard recipe.id == currentRecipeID, servingSize == currentServingSize else { return }
                ingredientOffers = offersByIngredient
                didLoadOffers = true
                rebuildPriceMatches()
                isLoadingRecipeCost = false
            }
        }
    }

    /// Derives each row's price and the recipe total from the cached offers
    /// and the preferred store. Pure state → state, so changing store is instant.
    private func rebuildPriceMatches() {
        let preferred = PreferredStore.name
        var matches: [String: IngredientPriceMatch] = [:]
        for (key, offers) in ingredientOffers {
            if let best = PreferredStore.bestOffer(from: offers, preferred: preferred) {
                matches[key] = IngredientPriceMatch(offer: best)
            }
        }
        ingredientPriceMatches = matches

        guard didLoadOffers else { return }
        let total = matches.values.reduce(0) { $0 + $1.price }
        let currencyCode = matches.values.first?.currencyCode ?? Locale.current.currency?.identifier ?? "NZD"
        let lineCount = recipe.ingredients.filter {
            !scaledIngredientDisplayString($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        recipeCostEstimate = RecipeCostEstimate(
            total: total,
            currencyCode: currencyCode,
            pricedIngredientCount: matches.count,
            totalIngredientCount: lineCount
        )
    }

    /// "$3.50 · New World" for an ingredient line's cross-referenced product
    /// match, or nil if nothing matched (or it's still loading).
    private func priceMatchText(for ingredient: String) -> String? {
        guard let match = ingredientPriceMatches[norm(ingredient)] else { return nil }
        let price = formatCurrency(match.price, currencyCode: match.currencyCode)
        guard let store = match.store, !store.isEmpty else { return price }
        return "\(price) · \(store)"
    }

    /// The price tag as a menu: tap to see what every store charges for this
    /// line and switch the preferred store from here. Picking a store also
    /// remembers that product for the ingredient (IngredientProductCache).
    @ViewBuilder
    private func storePriceTag(for ingredient: String) -> some View {
        let key = norm(ingredient)
        if let match = ingredientPriceMatches[key] {
            let offers = (ingredientOffers[key] ?? [])
                .sorted { ($0.price ?? 0) < ($1.price ?? 0) }
            let preferred = PreferredStore.name

            Menu {
                if offers.count > 1 || preferred != nil {
                    Section("Also at") {
                        ForEach(offers) { offer in
                            Button {
                                preferredStoreName = PreferredStore.brand(of: offer.store)
                                Task { await IngredientProductCache.shared.save(offer: offer, for: ingredient) }
                            } label: {
                                let price = formatCurrency(offer.price ?? 0, currencyCode: offer.currencyCode)
                                Label("\(offer.store) — \(price)", systemImage: offer.id == match.offer.id ? "checkmark" : "storefront")
                            }
                        }
                    }
                    if preferred != nil {
                        Button {
                            preferredStoreName = ""
                        } label: {
                            Label("Just show the cheapest", systemImage: "tag")
                        }
                    }
                }
                if let title = match.offer.productTitle, !title.isEmpty {
                    Section("Matched product") {
                        Text(title)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "tag.fill")
                    Text(priceMatchText(for: ingredient) ?? "")
                        .lineLimit(1)
                    if offers.count > 1 {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .opacity(0.8)
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundColor(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.green.opacity(0.12)))
            }
            .accessibilityLabel("\(priceMatchText(for: ingredient) ?? ""). \(offers.count) store\(offers.count == 1 ? "" : "s"). Choose store")
        }
    }

    private func formatCurrency(_ value: Double, currencyCode: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(currencyCode) \(String(format: "%.2f", value))"
    }

    // MARK: - Ingredient quantity parsing + scaling (keeps saved formatting)

    /// IMPORTANT:
    /// - If multiplier == 1, we return the *exact saved string*.
    /// - If we can parse a trailing number+unit, we replace ONLY the number, preserving:
    ///   - original spacing between name and number
    ///   - original spacing between number and unit
    ///   - original unit text (case)
    private func scaledIngredientDisplayString(_ raw: String) -> String {
        let original = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return raw }

        let pattern = #"^(.+?)(\s+)(\d+(?:[.,]\d+)?|\d+/\d+)(\s*)([A-Za-z]+)?\s*$"#

        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            let ns = original as NSString
            let range = NSRange(location: 0, length: ns.length)

            guard let match = regex.firstMatch(in: original, options: [], range: range) else {
                return original
            }

            let name = ns.substring(with: match.range(at: 1))
            let gap1 = ns.substring(with: match.range(at: 2))
            let qtyStr = ns.substring(with: match.range(at: 3))
            let gap2 = ns.substring(with: match.range(at: 4))
            let unit: String = (match.range(at: 5).location != NSNotFound) ? ns.substring(with: match.range(at: 5)) : ""

            guard let qty = parseNumberOrFraction(qtyStr) else {
                return original
            }

            let scaled = max(0, qty * portionMultiplier)
            let newQty = formatQuantityLikeOriginal(scaled, originalToken: qtyStr)
            let displayedQty = unit.isEmpty ? "x\(newQty)" : newQty

            if abs(portionMultiplier - 1.0) < 0.00001, !unit.isEmpty {
                return original
            }

            let rebuilt = "\(name)\(gap1)\(displayedQty)\(gap2)\(unit)".trimmingCharacters(in: .whitespacesAndNewlines)
            return rebuilt.isEmpty ? original : rebuilt
        } catch {
            return original
        }
    }

    private func parseNumberOrFraction(_ token: String) -> Double? {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)

        if t.contains("/") {
            let parts = t.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count == 2 else { return nil }
            let a = Double(parts[0].replacingOccurrences(of: ",", with: "."))
            let b = Double(parts[1].replacingOccurrences(of: ",", with: "."))
            guard let num = a, let den = b, den != 0 else { return nil }
            return num / den
        }

        return Double(t.replacingOccurrences(of: ",", with: "."))
    }

    private func formatQuantityLikeOriginal(_ value: Double, originalToken: String) -> String {
        let token = originalToken.trimmingCharacters(in: .whitespacesAndNewlines)

        if token.contains("/") {
            return formatQuantity(value)
        }

        let sep: Character? = token.contains(".") ? "." : (token.contains(",") ? "," : nil)
        if let sep = sep, let idx = token.firstIndex(of: sep) {
            let decimals = token.distance(from: token.index(after: idx), to: token.endIndex)
            let clamped = min(max(decimals, 0), 2)
            let fmt = "%.\(clamped)f"
            let out = String(format: fmt, value).replacingOccurrences(of: ".00", with: "")
            if sep == "," {
                return out.replacingOccurrences(of: ".", with: ",")
            }
            return out
        }

        let rounded = value.rounded()
        if abs(rounded - value) < 0.00001 {
            return String(Int(rounded))
        }
        return formatQuantity(value)
    }

    private struct ParsedIngredient {
        let name: String
        let quantity: Double?
        let unit: String?
    }

    private func parseIngredient(_ raw: String) -> ParsedIngredient {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return ParsedIngredient(name: "", quantity: nil, unit: nil) }

        let units = #"kg|g|l|ml|pcs|pc|tbsp|tsp|cups?|oz|lb"#

        // Pattern 1: "quantity[unit] name"  e.g. "500g butter", "2 cups flour", "1/2 tsp salt"
        // This is the most common recipe format.
        let leadingPattern = #"^(\d+(?:[.,]\d+)?|\d+/\d+)\s*(\#(units))\.?\s+(.+)$"#

        // Pattern 2 (legacy): "name quantity [unit]"  e.g. "butter 500 g"
        let trailingPattern = #"^(.+?)\s+(\d+(?:[.,]\d+)?|\d+/\d+)\s*(\#(units))?\s*$"#

        func tryPattern(_ pattern: String, nameGroup: Int, qtyGroup: Int, unitGroup: Int) -> ParsedIngredient? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let nsRange = NSRange(cleaned.startIndex..., in: cleaned)
            guard let match = regex.firstMatch(in: cleaned, options: [], range: nsRange) else { return nil }

            // Never index past the match's ranges — range(at:) throws (not returns
            // NSNotFound) for an index beyond numberOfRanges, which is a hard crash.
            guard match.numberOfRanges > max(nameGroup, qtyGroup, unitGroup) else { return nil }

            guard let qtyRange = Range(match.range(at: qtyGroup), in: cleaned),
                  let nameRange = Range(match.range(at: nameGroup), in: cleaned) else { return nil }

            let qtyString = String(cleaned[qtyRange])
            guard let qty = parseNumberOrFraction(qtyString) else { return nil }

            let name = String(cleaned[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }

            var unit: String? = nil
            if match.range(at: unitGroup).location != NSNotFound,
               let ur = Range(match.range(at: unitGroup), in: cleaned) {
                let u = String(cleaned[ur]).lowercased().trimmingCharacters(in: .punctuationCharacters)
                if !u.isEmpty { unit = u }
            }

            return ParsedIngredient(name: name, quantity: qty, unit: unit)
        }

        // Try leading format first (more common in real recipes).
        // leadingPattern captures: 1 = quantity, 2 = unit, 3 = name.
        if let result = tryPattern(leadingPattern, nameGroup: 3, qtyGroup: 1, unitGroup: 2) {
            return result
        }
        // Fall back to trailing format
        if let result = tryPattern(trailingPattern, nameGroup: 1, qtyGroup: 2, unitGroup: 3) {
            return result
        }

        return ParsedIngredient(name: cleaned, quantity: nil, unit: nil)
    }

    private func formatQuantity(_ q: Double) -> String {
        if q.rounded(.towardZero) == q { return String(Int(q)) }
        return String(format: "%.2f", q).replacingOccurrences(of: ".00", with: "")
    }

    /// "500 g" / "×2", scaled to the chosen serves; nil when the line has no
    /// amount we can read (then the row shows just the name).
    private func scaledQuantityText(for raw: String) -> String? {
        let parsed = parseIngredient(raw)
        guard let qty = parsed.quantity, qty > 0 else { return nil }
        let scaled = max(0, qty * portionMultiplier)
        let number = formatQuantity(scaled)
        if let unit = parsed.unit, !unit.isEmpty { return "\(number) \(unit)" }
        return "×\(number)"
    }

    // MARK: - Total time (steps timers)

    private func totalCookTimeSeconds(for recipe: CloudRecipe) -> Int {
        guard !recipe.steps.isEmpty else { return 0 }
        return recipe.steps.reduce(0) { $0 + max(0, $1.timerSeconds ?? 0) }
    }

    private func formatCookTime(_ totalSeconds: Int) -> String {
        let s = max(0, totalSeconds)
        let hours = s / 3600
        let minutes = (s % 3600) / 60
        let seconds = s % 60

        if hours > 0 {
            let m = seconds > 0 ? minutes + 1 : minutes
            return "\(hours)h \(m)m"
        }
        if minutes > 0 {
            let m = seconds > 0 ? minutes + 1 : minutes
            return "\(m)m"
        }
        return "\(seconds)s"
    }

    // MARK: - Steps UI

    /// One card per stage: the step, the ingredients (with scaled quantities)
    /// added at that stage, and its timer / temperature. See RecipeStageStepsView.
    private var stepsView: some View {
        RecipeStageStepsView(
            plan: stagePlan,
            displayLine: scaledIngredientDisplayString,
            isCovered: ingredientHasFullAmount
        )
    }

    // MARK: - Row

    @ViewBuilder
    private func ingredientRow(_ ingredient: String) -> some View {
        let matchedItem = matchedStoredIngredient(for: ingredient)
        let haveIt = matchedItem != nil
        let hasFullAmount = ingredientHasFullAmount(ingredient)
        let needsShopping = !hasFullAmount
        let storageIcon = iconForStorage(for: ingredient)
        let isFreezer = storageIcon == "snowflake"
        let inCart = isInShoppingLocal(ingredient)
        let cartTint = inCart ? Color.blue : Color.secondary
        let shortfallText = shoppingNeedDisplay(for: ingredient)
        let buyText = shoppingBuyDisplay(for: ingredient)

        let key = norm(ingredient)
        let inFlight = shoppingActionInFlight.contains(key)

        let needsSwap = !ingredientSubstitutions.isEmpty &&
            ingredientSubstitutions.contains(where: { $0.original == ingredient })

        let priceMatch = ingredientPriceMatches[key]
        let parsedName = parseIngredient(ingredient).name

        // One fixed-height line per ingredient: picture · name · quantity ·
        // price · (basket | green frydge tick). The picture is clipped to a
        // 44 pt tile so it always sits inside the row.
        let parsed = parseIngredient(ingredient)
        let scaledQuantity = scaledQuantityText(for: ingredient)
        let shownName = (parsedName.isEmpty ? ingredient : parsedName).trimmingCharacters(in: .whitespacesAndNewlines)

        HStack(alignment: .center, spacing: 10) {
            IngredientThumbnailView(
                ingredientName: shownName,
                imageURL: priceMatch?.imageURL,
                status: .none
            )
            .frame(width: 44, height: 44)
            .clipped()

            // Name + quantity on one line, dietary tags / top-up note under it.
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(shownName.prefix(1).uppercased() + shownName.dropFirst())
                        .font(.body.weight(.medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let scaledQuantity {
                        Text(scaledQuantity)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }

                let normalized = normalizedDietaryTags(matchedItem?.dietaryTags ?? []).sorted()
                HStack(spacing: 6) {
                    if haveIt && !hasFullAmount, let shortfallText {
                        Label("Need \(shortfallText) more", systemImage: isFreezer ? "snowflake" : "arrow.up.circle")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else if needsShopping, let buyText, parsed.quantity != nil {
                        Text("Buy \(buyText)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else if hasFullAmount {
                        Text("In your frydge")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                    ForEach(normalized.prefix(2), id: \.self) { tag in
                        DietaryBadgeChip(tag: tag, tone: dietaryHeaderTone(for: tag))
                    }
                }
                .frame(height: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                tappedIngredient = IngredientDetailItem(name: ingredient)
            }

            // Price (tap to switch store) — only when it still needs buying.
            if needsShopping {
                storePriceTag(for: ingredient)
                    .layoutPriority(1)
            }

            // Right: green frydge tick when you already have it; otherwise the
            // basket (solid blue once it's on the list).
            if hasFullAmount && !inCart {
                Button {
                    tappedIngredient = IngredientDetailItem(name: ingredient)
                } label: {
                    Image(systemName: "refrigerator.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.green))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("In your frydge. Show item")
            } else {
                Button {
                    toggleShoppingForIngredientTapOnly(ingredient)
                } label: {
                    Image(systemName: inCart ? "basket.fill" : "basket")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(inCart ? .white : cartTint)
                        .frame(width: 38, height: 38)
                        .background(
                            Circle()
                                .fill(inCart ? Color.blue : Color.gray.opacity(0.12))
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(inCart ? 0 : 0.12), lineWidth: 1)
                        )
                        .opacity(inFlight ? 0.55 : 1.0)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(inFlight)
                .accessibilityLabel(isInShoppingLocal(ingredient) ? "Remove from shopping list" : "Add to shopping list")
            }
        }
        .frame(height: 60)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            needsSwap ? adaptationAccentColor.opacity(0.5) : Color.white.opacity(0.15),
                            lineWidth: needsSwap ? 1.5 : 1
                        )
                )
        )
        .overlay(alignment: .leading) {
            if needsSwap {
                Capsule()
                    .fill(adaptationAccentColor)
                    .frame(width: 4)
                    .padding(.vertical, 10)
                    .padding(.leading, 4)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: needsSwap)
        .padding(.bottom, 2)
    }

    // MARK: - Tap-only shopping toggle (prevents “auto add”)

    private func toggleShoppingForIngredientTapOnly(_ ingredient: String) {
        let k = norm(ingredient)
        guard !k.isEmpty else { return }

        if shoppingActionInFlight.contains(k) { return }
        shoppingActionInFlight.insert(k)

        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                shoppingActionInFlight.remove(k)
            }
        }

        let need = shoppingNeed(for: ingredient)
        let isAlreadyOnList = shoppingListManager.isInShoppingList(ingredient) || shoppingListManager.isInShoppingList(need.name) || isInShoppingLocal(ingredient)

        if isAlreadyOnList {
            shoppingListManager.removeFromShoppingList(need.name)
        } else {
            let tagsToApply = normalizedDietaryTags(recipe.dietaryTags)
            // Already have the full amount (or the line didn't parse a
            // quantity): still honour the tap by adding one purchasable unit,
            // rather than silently doing nothing.
            if let q = need.quantity, q > 0 {
                // ShoppingListManager rounds this up to a purchasable pack size.
                shoppingListManager.addToShoppingList(
                    name: need.name,
                    quantity: formatQuantity(q),
                    unit: need.unit,
                    location: "Shopping",
                    dietaryTags: tagsToApply
                )
            } else {
                shoppingListManager.addToShoppingList(
                    name: need.name.isEmpty ? ingredient : need.name,
                    quantity: "1",
                    unit: need.unit,
                    location: "Shopping",
                    dietaryTags: tagsToApply
                )
            }
        }

        syncShoppingSetFromManager()
    }

    // MARK: - Explicit bulk add

    private func missingIngredients() -> [String] {
        recipe.ingredients.filter { ing in
            !ingredientHasFullAmount(ing) && !shoppingListManager.isInShoppingList(ing) && !isInShoppingLocal(ing)
        }
    }

    @MainActor
    private func addMissingIngredientsToShoppingList() async {
        guard !bulkAddInFlight else { return }
        bulkAddInFlight = true
        defer { bulkAddInFlight = false }

        let missing = missingIngredients()
        guard !missing.isEmpty else {
            syncShoppingSetFromManager()
            return
        }

        let tagsToApply = normalizedDietaryTags(recipe.dietaryTags)

        for ing in missing {
            let need = shoppingNeed(for: ing)
            if let q = need.quantity {
                // ShoppingListManager rounds this up to a purchasable pack size.
                shoppingListManager.addToShoppingList(
                    name: need.name,
                    quantity: formatQuantity(q),
                    unit: need.unit,
                    location: "Shopping",
                    dietaryTags: tagsToApply
                )
            } else {
                shoppingListManager.addToShoppingList(
                    name: ing,
                    quantity: "1",
                    unit: "",
                    location: "Shopping",
                    dietaryTags: tagsToApply
                )
            }
        }

        syncShoppingSetFromManager()
        appState.showBanner(
            title: "Shopping list updated",
            message: "Added \(missing.count) missing ingredient\(missing.count == 1 ? "" : "s").",
            systemImage: "cart.badge.plus",
            style: .success
        )
    }

    // MARK: - Shopping state sync

    private func syncShoppingSetFromManager() {
        let keys = shoppingListManager.shoppingListItems.map { $0.normalizedKey }
        shoppingSet = Set(keys)
    }

    // MARK: - Helpers

    private func norm(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isIngredientInFridge(_ raw: String) -> Bool {
        matchedStoredIngredient(for: raw) != nil
    }

    private func isInShoppingLocal(_ raw: String) -> Bool {
        let parsed = parseIngredient(raw)
        return shoppingSet.contains(norm(raw)) || shoppingSet.contains(norm(parsed.name))
    }

    private func normalizedDietaryTags<S: Sequence>(_ rawTags: S) -> Set<String> where S.Element == String {
        let wanted: Set<String> = ["DF", "GF", "V", "VG", "DAIRY FREE", "GLUTEN FREE", "VEGETARIAN", "VEGAN"]

        let normalized = rawTags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { wanted.contains($0) }
            .map { t -> String in
                if t == "DAIRY FREE" { return "DF" }
                if t == "GLUTEN FREE" { return "GF" }
                if t == "VEGETARIAN" { return "V" }
                if t == "VEGAN" { return "VG" }
                return t
            }

        return Set(normalized)
    }

    // MARK: - Header image

    private var imageView: some View {
        // Reserve the same space that the photo renders into, including in iPad sheets.
        Color.clear
            .aspectRatio(5 / 3, contentMode: .fit)
            .frame(maxHeight: 360)
            .overlay {
                GeometryReader { geo in
                    let height = geo.size.height

                    ZStack {
                        imageCarousel(height: height)

                        // Soft scrim at the foot of the photo so the info panel below
                        // sits on a settled edge rather than a hard photo cut-off.
                        LinearGradient(
                            colors: [Color.clear, Color.black.opacity(0.28)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                        .frame(height: height)
                        .frame(maxWidth: .infinity)
                        .allowsHitTesting(false)

                        if let cookTime = headerCookTime {
                            Label(cookTime, systemImage: "timer")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                                .foregroundColor(.primary)
                                .padding(12)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        }

                        if let credit = recipe.imageCredit, !credit.displayCredit.isEmpty {
                            Text(credit.displayCredit)
                                .font(.caption2)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.55))
                                .cornerRadius(4)
                                .padding(6)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        }
                    }
                    .frame(width: geo.size.width, height: height)
                }
            }
            .clipped()
    }

    @ViewBuilder
    private func imageCarousel(height: CGFloat) -> some View {
        let hasExtra = !extraImageURLs.isEmpty
        let mainImage = recipe.image ?? imageLoader.image

        if let img = mainImage, hasExtra {
            TabView {
                headerImage(img, height: height)
                    .tag(0)
                ForEach(extraImageURLs.indices, id: \.self) { i in
                    CachedAsyncImage(url: extraImageURLs[i]) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(height: height)
                                .frame(maxWidth: .infinity)
                                .clipped()
                                .cornerRadius(5)
                        default:
                            placeholderHeaderImage(height: height)
                        }
                    }
                    .tag(i + 1)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .frame(height: height)
        } else if let img = mainImage {
            headerImage(img, height: height)
        } else {
            // Same artwork as the list card, so a recipe without a photo
            // still opens to a full-bleed image; a spinner shows while the
            // loader is still trying disk, CloudKit and the remote URL.
            placeholderHeaderImage(height: height)
                .overlay(alignment: .bottomLeading) {
                    if imageLoader.isLoading {
                        ProgressView().tint(.white).padding(14)
                    }
                }
        }
    }

    private func buildExtraImageURLs() {
        var urls: [URL] = []
        if let creditURLString = recipe.imageCredit?.imageURL,
           creditURLString != recipe.imageSourceURL,
           let url = URL(string: creditURLString) {
            urls.append(url)
        }
        extraImageURLs = urls
    }

    private func headerImage(_ image: UIImage, height: CGFloat) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipped()
            .cornerRadius(5)
    }

    private var headerCookTime: String? {
        let seconds = totalCookTimeSeconds(for: recipe)
        guard seconds > 0 else { return nil }
        return formatCookTime(seconds)
    }

    private func placeholderHeaderImage(height: CGFloat) -> some View {
        RecipePlaceholderArtwork(recipeName: recipe.name, category: RecipeCategory.classify(recipe), emojiScale: 0.36)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipped()
    }


    private func loadLocalHeaderImage() -> UIImage? {
        for url in localHeaderImageURLs() {
            if let image = UIImage.frydgeBounded(contentsOf: url, maxPixelSize: ImageBudget.display) {
                return image
            }
        }
        return nil
    }

    private func cacheHeaderImage(_ image: UIImage) {
        guard let data = image.frydgeBoundedJPEG(maxPixelSize: ImageBudget.display, quality: 0.82) else { return }
        cacheHeaderImageData(data)
    }

    private func cacheHeaderImageData(_ data: Data) {
        let targetURL = primaryLocalHeaderImageURL()
        do {
            try FileManager.default.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: targetURL, options: [.atomic])
        } catch {
            print("[RECIPE] Failed to cache header image for \(recipe.id): \(error.localizedDescription)")
        }
    }

    private func localHeaderImageURLs() -> [URL] {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return [
            documentsURL
                .appendingPathComponent("recipe-images", isDirectory: true)
                .appendingPathComponent("\(recipe.id).jpg"),
            documentsURL.appendingPathComponent("\(recipe.id).jpg")
        ]
    }

    private func primaryLocalHeaderImageURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recipe-images", isDirectory: true)
            .appendingPathComponent("\(recipe.id).jpg")
    }

    // MARK: - Dietary badges

    private var normalizedRecipeDietaryTags: [String] {
        normalizedDietaryTags(recipe.dietaryTags).sorted()
    }

    private var dietaryBadges: some View {
        HStack(spacing: 8) {
            ForEach(normalizedRecipeDietaryTags, id: \.self) { tag in
                DietaryBadgeChip(tag: tag, tone: dietaryHeaderTone(for: tag))
            }
        }
    }

    private func dietaryHeaderTone(for tag: String) -> DietaryBadgeChip.Tone {
        switch tag.uppercased() {
        case "GF": return .green
        case "DF": return .orange
        case "V":  return .teal
        case "VG": return .green
        default:   return .gray
        }
    }

    private var adaptationAccentColor: Color {
        switch selectedDietaryTag?.uppercased() {
        case "GF": return .green
        case "DF": return .orange
        case "V":  return .teal
        case "VG": return .green
        default:   return .blue
        }
    }

    private enum DietaryColorState { case green, orange, gray }

    private func dietaryColor(for tag: String, recipe: CloudRecipe, fridgeIndex: [String: StoredIngredient]) -> DietaryColorState {
        var hasNameMatch = false
        var hasTaggedMatch = false

        for raw in recipe.ingredients {
            let key = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if let item = fridgeIndex.first(where: { (k, _) in key.contains(k) || k.contains(key) })?.value {
                hasNameMatch = true
                if item.dietaryTags.contains(tag) { hasTaggedMatch = true }
            }
        }

        if !hasNameMatch { return .gray }
        return hasTaggedMatch ? .green : .orange
    }

    private func dietaryColors(for state: DietaryColorState) -> (bg: Color, fg: Color) {
        switch state {
        case .green:  return (Color.green.opacity(0.18), .green)
        case .orange: return (Color.orange.opacity(0.18), .orange)
        case .gray:   return (Color.gray.opacity(0.15), .gray)
        }
    }

    // MARK: - Favourites helpers

    private var favouriteIDs: Set<String> {
        let parts = favoriteRecipeIDsCSV
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Set(parts)
    }

    private func isFavourite(recipeID: String) -> Bool {
        favouriteIDs.contains(recipeID)
    }

    private func toggleFavourite(recipeID: String) {
        var ids = favouriteIDs
        if ids.contains(recipeID) {
            ids.remove(recipeID)
        } else {
            ids.insert(recipeID)
        }
        favoriteRecipeIDsCSV = ids.sorted().joined(separator: ",")
    }

    private var favouriteMetricBadge: some View {
        Button {
            toggleFavourite(recipeID: recipe.id)
        } label: {
            Image(systemName: isFavourite(recipeID: recipe.id) ? "star.fill" : "star")
                .font(.caption)
                .frame(width: 28, height: 28)
            .foregroundColor(isFavourite(recipeID: recipe.id) ? .yellow : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder((isFavourite(recipeID: recipe.id) ? Color.yellow.opacity(0.6) : Color.white.opacity(0.15)), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavourite(recipeID: recipe.id) ? "Remove from favourites" : "Add to favourites")
    }

    // MARK: - Editing

    private func saveEditedRecipe(_ updatedRecipe: CloudRecipe) {
        recipe = updatedRecipe

        let authored = max(1, Int(updatedRecipe.serves.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 4)
        baseServes = authored

        servingSize = authored
    }
    
    // MARK: - Post-cook loop

    /// Entry point once the step-by-step cook-along finishes. Runs the fridge
    /// deduction confirmation (scaled to what's actually in the fridge), then
    /// hands off to the leftovers prompt, then back to the Frydge tab.
    private func startPostCookFlow() {
        pendingLeftoverAfterCook = true
        depletedIngredientNames = []

        let matches = cookDeductionMatches()
        if matches.isEmpty {
            // Nothing to deduct — go straight to storing leftovers.
            presentLeftoverSheet()
        } else {
            cookMatches = matches
            cookEstimates = autoUsageEstimates(for: matches)
            // Let the full-screen cook view finish dismissing before presenting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                showCookConfirmation = true
            }
        }
    }

    /// For each matched fridge item, work out how much of it this recipe uses —
    /// parsed recipe amount (scaled to the chosen serves) plus a wastage buffer,
    /// expressed as a percentage of the item's remaining stock. Items we can't
    /// parse fall back to "all of it" so nothing is silently under-deducted.
    private func autoUsageEstimates(for items: [StoredIngredient]) -> [UUID: CookUsageEstimate] {
        let wastage = 1.10 // ~10% for peelings, spills, sticking to the pan
        var out: [UUID: CookUsageEstimate] = [:]

        for item in items {
            let remainingPercent = max(0, 100 - item.quantityUsed)

            guard let raw = recipeIngredientMatching(item) else {
                out[item.id] = CookUsageEstimate(percent: remainingPercent, detail: nil, isEstimated: false)
                continue
            }

            let parsed = parseIngredient(raw)
            let recipeUnit = parsed.unit ?? ""

            guard let requiredBase = parsed.quantity, requiredBase > 0,
                  let total = parseNumberOrFraction(item.quantity), total > 0,
                  unitsCompatible(itemUnit: item.unit, recipeUnit: recipeUnit) else {
                out[item.id] = CookUsageEstimate(percent: remainingPercent, detail: nil, isEstimated: false)
                continue
            }

            let required = requiredBase * portionMultiplier * wastage
            let deltaPercent = min(remainingPercent, (required / total) * 100).rounded()
            let unitLabel = recipeUnit.isEmpty ? "" : " \(recipeUnit)"
            let detail = "≈\(formatQuantity(min(required, total)))\(unitLabel) of \(formatQuantity(total))\(unitLabel) · incl. ~10% waste"

            out[item.id] = CookUsageEstimate(percent: deltaPercent, detail: detail, isEstimated: true)
        }
        return out
    }

    /// The recipe ingredient line that best matches a fridge item (used to read
    /// the required quantity for auto-deduction).
    private func recipeIngredientMatching(_ item: StoredIngredient) -> String? {
        for raw in recipe.ingredients {
            let parsed = parseIngredient(raw)
            let recipeName = parsed.name.isEmpty ? raw : parsed.name
            if ingredientNamesMatch(fridgeName: item.name, recipeName: recipeName) {
                return raw
            }
        }
        return nil
    }

    private func unitsCompatible(itemUnit: String, recipeUnit: String) -> Bool {
        let a = norm(itemUnit)
        let b = norm(recipeUnit)
        return a == b || a.isEmpty || b.isEmpty
    }

    private func presentLeftoverSheet() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            showLeftoverSheet = true
        }
    }

    /// Restock the items that were fully used up while cooking.
    private func addRestockToShoppingList(_ names: [String]) {
        guard !names.isEmpty else { return }
        for name in names {
            shoppingListManager.addToShoppingList(
                name: name,
                quantity: "",
                unit: "",
                location: "Store",
                dietaryTags: []
            )
        }
        appState.showBanner(
            title: "Added to shopping list",
            message: names.count == 1 ? names[0] : "\(names.count) items to restock",
            systemImage: "cart.badge.plus",
            style: .success
        )
    }

    // MARK: - Cook Recipe
    
    private func cookRecipe() {
        // Never silently delete fridge items. Find the items this recipe plausibly
        // uses, then let the user confirm what (and how much) was actually used.
        let matches = cookDeductionMatches()

        guard !matches.isEmpty else {
            // Nothing in the fridge matched — just acknowledge the cook.
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return
        }

        cookMatches = matches
        cookEstimates = autoUsageEstimates(for: matches)
        showCookConfirmation = true
    }

    /// Unique fridge items this recipe plausibly uses, using word-boundary matching
    /// (so "ice" never matches "rice"), deduped by id and limited to real food items.
    private func cookDeductionMatches() -> [StoredIngredient] {
        var seen = Set<UUID>()
        var result: [StoredIngredient] = []
        for raw in recipe.ingredients {
            let parsed = parseIngredient(raw)
            let recipeName = parsed.name.isEmpty ? raw : parsed.name
            for item in frydgeManager.storedIngredients where item.lifecycle == .fridge {
                guard !seen.contains(item.id) else { continue }
                if ingredientNamesMatch(fridgeName: item.name, recipeName: recipeName) {
                    seen.insert(item.id)
                    result.append(item)
                }
            }
        }
        return result
    }

    /// Shared matcher: shared whole words or stems, after synonym normalisation.
    private func ingredientNamesMatch(fridgeName: String, recipeName: String) -> Bool {
        IngredientMatcher.matches(fridgeName, recipeName)
    }

    // MARK: - Ingredient helpers

    private struct IngredientNeed {
        let name: String
        let quantity: Double?
        let unit: String
        let available: Double?
    }

    /// Resolves a recipe line to the fridge item that covers it, through the
    /// shared matcher (RecipeMatch.swift) so this screen's have/missing counts
    /// agree with the recipes list and the item detail sheet.
    private func matchedStoredIngredient(for raw: String) -> StoredIngredient? {
        frydgeManager.matchedFridgeItem(for: raw)
    }

    private func matchedShoppingListItem(for raw: String) -> ShoppingListItem? {
        let parsed = parseIngredient(raw)
        let key = norm(parsed.name.isEmpty ? raw : parsed.name)
        return shoppingListManager.shoppingListItems.first { item in
            let n = norm(item.name)
            return key.contains(n) || n.contains(key)
        }
    }

    /// Covered by the fridge, including amount, via the shared readiness
    /// matcher (so it matches the list rows and the Cook button).
    private func ingredientHasFullAmount(_ raw: String) -> Bool {
        readiness.status(for: raw)?.isCovered ?? false
    }

    private func shoppingNeed(for raw: String) -> IngredientNeed {
        let parsed = parseIngredient(raw)
        let displayName = parsed.name.isEmpty ? raw : parsed.name
        let unit = parsed.unit ?? ""
        let required = parsed.quantity.map { max(0, $0 * portionMultiplier) }
        let item = matchedStoredIngredient(for: raw)
        let available = comparableAvailableQuantity(for: item, requiredUnit: unit)

        if let required, let available {
            return IngredientNeed(
                name: displayName,
                quantity: max(0, required - available),
                unit: unit,
                available: available
            )
        }

        return IngredientNeed(
            name: displayName,
            quantity: required,
            unit: unit,
            available: available
        )
    }

    private func shoppingNeedDisplay(for raw: String) -> String? {
        let need = shoppingNeed(for: raw)
        guard let quantity = need.quantity else { return nil }
        let formatted = formatQuantity(quantity)
        return need.unit.isEmpty ? "x\(formatted)" : "\(formatted) \(need.unit)"
    }

    /// What tapping the cart actually adds: the shortfall rounded up to a
    /// purchasable pack (eggs in 6s, butter in 250 g blocks, …).
    private func shoppingBuyDisplay(for raw: String) -> String? {
        let need = shoppingNeed(for: raw)
        guard let quantity = need.quantity else { return nil }
        if let buy = PackSizeRules.purchaseDisplay(name: need.name, needed: quantity, unit: need.unit) {
            return buy.unit.isEmpty ? "x\(buy.quantity)" : "\(buy.quantity) \(buy.unit)"
        }
        let formatted = formatQuantity(quantity)
        return need.unit.isEmpty ? "x\(formatted)" : "\(formatted) \(need.unit)"
    }

    private func comparableAvailableQuantity(for item: StoredIngredient?, requiredUnit: String) -> Double? {
        guard let item else { return nil }
        let itemUnit = norm(item.unit)
        let unit = norm(requiredUnit)
        guard itemUnit == unit || itemUnit.isEmpty || unit.isEmpty else { return nil }
        guard let total = parseNumberOrFraction(item.quantity) else { return nil }
        let remainingRatio = max(0, min(1, 1 - (item.quantityUsed / 100)))
        return total * remainingRatio
    }

    private func iconForStorage(for raw: String) -> String {
        if let item = matchedStoredIngredient(for: raw) {
            let n = norm(item.name)
            if isFreezerLikely(n) { return "snowflake" }
        }
        return isFreezerLikely(norm(raw)) ? "snowflake" : "drop.fill"
    }

    private func isFreezerLikely(_ s: String) -> Bool {
        let hints = ["frozen", "freezer", "ice cream", "ice-cream", "peas (frozen)", "spinach (frozen)"]
        return hints.contains { s.contains($0) }
    }

    // MARK: - Dietary Substitution Engine

    private func computeSubstitutions(tag: String) -> [(original: String, substitute: String)] {
        recipe.ingredients.compactMap { ingredient in
            let lower = ingredient.lowercased()
            let sub: String?
            switch tag {
            case "GF": sub = gfSubstitute(lower)
            case "DF": sub = dfSubstitute(lower)
            case "V":  sub = vSubstitute(lower)
            case "VG": sub = vgSubstitute(lower)
            default:   sub = nil
            }
            guard let sub else { return nil }
            return (original: ingredient, substitute: sub)
        }
    }

    private func gfSubstitute(_ s: String) -> String? {
        let gfFlours = ["rice flour", "almond flour", "tapioca flour", "cornflour", "corn flour",
                        "buckwheat flour", "chickpea flour", "coconut flour", "gluten-free flour",
                        "polenta", "arrowroot"]
        let gfPasta  = ["rice pasta", "gluten-free pasta", "lentil pasta", "chickpea pasta",
                        "rice noodle", "glass noodle", "vermicelli"]
        let gfBread  = ["gluten-free bread", "rice bread", "corn tortilla", "rice cracker"]

        if s.contains("flour") && !gfFlours.contains(where: s.contains) {
            return "gluten-free flour blend (1:1 swap)"
        }
        if s.contains("soy sauce") && !s.contains("tamari") {
            return "tamari (gluten-free soy sauce, same quantity)"
        }
        let pastaWords = ["pasta", "noodle", "spaghetti", "fettucine", "penne", "linguine", "tagliatelle"]
        if pastaWords.contains(where: s.contains) && !gfPasta.contains(where: s.contains) {
            return "certified gluten-free pasta or rice noodles"
        }
        if s.contains("breadcrumb") && !s.contains("gluten-free") {
            return "gluten-free breadcrumbs (1:1)"
        }
        if s.contains("bread") && !gfBread.contains(where: s.contains) && !s.contains("breadcrumb") {
            return "gluten-free bread"
        }
        if s.contains("barley") { return "quinoa or rice" }
        if s.contains("couscous") { return "quinoa (same quantity, cooked)" }
        if s.contains("beer") && !s.contains("gluten-free") { return "gluten-free beer or dry apple cider" }
        if s.contains("oat") && !s.contains("gluten-free") { return "certified gluten-free oats" }
        if s.contains("teriyaki") && !s.contains("gluten-free") { return "gluten-free teriyaki sauce" }
        if s.contains("miso") && !s.contains("gluten-free") && !s.contains("rice miso") {
            return "certified gluten-free rice miso"
        }
        return nil
    }

    private func dfSubstitute(_ s: String) -> String? {
        let plantMilks = ["oat milk", "almond milk", "soy milk", "coconut milk", "rice milk",
                          "cashew milk", "hemp milk", "oat cream", "coconut cream", "coconut yogurt"]
        let nonDairyButter = ["peanut butter", "almond butter", "nut butter", "cashew butter",
                               "sunflower butter", "vegan butter", "coconut oil", "olive oil"]

        if s.contains("milk") && !plantMilks.contains(where: s.contains) {
            return "oat milk or almond milk (1:1)"
        }
        if s.contains("butter") && !nonDairyButter.contains(where: s.contains) {
            return "vegan butter or coconut oil (¾ the amount)"
        }
        if s.contains("cream cheese") { return "dairy-free cream cheese or blended cashews" }
        if s.contains("heavy cream") || s.contains("double cream") || s.contains("whipping cream") {
            return "full-fat coconut cream (1:1)"
        }
        if s.contains("sour cream") { return "dairy-free sour cream or coconut yogurt" }
        if s.contains("ice cream") { return "coconut-based dairy-free ice cream" }
        if s.contains("cream") && !plantMilks.contains(where: s.contains) {
            return "coconut cream (1:1)"
        }
        if s.contains("cheese") && !s.contains("dairy-free") && !s.contains("vegan") {
            return "dairy-free cheese (same quantity)"
        }
        if s.contains("yogurt") || s.contains("yoghurt") { return "coconut or dairy-free yogurt" }
        if s.contains("ghee") { return "coconut oil or vegan butter" }
        if s.contains("condensed milk") { return "coconut condensed milk" }
        return nil
    }

    private func vSubstitute(_ s: String) -> String? {
        let meats = ["chicken", "beef", "pork", "lamb", "turkey", "veal", "duck",
                     "venison", "rabbit", "mutton", "goat", "bison"]
        let seafood = ["salmon", "tuna", "cod", "tilapia", "shrimp", "prawn", "crab",
                       "lobster", "clam", "mussel", "oyster", "squid", "anchovies",
                       "sardine", "mackerel", "trout", "halibut", "fish"]

        for meat in meats where s.contains(meat) {
            if s.contains("stock") || s.contains("broth") { return "vegetable stock (same quantity)" }
            return "firm tofu, tempeh, or meat substitute (same weight)"
        }
        for fish in seafood where s.contains(fish) {
            if s.contains("anchovies") || s.contains("anchovy") { return "capers (1:1)" }
            if s.contains("sauce") { return "soy sauce + a squeeze of lime (1:1)" }
            return "firm tofu or hearts of palm (same weight)"
        }
        if s.contains("fish sauce") { return "soy sauce + a squeeze of lime (1:1)" }
        if s.contains("gelatin") { return "agar-agar (use half the amount)" }
        if s.contains("lard") { return "vegetable shortening or coconut oil" }
        if s.contains("bacon") { return "smoked paprika seasoning or coconut bacon" }
        return nil
    }

    private func vgSubstitute(_ s: String) -> String? {
        if let sub = vSubstitute(s) { return sub }
        if let sub = dfSubstitute(s) { return sub }
        if (s.contains("egg") || s.contains("eggs")) && !s.contains("eggplant") && !s.contains("egg noodle") {
            return "flax egg (1 tbsp ground flaxseed + 3 tbsp water, rest 5 min) or aquafaba"
        }
        if s.contains("honey") { return "maple syrup or agave nectar (1:1)" }
        if s.contains("mayonnaise") || s.contains("mayo") { return "vegan mayonnaise (1:1)" }
        if s.contains("worcestershire") { return "vegan Worcestershire sauce" }
        return nil
    }
}

// IngredientThumbnailView, RecipeAdaptationSheet, CookUsageEstimate and
// MarkCookedSheet live in RecipeDetailSupportingViews.swift.

