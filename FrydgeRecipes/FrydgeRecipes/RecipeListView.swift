import SwiftUI
import CloudKit
import UserNotifications
import UIKit

struct RecipeListView: View {
    // @StateObject so the model survives parent re-renders; it was previously
    // @ObservedObject with an inline initialiser, which recreated it (and
    // refetched recipes) whenever HomeView re-rendered.
    @StateObject private var recipeListModel = RecipeListModel()
    @AppStorage("lastViewedRecipeID") var lastViewedRecipeID: String?
    @State private var selectedRecipe: CloudRecipe?

    /// ✅ This is the source of truth for ingredient availability (Fridge + Freezer, etc.)
    @EnvironmentObject var frydgeManager: FrydgeManager
    @EnvironmentObject private var shoppingListManager: ShoppingListManager
    @EnvironmentObject private var sharedShoppingListManager: SharedShoppingListManager
    @EnvironmentObject private var appState: AppState

    // ✅ NEW: Import sheet
    @State private var showingImport = false
    /// One-tap camera import: snap a cookbook page, see fridge match + cost, save.
    @State private var showingSnap = false
    /// Set while a share / universal link is being resolved from CloudKit or
    /// the share payload because the recipe wasn't in the local list.
    @State private var isResolvingSharedRecipe = false
    @State private var suggestRecipe: CloudRecipe?
    @State private var suggestionMessage: String?
    @State private var expandedRecipeID: String?
    /// Recipe whose missing ingredients are being shown ("complete this recipe").
    @State private var missingSheetRecipe: CloudRecipe?

    // MARK: - Add menu (plus button) → three big actions under the header
    @State private var showAddActions = false

    // MARK: - Scroll-driven category popout
    /// True while the list is being scrolled/decelerating; drives the floating
    /// "🐔 Chicken" pill so you always know which chapter you're in.
    @State private var isScrolling = false

    // MARK: - Allergen safety (Profile → Dietary → Can't & won't eat)
    @ObservedObject private var restrictions = DietaryRestrictionStore.shared
    /// Verdict per recipe id, rebuilt only when the recipes or the rules change
    /// so filtering stays instant on every body pass.
    @State private var allergenVerdicts: [String: RecipeAllergenVerdict] = [:]
    @State private var allergenFingerprint = ""
    /// Recipes that hit a can't-eat rule are hidden unless this is on.
    @State private var showUnsafeRecipes = false

    // MARK: - Category tabs (book-style side tabs)

    /// Tab highlighted in the side rail. Follows the topmost visible section
    /// header while scrolling, or the tab the user last tapped.
    @State private var selectedCategory: RecipeCategory?
    @State private var visibleCategoryHeaders: Set<RecipeCategory> = []
    /// Set while a tab-triggered scroll is animating so headers flying past
    /// don't steal the highlight from the tapped tab.
    @State private var suppressHeaderTracking = false

    // MARK: - Filter / prioritisation

    private enum RecipeFilter: String, CaseIterable, Hashable {
        case favourites
        case glutenFree
        case vegetarian
        case vegan
        case dairyFree

        var title: String {
            switch self {
            case .favourites:  return "⭐️ Favourites"
            case .glutenFree:  return "Gluten Free"
            case .vegetarian:  return "🥕 Vegetarian"
            case .vegan:       return "🌱 Vegan"
            case .dairyFree:   return "Dairy Free"
            }
        }

        /// Used for dietary-tag matching against CloudRecipe.dietaryTags
        var dietaryTagKey: String? {
            switch self {
            case .glutenFree:  return "GF"
            case .vegetarian:  return "V"
            case .vegan:       return "VG"
            case .dairyFree:   return "DF"
            case .favourites:  return nil
            }
        }

        var systemImage: String? {
            switch self {
            case .glutenFree: return "leaf"
            case .vegan:      return "leaf.fill"
            default:          return nil
            }
        }
    }

    /// Total-time buckets, from the summed step timers. Single-select; recipes
    /// with no timed steps are left out while a time filter is active, since
    /// their duration is unknown rather than zero.
    private enum RecipeTimeFilter: String, CaseIterable, Hashable {
        case under15
        case under30
        case under60
        case over60

        var title: String {
            switch self {
            case .under15: return "Under 15 min"
            case .under30: return "Under 30 min"
            case .under60: return "Under 1 hr"
            case .over60:  return "Over 1 hr"
            }
        }

        func matches(totalSeconds: Int) -> Bool {
            guard totalSeconds > 0 else { return false }
            switch self {
            case .under15: return totalSeconds <= 15 * 60
            case .under30: return totalSeconds <= 30 * 60
            case .under60: return totalSeconds <= 60 * 60
            case .over60:  return totalSeconds > 60 * 60
            }
        }
    }

    /// Fridge-coverage buckets, from `RecipeMatch.percent`. Single-select,
    /// same as the time filter.
    private enum RecipeMatchFilter: String, CaseIterable, Hashable {
        case complete
        case high
        case half

        var title: String {
            switch self {
            case .complete: return "100% match"
            case .high:     return "75%+ match"
            case .half:     return "50%+ match"
            }
        }

        var threshold: Double {
            switch self {
            case .complete: return 1.0
            case .high:      return 0.75
            case .half:      return 0.5
            }
        }

        func matches(percent: Double) -> Bool { percent >= threshold }
    }

    /// How the list is ordered. Remembered between launches.
    enum RecipeSortOrder: String, CaseIterable, Identifiable {
        case bestMatch
        case newest
        case alphabetical
        case quickest
        case favouritesFirst

        var id: String { rawValue }

        var title: String {
            switch self {
            case .bestMatch:       return "Best fridge match"
            case .newest:          return "Newest first"
            case .alphabetical:    return "A to Z"
            case .quickest:        return "Quickest first"
            case .favouritesFirst: return "Favourites first"
            }
        }

        /// Short label for the chip at the top of the list.
        var shortTitle: String {
            switch self {
            case .bestMatch:       return "Best match"
            case .newest:          return "Newest"
            case .alphabetical:    return "A–Z"
            case .quickest:        return "Quickest"
            case .favouritesFirst: return "Favourites"
            }
        }

        var systemImage: String {
            switch self {
            case .bestMatch:       return "refrigerator"
            case .newest:          return "clock.arrow.circlepath"
            case .alphabetical:    return "textformat.abc"
            case .quickest:        return "timer"
            case .favouritesFirst: return "star"
            }
        }
    }

    @AppStorage("recipeListSortOrder") private var sortOrderRaw: String = RecipeSortOrder.bestMatch.rawValue
    private var sortOrder: RecipeSortOrder {
        get { RecipeSortOrder(rawValue: sortOrderRaw) ?? .bestMatch }
        nonmutating set { sortOrderRaw = newValue.rawValue }
    }

    @State private var selectedFilters: Set<RecipeFilter> = []
    @State private var selectedTimeFilter: RecipeTimeFilter?
    @State private var selectedMatchFilter: RecipeMatchFilter?
    @State private var searchText = ""
    @State private var isSearchVisible = false
    @FocusState private var isSearchFocused: Bool

    /// Number of refine options currently applied, for the Refine chip badge.
    private var activeRefineCount: Int {
        selectedFilters.count + (selectedTimeFilter == nil ? 0 : 1) + (selectedMatchFilter == nil ? 0 : 1)
    }

    /// Simple local favourites store (comma-separated recipe IDs)
    @AppStorage("favoriteRecipeIDs") private var favoriteRecipeIDsCSV: String = ""

    // MARK: - Layout (iPhone vs iPad)

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var availableWidth: CGFloat = 0
    private var isTabletLayout: Bool { horizontalSizeClass == .regular }

    /// Measure this pane, rather than the device: the app sidebar and Split View
    /// both reduce the space available to the cookbook's contents column.
    private var isWideLayout: Bool { isTabletLayout }

    /// Width of the iPad Contents column.
    private let contentsColumnWidth: CGFloat = 200

    /// Horizontal margin for the page grid.
    private var pageHorizontalPadding: CGFloat { isWideLayout ? 20 : 12 }

    /// Use multiple pages when this pane can fit them, even when there
    /// isn't enough space for the separate chapter column.
    private var pageColumns: [GridItem] {
        if availableWidth >= 520 {
            return [GridItem(.adaptive(minimum: isTabletLayout ? 260 : 230, maximum: 420), spacing: 20, alignment: .top)]
        }
        return [GridItem(.flexible(), spacing: 0, alignment: .top)]
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if !isTabletLayout {
                    headerSection
                        .padding(.bottom, 6)
                        .browsingHeader()
                }
                if showAddActions {
                    addActionsRow
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if isTabletLayout {
                    tabletSearchBar
                } else {
                    filterBar
                        .browsingHeader()
                }
                if isSearchVisible && !isTabletLayout {
                    recipeSearchBar
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    Spacer().frame(height: 6)
                }

                // Match, sort, filter and group exactly once per body pass;
                // every page, the contents column and the rail read from this snapshot.
                let snapshot = listSnapshot

                ScrollViewReader { scrollProxy in
                    VStack(spacing: 0) {
                        if isTabletLayout, !snapshot.rail.isEmpty {
                            tabletChapters(rail: snapshot.rail) { category in
                                jump(to: category, using: scrollProxy)
                            }
                        }
                        pageScroll(snapshot: snapshot, scrollProxy: scrollProxy)
                    }
                    .navigationDestination(item: $selectedRecipe) { recipe in
                        RecipeDetailView(recipeListModel: recipeListModel, recipe: recipe)
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.width
            } action: { availableWidth = $0 }
            .padding(.top, 10)
            .background {
                CookbookBackground().ignoresSafeArea()
            }
            .navigationTitle(isTabletLayout ? "Recipes" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.browser)
            .toolbar {
                if isTabletLayout {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("Search", systemImage: "magnifyingglass") { isSearchFocused = true }
                            .keyboardShortcut("f", modifiers: .command)
                        Menu {
                            NavigationLink(destination: RecipeEditorView(recipe: .constant(nil), onSave: { _ in })) {
                                Label("Write a recipe", systemImage: "square.and.pencil")
                            }
                            Button("Scan a recipe", systemImage: "camera") { showingSnap = true }
                            Button("Import from a link", systemImage: "link") { showingImport = true }
                        } label: {
                            Label("Add Recipe", systemImage: "plus")
                        }
                        .help("Write, scan, or import a recipe")
                        NavigationLink(destination: ProfileView()) {
                            Label("Profile", systemImage: "person.crop.circle")
                        }
                    }
                }
            }
            .onAppear {
                initializeView()
                rebuildAllergenVerdicts()
            }
            // Keep the allergen filter instant: recompute when recipes land
            // or the user edits their can't / won't eat rules or profile tags.
            .onChange(of: recipeListModel.recipes.count) { _, _ in
                rebuildAllergenVerdicts(force: true)
            }
            .onReceive(restrictions.$restrictions) { _ in
                rebuildAllergenVerdicts()
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                rebuildAllergenVerdicts()
            }
            .onChange(of: appState.lastViewedRecipeID) { _, _ in
                navigateToPendingRecipeIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: .recipeDidSave)) { _ in
                Task { await recipeListModel.fetchRecipesFromCloud() }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SharedShoppingListChanged"))) { _ in
                Task { await refreshSharedSuggestionTargets() }
            }
            // ✅ NEW: Present importer
            .sheet(isPresented: $showingImport) {
                RecipeImportView()
            }
            .fullScreenCover(isPresented: $showingSnap) {
                RecipeSnapView()
            }
            .sheet(item: $suggestRecipe) { recipe in
                RecipeSuggestionSheet(
                    recipe: recipe,
                    sharedManager: sharedShoppingListManager,
                    onSuggested: { listName in
                        suggestionMessage = "Suggested \(recipe.name) to \(listName)."
                    }
                )
            }
            .sheet(item: $missingSheetRecipe) { recipe in
                RecipeMissingIngredientsSheet(recipe: recipe)
                    .environmentObject(frydgeManager)
                    .environmentObject(shoppingListManager)
            }
            .alert("Recipe Suggested", isPresented: Binding(
                get: { suggestionMessage != nil },
                set: { if !$0 { suggestionMessage = nil } }
            )) {
                Button("OK", role: .cancel) { suggestionMessage = nil }
            } message: {
                Text(suggestionMessage ?? "")
            }
        }
    }

    // MARK: - Filtered recipes

    private struct CategorySection {
        let category: RecipeCategory
        let recipes: [CloudRecipe]
    }

    /// Derived list state. Built once per body pass (see `body`) instead of
    /// recomputing the match/sort/filter chain from several computed
    /// properties, which previously ran it four or five times per render.
    private struct ListSnapshot {
        /// Fridge match for every recipe, so the sort and each row agree.
        let matches: [String: RecipeMatch]
        /// Sorted + filtered recipes.
        let filtered: [CloudRecipe]
        /// `filtered` grouped by main protein, in book order; empty
        /// categories are dropped so there are no blank chapters or dead tabs.
        let sections: [CategorySection]
        /// Recipes dropped because they hit a can't-eat rule (banner count).
        let hiddenUnsafeCount: Int
        /// Unsafe recipes currently shown because the user asked to see them.
        let unsafeShownCount: Int

        var rail: [RecipeCategory] { sections.map(\.category) }
    }

    /// Ordered by the chosen sort (see `RecipeSortOrder`); every order falls
    /// back to fridge match, then most recently edited, so ties are stable.
    private var listSnapshot: ListSnapshot {
        let recipes = recipeListModel.recipes
        let matchByID = Dictionary(
            recipes.map { ($0.id, frydgeManager.recipeMatch(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        let favourites = favouriteIDs
        let order = sortOrder

        func edited(_ r: CloudRecipe) -> Date { r.modificationDate ?? r.creationDate ?? .distantPast }
        func byMatchThenDate(_ a: CloudRecipe, _ b: CloudRecipe) -> Bool {
            let ma = matchByID[a.id]?.percent ?? 0
            let mb = matchByID[b.id]?.percent ?? 0
            if ma != mb { return ma > mb }
            return edited(a) > edited(b)
        }

        let sorted = recipes.sorted { a, b in
            switch order {
            case .bestMatch:
                return byMatchThenDate(a, b)
            case .newest:
                let da = edited(a), db = edited(b)
                if da != db { return da > db }
                return byMatchThenDate(a, b)
            case .alphabetical:
                let cmp = a.displayName.localizedCaseInsensitiveCompare(b.displayName)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return byMatchThenDate(a, b)
            case .quickest:
                // Untimed recipes sink to the bottom rather than reading as "0 min".
                let ta = totalCookTimeSeconds(for: a), tb = totalCookTimeSeconds(for: b)
                if (ta > 0) != (tb > 0) { return ta > 0 }
                if ta != tb { return ta < tb }
                return byMatchThenDate(a, b)
            case .favouritesFirst:
                let fa = favourites.contains(a.id), fb = favourites.contains(b.id)
                if fa != fb { return fa }
                return byMatchThenDate(a, b)
            }
        }

        // Allergen rules apply before everything else: a recipe that hits a
        // can't-eat rule is pulled from the list (unless the user opts to see
        // them), so "no nuts" is honoured the moment the rule is saved.
        var hiddenUnsafe = 0
        var unsafeShown = 0
        let filtered = sorted.filter { recipe in
            if let verdict = allergenVerdicts[recipe.id], verdict.isUnsafe {
                if showUnsafeRecipes {
                    unsafeShown += 1
                } else {
                    hiddenUnsafe += 1
                    return false
                }
            }
            let passesFilters = selectedFilters.isEmpty || selectedFilters.allSatisfy { matches(filter: $0, recipe: recipe) }
            let passesTime = selectedTimeFilter.map { $0.matches(totalSeconds: totalCookTimeSeconds(for: recipe)) } ?? true
            let passesMatch = selectedMatchFilter.map { $0.matches(percent: matchByID[recipe.id]?.percent ?? 0) } ?? true
            return passesFilters && passesTime && passesMatch && matchesSearch(recipe)
        }

        var buckets: [RecipeCategory: [CloudRecipe]] = [:]
        for recipe in filtered {
            buckets[RecipeCategory.classify(recipe), default: []].append(recipe)
        }
        let sections = RecipeCategory.allCases.compactMap { category -> CategorySection? in
            guard let recipes = buckets[category], !recipes.isEmpty else { return nil }
            return CategorySection(category: category, recipes: recipes)
        }

        return ListSnapshot(
            matches: matchByID,
            filtered: filtered,
            sections: sections,
            hiddenUnsafeCount: hiddenUnsafe,
            unsafeShownCount: unsafeShown
        )
    }

    // MARK: - Allergen verdicts

    /// Recomputes the per-recipe allergen verdicts. Called when the recipes
    /// or the user's rules change — never per body pass.
    private func rebuildAllergenVerdicts(force: Bool = false) {
        let fingerprint = RecipeAllergenCheck.rulesFingerprint()
        let recipes = recipeListModel.recipes
        if !force, fingerprint == allergenFingerprint, allergenVerdicts.count == recipes.count {
            return
        }
        allergenFingerprint = fingerprint
        guard RecipeAllergenCheck.hasAnyRules else {
            allergenVerdicts = [:]
            return
        }
        var out: [String: RecipeAllergenVerdict] = [:]
        out.reserveCapacity(recipes.count)
        for recipe in recipes {
            out[recipe.id] = RecipeAllergenCheck.evaluate(recipe)
        }
        allergenVerdicts = out
    }

    /// Banner above the list: how many recipes were pulled for your allergies,
    /// with a toggle to peek at them (they stay clearly marked).
    private func allergenBanner(hidden: Int, shown: Int) -> some View {
        let count = showUnsafeRecipes ? shown : hidden
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(showUnsafeRecipes
                     ? "Showing \(count) recipe\(count == 1 ? "" : "s") you can't eat"
                     : "\(count) recipe\(count == 1 ? "" : "s") hidden for your allergies")
                    .font(.system(.subheadline).weight(.semibold))
                    .foregroundStyle(CookbookTheme.ink)
                Text(showUnsafeRecipes
                     ? "Open one to see what to swap."
                     : "Based on your can't-eat list in Profile.")
                    .font(CookbookTheme.captionFont)
                    .foregroundStyle(CookbookTheme.inkSecondary)
            }
            Spacer()
            Button(showUnsafeRecipes ? "Hide" : "Show") {
                withAnimation(.easeInOut(duration: 0.2)) { showUnsafeRecipes.toggle() }
            }
            .font(.caption.weight(.bold))
            .buttonStyle(.bordered)
            .tint(CookbookTheme.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .cookbookPage(cornerRadius: 16)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.red.opacity(0.45), lineWidth: 1)
        )
        .padding(.horizontal, 6)
        .padding(.top, 6)
    }

    /// The floating "🐔 Chicken" pill shown while scrolling. Tapping opens a
    /// menu of every chapter so it doubles as a quick jump.
    private func categoryPopout(current: RecipeCategory, rail: [RecipeCategory], onJump: @escaping (RecipeCategory) -> Void) -> some View {
        Menu {
            ForEach(rail) { category in
                Button {
                    onJump(category)
                } label: {
                    Label("\(category.emoji)  \(category.title)", systemImage: category == current ? "checkmark" : "arrow.down.to.line")
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(current.emoji)
                    .font(.title3)
                Text(current.title)
                    .font(.system(.subheadline).weight(.bold))
                    .foregroundStyle(CookbookTheme.ink)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(CookbookTheme.inkSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(CookbookTheme.card))
            .overlay(
                Capsule().strokeBorder(current.color.opacity(0.9), lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
        }
        .accessibilityLabel("Now in \(current.title). Jump to another chapter")
    }

    /// Three big actions that drop down from the plus button: write it
    /// yourself (✏️), snap or scan it (📷), or pull it from YouTube, TikTok,
    /// Instagram or any link (⬇️).
    private var addActionsRow: some View {
        HStack(spacing: 10) {
            NavigationLink(destination: RecipeEditorView(recipe: .constant(nil), onSave: { _ in })) {
                addActionLabel(emoji: "✏️", title: "Write it", subtitle: "Type it in")
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { withAnimation { showAddActions = false } })

            Button {
                withAnimation { showAddActions = false }
                showingSnap = true
            } label: {
                addActionLabel(emoji: "📷", title: "Snap / scan", subtitle: "Photo or barcode")
            }
            .buttonStyle(.plain)

            Button {
                withAnimation { showAddActions = false }
                showingImport = true
            } label: {
                addActionLabel(emoji: "⬇️", title: "Download", subtitle: "YouTube, TikTok, links")
            }
            .buttonStyle(.plain)
        }
    }

    private func addActionLabel(emoji: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(emoji)
                .font(.system(size: 28))
            Text(title)
                .font(.system(.caption).weight(.bold))
                .foregroundStyle(CookbookTheme.ink)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(CookbookTheme.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .cookbookPage(cornerRadius: 18)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)")
    }

    // MARK: - Category sections

    private func highlightedCategory(in rail: [RecipeCategory]) -> RecipeCategory? {
        if let selectedCategory, rail.contains(selectedCategory) {
            return selectedCategory
        }
        return rail.first
    }

    // MARK: - Pages

    /// The book itself: chapters of recipe pages in a scrolling grid. The
    /// floating rail and chapter pill only appear on compact widths; on iPad
    /// the Contents column beside it does that job.
    private func pageScroll(snapshot: ListSnapshot, scrollProxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Recipes hidden because they hit a can't-eat rule.
                if snapshot.hiddenUnsafeCount > 0 || (showUnsafeRecipes && snapshot.unsafeShownCount > 0) {
                    allergenBanner(hidden: snapshot.hiddenUnsafeCount, shown: snapshot.unsafeShownCount)
                        .padding(.horizontal, pageHorizontalPadding)
                }

                if snapshot.filtered.isEmpty {
                    emptyPage
                } else {
                    // Recipes are grouped into colour-coded "chapters" by main
                    // protein; the contents / side tabs jump between them.
                    ForEach(Array(snapshot.sections.enumerated()), id: \.element.category) { index, section in
                        chapterHeading(section.category, number: index + 1, count: section.recipes.count)
                            .id(section.category)
                            .onAppear { headerBecameVisible(section.category) }
                            .onDisappear { headerLeftView(section.category) }

                        LazyVGrid(columns: pageColumns, alignment: .leading, spacing: isWideLayout ? 18 : 0) {
                            ForEach(section.recipes, id: \.id) { recipe in
                                VStack(spacing: 0) {
                                    if isTabletLayout {
                                        tabletRecipeCard(recipe, match: snapshot.matches[recipe.id])
                                    } else {
                                        recipeRow(recipe, category: section.category, match: snapshot.matches[recipe.id])
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, pageHorizontalPadding)
                        .padding(.bottom, 10)
                    }

                    colophon(recipeCount: snapshot.filtered.count, chapterCount: snapshot.sections.count)
                }
            }
            // Clear the floating tab bar at the foot of the screen.
            .padding(.bottom, 96)
        }
        .refreshable {
            await recipeListModel.fetchRecipesFromCloud()
        }
        .scrollContentBackground(.hidden)
        .browsingScrollNavigation()
        .background(Color.clear)
        // Drives the floating chapter pill: shown while the book
        // moves, hidden again once it settles.
        .onScrollPhaseChange { _, newPhase in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                isScrolling = newPhase != .idle
            }
        }
        // Side tabs are hidden by default and only slide in while
        // scrolling, so pages get the full width at rest.
        .overlay(alignment: .topTrailing) {
            if !isWideLayout, isScrolling, !snapshot.rail.isEmpty {
                RecipeCategoryTabRail(
                    categories: snapshot.rail,
                    selected: highlightedCategory(in: snapshot.rail)
                ) { category in
                    jump(to: category, using: scrollProxy)
                }
                .padding(.top, 14)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // "🐔 Chicken" popout while scrolling — tap it to jump
        // to any other chapter.
        .overlay(alignment: .top) {
            if !isWideLayout, isScrolling, let current = highlightedCategory(in: snapshot.rail) {
                categoryPopout(current: current, rail: snapshot.rail) { category in
                    jump(to: category, using: scrollProxy)
                }
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
            }
        }
    }

    /// Chapter opener: "CHAPTER ONE" running head, serif title, recipe
    /// count and a rule in the chapter colour.
    @ViewBuilder
    private func chapterHeading(_ category: RecipeCategory, number: Int, count: Int) -> some View {
        if isTabletLayout {
            HStack {
                Text(category.title).font(.title2.bold())
                Text("\(count)").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, pageHorizontalPadding)
            .padding(.top, 24)
            .padding(.bottom, 14)
            .accessibilityAddTraits(.isHeader)
        } else {
            chapterHeader(category, number: number, count: count)
        }
    }

    private var tabletSearchBar: some View {
        HStack(spacing: 16) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search recipes, ingredients…", text: $searchText)
                    .focused($isSearchFocused)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                if !searchText.isEmpty {
                    Button("Clear search", systemImage: "xmark.circle.fill") { searchText = "" }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            sortMenuChip
            refineMenuChip
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func tabletChapters(rail: [RecipeCategory], onJump: @escaping (RecipeCategory) -> Void) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(rail, id: \.self) { category in
                    Button {
                        onJump(category)
                    } label: {
                        Text("\(category.emoji) \(category.title)")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(selectedCategory == category ? Color.accentColor.opacity(0.14) : Color(.secondarySystemGroupedBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 4)
    }

    private func tabletRecipeCard(_ recipe: CloudRecipe, match: RecipeMatch?) -> some View {
        let coverage = match ?? frydgeManager.recipeMatch(for: recipe)
        let seconds = totalCookTimeSeconds(for: recipe)
        return TabletRecipeCard(
            recipe: recipe,
            time: seconds > 0 ? formatCookTime(seconds) : nil,
            matchPercent: coverage.percent,
            missingCount: coverage.missing.count,
            isFavourite: isFavourite(recipeID: recipe.id),
            open: { handleRecipeSelection(recipe) },
            toggleFavourite: { toggleFavourite(recipeID: recipe.id) },
            addMissing: { addMissingIngredientsToShoppingList(for: recipe) },
            suggest: { suggestRecipe = recipe }
        )
    }

    private func chapterHeader(_ category: RecipeCategory, number: Int, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chapter \(CookbookTheme.numeral(number))")
                .font(CookbookTheme.runningHeadFont)
                .tracking(2)
                .foregroundStyle(category.color)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(category.emoji)
                    .font(.title2)
                Text(category.title)
                    .font(CookbookTheme.chapterTitleFont)
                    .foregroundStyle(CookbookTheme.ink)
                Spacer(minLength: 8)
                Text("\(count) recipe\(count == 1 ? "" : "s")")
                    .font(CookbookTheme.metaFont)
                    .foregroundStyle(CookbookTheme.inkSecondary)
            }

            CookbookRule(tint: category.color.opacity(0.7), thickness: 1.5)
        }
        .padding(.horizontal, pageHorizontalPadding + 6)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// iPad table of contents: one line per chapter with a dotted leader
    /// to its number. The current chapter is picked out in its colour.
    private func contentsColumn(rail: [RecipeCategory], selected: RecipeCategory?, onJump: @escaping (RecipeCategory) -> Void) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Contents")
                    .font(CookbookTheme.chapterTitleFont)
                    .foregroundStyle(CookbookTheme.ink)
                CookbookOrnament()
                    .padding(.vertical, 10)

                ForEach(Array(rail.enumerated()), id: \.element) { index, category in
                    let isCurrent = category == selected
                    Button {
                        onJump(category)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(category.emoji)
                                .font(.subheadline)
                            Text(category.title)
                                .font(isCurrent ? CookbookTheme.bodyFont.weight(.semibold) : CookbookTheme.bodyFont)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .layoutPriority(1)
                            CookbookLeader()
                            Text(CookbookTheme.numeral(index + 1))
                                .font(CookbookTheme.metaFont)
                        }
                        .foregroundStyle(isCurrent ? category.color : CookbookTheme.ink)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(category.title) recipes, chapter \(index + 1)")
                    .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
                }
            }
            .padding(18)
            .cookbookPage(cornerRadius: 12)
        }
        .scrollIndicators(.hidden)
        .animation(.easeInOut(duration: 0.2), value: selected)
    }

    /// Closing line at the foot of the book.
    private func colophon(recipeCount: Int, chapterCount: Int) -> some View {
        VStack(spacing: 10) {
            CookbookOrnament(symbol: "❦")
            Text("\(recipeCount) recipe\(recipeCount == 1 ? "" : "s") across \(chapterCount) chapter\(chapterCount == 1 ? "" : "s")")
                .font(CookbookTheme.metaFont)
                .foregroundStyle(CookbookTheme.inkSecondary)
        }
        .padding(.horizontal, pageHorizontalPadding + 24)
        .padding(.top, 26)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }

    /// Blank page shown when nothing matches.
    private var emptyPage: some View {
        VStack(spacing: 10) {
            Text("❧")
                .font(.system(.title))
                .foregroundStyle(CookbookTheme.inkSecondary)
            Text(emptyRecipeListMessage)
                .font(CookbookTheme.metaFont)
                .foregroundStyle(CookbookTheme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func jump(to category: RecipeCategory, using proxy: ScrollViewProxy) {
        selectedCategory = category
        suppressHeaderTracking = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeInOut(duration: 0.35)) {
            proxy.scrollTo(category, anchor: .top)
        }
        Task {
            try? await Task.sleep(for: .seconds(0.7))
            suppressHeaderTracking = false
        }
    }

    private func headerBecameVisible(_ category: RecipeCategory) {
        visibleCategoryHeaders.insert(category)
        syncSelectedCategoryToScroll()
    }

    private func headerLeftView(_ category: RecipeCategory) {
        visibleCategoryHeaders.remove(category)
        syncSelectedCategoryToScroll()
    }

    /// Highlight the topmost visible chapter heading. When no heading is on
    /// screen the previous highlight stays put.
    private func syncSelectedCategoryToScroll() {
        guard !suppressHeaderTracking else { return }
        if let topmost = visibleCategoryHeaders.min(by: { $0.sortOrder < $1.sortOrder }) {
            selectedCategory = topmost
        }
    }

    private var emptyRecipeListMessage: String {
        if recipeListModel.recipes.isEmpty {
            return "No recipes available."
        }

        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No recipes match that search."
        }

        return "No recipes match those filters."
    }

    private func matches(filter: RecipeFilter, recipe: CloudRecipe) -> Bool {
        switch filter {
        case .favourites:
            return isFavourite(recipeID: recipe.id)
        case .glutenFree, .vegetarian, .vegan, .dairyFree:
            if let key = filter.dietaryTagKey {
                return recipe.dietaryTags.contains(key)
            }
            return false
        }
    }

    private func matchesSearch(_ recipe: CloudRecipe) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }

        if recipe.name.localizedCaseInsensitiveContains(query) {
            return true
        }

        return recipe.ingredients.contains { ingredient in
            ingredient.localizedCaseInsensitiveContains(query)
        }
    }

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

    /// Title page: small-caps "FRYDGE" running head, "Recipes" in serif and
    /// the recipe count as an italic subtitle, with add / profile in ink.
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Frydge")
                        .font(CookbookTheme.runningHeadFont)
                        .tracking(3)
                        .foregroundStyle(CookbookTheme.inkSecondary)

                    Text("Recipes")
                        .font(CookbookTheme.bookTitleFont)
                        .foregroundStyle(CookbookTheme.ink)

                }

                Spacer()

                // Single entry point for all three ways to add a recipe:
                // tapping drops down three big buttons (write ✏️, snap/scan
                // 📷, download ⬇️) under the header instead of a text menu.
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        showAddActions.toggle()
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title)
                        .foregroundStyle(CookbookTheme.accent)
                        .rotationEffect(.degrees(showAddActions ? 45 : 0))
                }
                .accessibilityLabel(showAddActions ? "Close add recipe options" : "Add recipe")

                Spacer()

                NavigationLink(destination: ProfileView()) {
                    Image(systemName: "person.crop.circle")
                        .font(.title)
                        .foregroundStyle(CookbookTheme.ink)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 2)
    }

    private var filterBar: some View {
        // Note: 10px height is too small for tappable targets.
        // This bar uses a compact height while keeping taps accessible.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                searchToggleChip

                // Just the two drop-downs: list order, and one refine menu
                // holding the dietary, time and fridge-match lists. The
                // per-filter chip rows were removed so the bar stays short.
                sortMenuChip
                refineMenuChip
            }
            .padding(.horizontal)
        }
        .frame(height: 44)
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: isSearchVisible)
    }

    /// "Sort: Best match ▾" — picks the list order.
    private var sortMenuChip: some View {
        Menu {
            Picker("List order", selection: Binding(
                get: { sortOrder },
                set: { sortOrder = $0 }
            )) {
                ForEach(RecipeSortOrder.allCases) { order in
                    Label(order.title, systemImage: order.systemImage).tag(order)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.caption.weight(.semibold))
                Text(sortOrder.shortTitle)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(CookbookTheme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(CookbookTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(CookbookTheme.rule, lineWidth: 1)
            )
        }
        .accessibilityLabel("List order: \(sortOrder.title)")
    }

    /// "Refine ▾" — every filter in one menu, with a count of what's applied.
    private var refineMenuChip: some View {
        Menu {
            Section("Dietary & favourites") {
                ForEach(RecipeFilter.allCases, id: \.self) { filter in
                    Toggle(isOn: Binding(
                        get: { selectedFilters.contains(filter) },
                        set: { on in if on { selectedFilters.insert(filter) } else { selectedFilters.remove(filter) } }
                    )) {
                        Label(filter.title, systemImage: filter.systemImage ?? "checkmark")
                    }
                }
            }

            Section("Total time") {
                ForEach(RecipeTimeFilter.allCases, id: \.self) { filter in
                    Toggle(isOn: Binding(
                        get: { selectedTimeFilter == filter },
                        set: { on in selectedTimeFilter = on ? filter : nil }
                    )) {
                        Label(filter.title, systemImage: "timer")
                    }
                }
            }

            Section("Fridge match") {
                ForEach(RecipeMatchFilter.allCases, id: \.self) { filter in
                    Toggle(isOn: Binding(
                        get: { selectedMatchFilter == filter },
                        set: { on in selectedMatchFilter = on ? filter : nil }
                    )) {
                        Label(filter.title, systemImage: "refrigerator")
                    }
                }
            }

            if activeRefineCount > 0 {
                Button(role: .destructive) {
                    selectedFilters.removeAll()
                    selectedTimeFilter = nil
                    selectedMatchFilter = nil
                } label: {
                    Label("Clear all", systemImage: "xmark.circle")
                }
            }
        } label: {
            let count = activeRefineCount
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.caption.weight(.semibold))
                Text("Refine")
                    .font(.caption)
                    .fontWeight(.semibold)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(CookbookTheme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(CookbookTheme.card))
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(count > 0 ? CookbookTheme.card : CookbookTheme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(count > 0 ? CookbookTheme.accent : CookbookTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(count > 0 ? Color.clear : CookbookTheme.rule, lineWidth: 1)
            )
        }
        .accessibilityLabel(activeRefineCount > 0 ? "Refine, \(activeRefineCount) applied" : "Refine")
    }

    private var searchToggleChip: some View {
        Button {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                isSearchVisible.toggle()
                if !isSearchVisible {
                    searchText = ""
                    isSearchFocused = false
                }
            }

            if isSearchVisible {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    isSearchFocused = true
                }
            }
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSearchVisible ? CookbookTheme.card : CookbookTheme.ink)
                .frame(width: 36, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSearchVisible ? CookbookTheme.accent : CookbookTheme.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(CookbookTheme.rule, lineWidth: isSearchVisible ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSearchVisible ? "Hide recipe search" : "Show recipe search")
    }

    private var recipeSearchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)

            TextField("Search recipes or ingredients", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isSearchFocused)
                .submitLabel(.search)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    isSearchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear recipe search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CookbookTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSearchFocused ? CookbookTheme.accent.opacity(0.6) : CookbookTheme.rule, lineWidth: 1)
        )
    }

    private func filterChip(_ filter: RecipeFilter) -> some View {
        let isOn = selectedFilters.contains(filter)

        return Button {
            if isOn {
                selectedFilters.remove(filter)
            } else {
                selectedFilters.insert(filter)
            }
        } label: {
            HStack(spacing: 6) {
                if let systemImage = filter.systemImage {
                    Image(systemName: systemImage)
                        .font(.caption)
                }
                Text(filter.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            .foregroundColor(isOn ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isOn ? Color.blue : Color.gray.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.gray.opacity(0.35), lineWidth: isOn ? 0 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(filter.title)
    }

    /// Single-select time chip: tapping the active one clears it.
    private func timeFilterChip(_ filter: RecipeTimeFilter) -> some View {
        let isOn = selectedTimeFilter == filter

        return Button {
            selectedTimeFilter = isOn ? nil : filter
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .font(.caption)
                Text(filter.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            .foregroundColor(isOn ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isOn ? Color.orange : Color.gray.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.gray.opacity(0.35), lineWidth: isOn ? 0 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Total time \(filter.title)")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    /// Single-select fridge-match chip: tapping the active one clears it.
    private func matchFilterChip(_ filter: RecipeMatchFilter) -> some View {
        let isOn = selectedMatchFilter == filter

        return Button {
            selectedMatchFilter = isOn ? nil : filter
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cart")
                    .font(.caption)
                Text(filter.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            .foregroundColor(isOn ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isOn ? Color.green : Color.gray.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.gray.opacity(0.35), lineWidth: isOn ? 0 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Fridge match \(filter.title)")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Cell

    private func recipeRow(_ recipe: CloudRecipe, category: RecipeCategory, match: RecipeMatch?) -> some View {
        let isExpanded = expandedRecipeID == recipe.id

        return VStack(spacing: 0) {
            recipeItem(recipe, category: category, match: match)
                .scaleEffect(isExpanded ? 1.035 : 1.0, anchor: .center)
                .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isExpanded)
                .padding(.horizontal, 6)
                .padding(.bottom, isExpanded ? 6 : 10)

            if isExpanded {
                recipeInlineActionBar(for: recipe)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isExpanded)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            if isExpanded {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    expandedRecipeID = nil
                }
            } else {
                handleRecipeSelection(recipe)
            }
        }
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.28)
                .onEnded { _ in
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        expandedRecipeID = isExpanded ? nil : recipe.id
                    }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
        )
    }

    /// Long-press tray under a card. Liquid Glass buttons that morph together
    /// in one `GlassEffectContainer`, each with a caption so nothing needs
    /// guessing; Share is the big primary action; then the comments
    /// drop-down for this recipe (list only).
    private func recipeInlineActionBar(for recipe: CloudRecipe) -> some View {
        let missingCount = frydgeManager.recipeMatch(for: recipe).missing.count
        return VStack(spacing: 10) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    // Native share menu (link / text / card / copy); the
                    // public preview is published in the background.
                    RecipeShareMenu(recipe: recipe, style: .tray)
                    recipeActionButton(systemImage: "eye", label: "Open") {
                        withAnimation(.spring(response: 0.25)) { expandedRecipeID = nil }
                        handleRecipeSelection(recipe)
                    }
                    recipeActionButton(
                        systemImage: sharedShoppingListManager.isLoading ? "hourglass" : "bubble.left.and.bubble.right",
                        label: "Suggest"
                    ) {
                        withAnimation(.spring(response: 0.25)) { expandedRecipeID = nil }
                        suggestRecipe = recipe
                    }
                    recipeActionButton(
                        systemImage: isFavourite(recipeID: recipe.id) ? "star.fill" : "star",
                        label: isFavourite(recipeID: recipe.id) ? "Saved" : "Save",
                        tint: isFavourite(recipeID: recipe.id) ? .yellow : nil
                    ) {
                        toggleFavourite(recipeID: recipe.id)
                    }
                    recipeActionButton(
                        systemImage: "cart.badge.plus",
                        label: missingCount > 0 ? "Add \(missingCount)" : "In stock",
                        tint: .blue,
                        isDisabled: missingCount == 0
                    ) {
                        addMissingIngredientsToShoppingList(for: recipe)
                        withAnimation(.spring(response: 0.25)) { expandedRecipeID = nil }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .cookbookPage(cornerRadius: 22)

            // Comments live only here, in the list.
            RecipeCommentsDropdown(recipeID: recipe.id)
        }
    }

    private func recipePreviewWidth(availableSize: CGSize) -> CGFloat {
        min(availableSize.width - 44, 340)
    }

    private func recipePreviewHeight(availableSize: CGSize) -> CGFloat {
        min(availableSize.height * 0.62, 460)
    }

    private func recipePreviewSize(availableSize: CGSize) -> CGSize {
        CGSize(
            width: max(260, recipePreviewWidth(availableSize: availableSize)),
            height: max(320, recipePreviewHeight(availableSize: availableSize))
        )
    }

    private func recipePreviewCornerRadius(for size: CGSize) -> CGFloat {
        min(28, size.width * 0.08)
    }

    private func actionTraySpacing(for size: CGSize) -> CGFloat {
        size.width < 330 ? 8 : 10
    }

    private func actionButtonSize(for size: CGSize) -> CGFloat {
        size.width < 330 ? 42 : 46
    }

    private func actionTrayHorizontalPadding(for size: CGSize) -> CGFloat {
        size.width < 330 ? 10 : 12
    }

    private func actionOverlayHorizontalPadding(for size: CGSize, availableSize: CGSize) -> CGFloat {
        max(12, (availableSize.width - size.width) / 2)
    }

    private var actionTrayIconNames: [String] {
        ["eye", "square.and.arrow.up", "bubble.left.and.bubble.right", "star", "cart.badge.plus"]
    }

    private func actionTrayWidth(for size: CGSize) -> CGFloat {
        let buttonSize = actionButtonSize(for: size)
        let spacing = actionTraySpacing(for: size)
        let horizontalPadding = actionTrayHorizontalPadding(for: size) * 2
        return CGFloat(actionTrayIconNames.count) * buttonSize + CGFloat(actionTrayIconNames.count - 1) * spacing + horizontalPadding
    }

    private func recipePreviewScale(for size: CGSize) -> CGFloat {
        let trayWidth = actionTrayWidth(for: size)
        guard trayWidth > size.width else { return 1 }
        return size.width / trayWidth
    }

    private func recipePreviewScaledHeight(for size: CGSize) -> CGFloat {
        size.height * recipePreviewScale(for: size)
    }

    private func recipePreviewTrayOffset(for size: CGSize) -> CGFloat {
        max(10, recipePreviewScaledHeight(for: size) * 0.025)
    }

    private func recipePreviewOverlayBottomPadding(for size: CGSize) -> CGFloat {
        max(12, size.height * 0.032)
    }

    private func recipePreviewOverlayHorizontalPadding(for size: CGSize) -> CGFloat {
        max(12, size.width * 0.04)
    }

    private func recipePreviewOverlayCornerRadius(for size: CGSize) -> CGFloat {
        min(18, size.width * 0.055)
    }

    private func recipePreviewBadgeSpacing(for size: CGSize) -> CGFloat {
        size.width < 330 ? 6 : 8
    }

    private func recipePreviewTitleFont(for size: CGSize) -> Font {
        size.width < 330 ? .headline.weight(.semibold) : .title3.weight(.semibold)
    }

    private func recipePreviewBadgeFont(for size: CGSize) -> Font {
        size.width < 330 ? .caption2.weight(.semibold) : .caption.weight(.semibold)
    }

    private func recipePreviewBadgeHorizontalPadding(for size: CGSize) -> CGFloat {
        size.width < 330 ? 7 : 9
    }

    private func recipePreviewBadgeVerticalPadding(for size: CGSize) -> CGFloat {
        size.width < 330 ? 5 : 6
    }

    private func recipePreviewImageMaxScale(for imageSize: CGSize, targetSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        let widthScale = targetSize.width / imageSize.width
        let heightScale = targetSize.height / imageSize.height
        return max(widthScale, heightScale)
    }

    private func recipePreviewUIImage(_ uiImage: UIImage, targetSize: CGSize) -> some View {
        Image(uiImage: uiImage)
            .resizable()
            .scaledToFill()
            .scaleEffect(max(1, recipePreviewImageMaxScale(for: uiImage.size, targetSize: targetSize)))
            .frame(width: targetSize.width, height: targetSize.height)
            .clipped()
    }

    private func recipePreviewAsyncImage(_ image: Image, targetSize: CGSize) -> some View {
        image
            .resizable()
            .scaledToFill()
            .frame(width: targetSize.width, height: targetSize.height)
            .clipped()
    }

    private func recipePreviewPlaceholder(targetSize: CGSize, showsProgress: Bool = false) -> some View {
        return ZStack {
            Color.black.opacity(0.28)
            if showsProgress {
                ProgressView()
                    .tint(.white)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 52, weight: .regular))
                    .foregroundColor(.white.opacity(0.72))
            }
        }
        .frame(width: targetSize.width, height: targetSize.height)
    }

    private func dismissRecipeActionOverlay() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            expandedRecipeID = nil
        }
    }

    private func recipeItem(_ recipe: CloudRecipe, category: RecipeCategory, match precomputed: RecipeMatch?) -> some View {
        // ✅ FrydgeManager.recipeMatch is the single source of truth, shared with
        // RecipeDetailView and the item detail sheet. The list passes in the
        // value it already computed for sorting so each row doesn't redo it.
        let match = precomputed ?? frydgeManager.recipeMatch(for: recipe)
        let matchPercent = match.percent

        let barColor: Color = matchPercent >= 0.9 ? .green : matchPercent >= 0.5 ? .blue : .red

        // ✅ Total cook time from steps (same logic style as RecipeDetailView)
        let totalCookSeconds = totalCookTimeSeconds(for: recipe)
        let totalCookDisplay = totalCookSeconds > 0 ? formatCookTime(totalCookSeconds) : nil

        // ✅ Serves (string in CloudRecipe) -> display number with safe default
        let servesClean = recipe.serves.trimmingCharacters(in: .whitespacesAndNewlines)
        let servesDisplay = (Int(servesClean) ?? 1)
        let servesText = "\(max(1, servesDisplay))"

        return ZStack {
            recipeCardImage(recipe)

            VStack {
                // ✅ TOP ROW: title + total cook time (glass bubbles)
                HStack(spacing: 10) {
                    // Title bubble with glass effect, colour-coded to the
                    // recipe's chapter (chicken, beef, ...).
                    // Tidied name (see CloudRecipe.displayName); long names
                    // wrap to a second line instead of shrinking to a squint.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(category.emoji)
                            .font(.subheadline)
                        Text(recipe.displayName)
                            .font(.headline)
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.9)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(category.color.opacity(0.85), lineWidth: 1.2)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)

                    Spacer(minLength: 8)

                    if let totalCookDisplay {
                        HStack(spacing: 6) {
                            Image(systemName: "timer")
                                .font(.caption2)
                            Text(totalCookDisplay)
                                .font(.caption2)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Spacer()

                // ✅ BOTTOM ROW: All info in glass bubbles
                HStack(spacing: 8) {
                    // Serves bubble
                    HStack(spacing: 4) {
                        Text("👤")
                            .font(.caption)
                        Text(servesText)
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                    )

                    // Dietary badges
                    HStack(spacing: 6) {
                        if recipe.dietaryTags.contains("DF") { dietaryBadge("DF", recipe: recipe) }
                        if recipe.dietaryTags.contains("GF") { dietaryBadge("GF", recipe: recipe) }
                        if recipe.dietaryTags.contains("V")  { dietaryBadge("V",  recipe: recipe) }
                        if recipe.dietaryTags.contains("VG") { dietaryBadge("VG", recipe: recipe) }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                    Spacer()

                    // Allergen pill: red when the recipe hits a can't-eat
                    // rule (only visible when those are being shown), orange
                    // for a prefer-not rule.
                    if let verdict = allergenVerdicts[recipe.id], !verdict.isClean, let headline = verdict.headline {
                        HStack(spacing: 4) {
                            Image(systemName: verdict.isUnsafe ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .font(.caption2)
                            Text(headline)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background((verdict.isUnsafe ? Color.red : Color.orange).opacity(0.85), in: Capsule())
                        .accessibilityLabel(headline)
                    }

                    // Match percentage bubble. Below 100% the trolley is a
                    // solid blue button that lists the missing ingredients
                    // and offers to add them to the shopping list.
                    Button {
                        guard !match.isComplete else { return }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        missingSheetRecipe = recipe
                    } label: {
                        HStack(spacing: 6) {
                            ProgressView(value: matchPercent)
                                .frame(width: 40, height: 4)
                                .tint(barColor)

                            Text(match.percentText)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)

                            if !match.isComplete {
                                Image(systemName: "cart.badge.plus")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 24, height: 24)
                                    .background(Circle().fill(Color.blue))
                                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                            } else {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 20, height: 20)
                                    .background(Circle().fill(Color.green))
                            }
                        }
                        .padding(.leading, 10)
                        .padding(.trailing, match.isComplete ? 6 : 4)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(match.isComplete)
                    .accessibilityLabel(match.isComplete
                                        ? "All ingredients in your frydge"
                                        : "\(match.percentText) match, missing \(match.missing.count). Add missing ingredients to shopping list")
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 10)
            }
        }
        .aspectRatio(0.8, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(
            // Liquid Glass dark silver/grey background
            ZStack {
                // Base gradient layer
                LinearGradient(
                    colors: [
                        Color(white: 0.22, opacity: 0.75),
                        Color(white: 0.18, opacity: 0.8)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                
                // Light reflection layer
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.15),
                        Color.clear,
                        Color.white.opacity(0.05)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                
                // Glass blur material
                Rectangle()
                    .fill(.ultraThinMaterial.opacity(0.4))
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            // Subtle glass border with gradient
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.45),
                            Color.white.opacity(0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 6)
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
        .padding(.vertical, 10)
    }

    /// One glass action in the long-press tray: icon in a glass circle with
    /// a caption under it. `tint` fills the circle (blue = primary action,
    /// yellow = saved favourite); nil keeps it clear glass.
    private func recipeActionButton(
        systemImage: String,
        label: String,
        tint: Color? = nil,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard !isDisabled else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    // Ink on paper, white on a tinted (filled) circle.
                    .foregroundStyle(isDisabled
                                     ? CookbookTheme.ink.opacity(0.35)
                                     : (tint == nil ? CookbookTheme.ink : Color.white))
                    .frame(width: 48, height: 48)
                    .background {
                        let fill = (isDisabled ? nil : tint)?.opacity(0.9) ?? CookbookTheme.paper
                        Circle().fill(fill)
                    }
                    .overlay(
                        Circle().strokeBorder(CookbookTheme.rule, lineWidth: 1)
                    )
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isDisabled ? CookbookTheme.ink.opacity(0.35) : CookbookTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(label)
    }

    private func recipeContextPreview(_ recipe: CloudRecipe, size: CGSize) -> some View {
        let servesText = "\(max(1, Int(recipe.serves.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1))"
        let cookTime = totalCookTimeSeconds(for: recipe)

        return ZStack(alignment: .bottomLeading) {
            recipePreviewImage(recipe, targetSize: size)

            LinearGradient(
                colors: [.clear, .black.opacity(0.28), .black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 10) {
                Text(recipe.name)
                    .font(recipePreviewTitleFont(for: size))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                HStack(spacing: recipePreviewBadgeSpacing(for: size)) {
                    contextPreviewBadge(systemImage: "person", text: servesText, size: size)
                    if cookTime > 0 {
                        contextPreviewBadge(systemImage: "timer", text: formatCookTime(cookTime), size: size)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .recipeLiquidGlass(cornerRadius: recipePreviewOverlayCornerRadius(for: size))
            .padding(.horizontal, recipePreviewOverlayHorizontalPadding(for: size))
            .padding(.bottom, recipePreviewOverlayBottomPadding(for: size))
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: recipePreviewCornerRadius(for: size), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: recipePreviewCornerRadius(for: size), style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 10)
    }

    @ViewBuilder
    private func recipePreviewImage(_ recipe: CloudRecipe, targetSize: CGSize) -> some View {
        RecipePreviewImageView(recipe: recipe, targetSize: targetSize)
    }

    @ViewBuilder
    private func previewImagePhase(_ phase: AsyncImagePhase, recipe: CloudRecipe, targetSize: CGSize) -> some View {
        switch phase {
        case .empty:
            recipePreviewPlaceholder(targetSize: targetSize, showsProgress: true)
        case .success(let image):
            recipePreviewAsyncImage(image, targetSize: targetSize)
        case .failure:
            previewLocalOrPlaceholder(recipe, targetSize: targetSize)
        @unknown default:
            previewLocalOrPlaceholder(recipe, targetSize: targetSize)
        }
    }

    @ViewBuilder
    private func previewLocalOrPlaceholder(_ recipe: CloudRecipe, targetSize: CGSize) -> some View {
        if let image = cachedRecipeImage(for: recipe) {
            recipePreviewUIImage(image, targetSize: targetSize)
        } else {
            recipePreviewPlaceholder(targetSize: targetSize)
        }
    }

    private func contextPreviewBadge(systemImage: String, text: String, size: CGSize) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(recipePreviewBadgeFont(for: size))
        .foregroundStyle(.white)
        .padding(.horizontal, recipePreviewBadgeHorizontalPadding(for: size))
        .padding(.vertical, recipePreviewBadgeVerticalPadding(for: size))
        .background(.thinMaterial, in: Capsule(style: .continuous))
    }

    // MARK: - Recipe image (List card)

    @ViewBuilder
    private func recipeCardImage(_ recipe: CloudRecipe) -> some View {
        RecipeCardImageView(recipe: recipe)
    }

    @ViewBuilder
    private func fallbackRemoteOrLocalOrPlaceholder(_ recipe: CloudRecipe) -> some View {
        // Secondary: remote URL string if present.
        if let urlString = recipe.imageSourceURL,
           let url = URL(string: urlString) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ZStack {
                        Color.black.opacity(0.15)
                        ProgressView()
                    }
                    .aspectRatio(0.8, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .cornerRadius(8)

                case .success(let image):
                    fullBleedRecipeListImage(image)

                case .failure:
                    fallbackLocalOrPlaceholderImage(recipe)

                @unknown default:
                    fallbackLocalOrPlaceholderImage(recipe)
                }
            }
        } else {
            fallbackLocalOrPlaceholderImage(recipe)
        }
    }

    @ViewBuilder
    private func fallbackLocalOrPlaceholderImage(_ recipe: CloudRecipe) -> some View {
        // Fallback to local cached image (if you have one)
        if let image = cachedRecipeImage(for: recipe) {
            fullBleedRecipeListImage(Image(uiImage: image))
        } else {
            ZStack {
                Color.black.opacity(0.18)
                Image(systemName: "photo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .foregroundColor(.white.opacity(0.65))
            }
            .aspectRatio(0.8, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .cornerRadius(8)
        }
    }

    private func fullBleedRecipeListImage(_ image: Image) -> some View {
        GeometryReader { proxy in
            image
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .aspectRatio(0.8, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
        )
    }

    private func cachedRecipeImage(for recipe: CloudRecipe) -> UIImage? {
        for url in cachedRecipeImageURLs(for: recipe) {
            if let image = UIImage.frydgeBounded(contentsOf: url, maxPixelSize: ImageBudget.display) {
                return image
            }
        }
        return nil
    }

    private func cachedRecipeImageURLs(for recipe: CloudRecipe) -> [URL] {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return [
            documentsURL
                .appendingPathComponent("recipe-images", isDirectory: true)
                .appendingPathComponent("\(recipe.id).jpg"),
            documentsURL.appendingPathComponent("\(recipe.id).jpg")
        ]
    }

    // MARK: - Total cook time (from steps)

    private func totalCookTimeSeconds(for recipe: CloudRecipe) -> Int {
        guard !recipe.steps.isEmpty else { return 0 }
        return recipe.steps.reduce(0) { partial, step in
            partial + max(0, step.timerSeconds ?? 0)
        }
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

    // MARK: - Frydge matching (same idea as RecipeDetailView)

    private func norm(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Shared matcher (RecipeMatch.swift) — same answer as the recipe detail.
    private func isIngredientInKitchen(_ ingredient: String) -> Bool {
        frydgeManager.hasIngredient(ingredient)
    }

    // MARK: - Dietary helpers

    private enum DietaryColorState { case green, orange, gray }

    private func dietaryColor(for tag: String, recipe: CloudRecipe) -> DietaryColorState {
        var hasNameMatch = false
        var hasTaggedMatch = false

        for raw in recipe.ingredients {
            if let item = frydgeManager.matchedFridgeItem(for: raw) {
                hasNameMatch = true
                if item.dietaryTags.contains(tag) {
                    hasTaggedMatch = true
                }
            }
        }

        if !hasNameMatch { return .gray }
        return hasTaggedMatch ? .green : .orange
    }

    private func dietaryBadge(_ tag: String, recipe: CloudRecipe) -> some View {
        let state = dietaryColor(for: tag, recipe: recipe)
        let tone: DietaryBadgeChip.Tone
        switch state {
        case .green:  tone = .green
        case .orange: tone = .orange
        case .gray:   tone = .gray
        }
        return DietaryBadgeChip(tag: tag, tone: tone)
    }

    // MARK: - Shopping helpers (List)

    private func addMissingIngredientsToShoppingList(for recipe: CloudRecipe) {
        let tagsToApply = normalizedDietaryTagsForShopping(recipeLevelTags: recipe.dietaryTags)
        // Same missing set the match badge shows; the manager skips lines already listed.
        let missing = frydgeManager.recipeMatch(for: recipe).missing
        let added = shoppingListManager.addMissingIngredients(missing, dietaryTags: tagsToApply)
        if added > 0 {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func normalizedDietaryTagsForShopping(recipeLevelTags: [String]) -> Set<String> {
        let wanted: Set<String> = ["DF", "GF", "V", "VG", "DAIRY FREE", "GLUTEN FREE", "VEGETARIAN", "VEGAN"]

        let normalized = recipeLevelTags
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

    private struct ParsedIngredientList {
        let name: String
        let quantity: Double?
        let unit: String?
    }

    private func parseIngredient(_ raw: String) -> ParsedIngredientList {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return ParsedIngredientList(name: "", quantity: nil, unit: nil) }

        let pattern = #"^(.+?)\s+(\d+(?:[.,]\d+)?|\d+/\d+)\s*(kg|g|l|ml|pcs|pc|tbsp|tsp|cup|cups|oz|lb)?\s*$"#

        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let range = NSRange(cleaned.startIndex..., in: cleaned)

            guard let match = regex.firstMatch(in: cleaned, options: [], range: range) else {
                return ParsedIngredientList(name: cleaned, quantity: nil, unit: nil)
            }

            guard
                let nameRange = Range(match.range(at: 1), in: cleaned),
                let qtyRange = Range(match.range(at: 2), in: cleaned)
            else {
                return ParsedIngredientList(name: cleaned, quantity: nil, unit: nil)
            }

            let name = String(cleaned[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let qtyString = String(cleaned[qtyRange])

            let qty = parseNumberOrFraction(qtyString)

            var unit: String? = nil
            if match.numberOfRanges > 3, match.range(at: 3).location != NSNotFound,
               let unitRange = Range(match.range(at: 3), in: cleaned) {
                unit = String(cleaned[unitRange]).lowercased()
            }

            return ParsedIngredientList(name: name.isEmpty ? cleaned : name, quantity: qty, unit: unit)
        } catch {
            return ParsedIngredientList(name: cleaned, quantity: nil, unit: nil)
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

    private func formatQuantity(_ q: Double) -> String {
        if q.rounded(.towardZero) == q { return String(Int(q)) }
        return String(format: "%.2f", q).replacingOccurrences(of: ".00", with: "")
    }

    // MARK: - Navigation / lifecycle

    private func initializeView() {
        requestNotificationPermission()
        Task {
            // Use cached data first; only hit CloudKit when cache is empty or stale (>15 min)
            async let recipes: Void = recipeListModel.fetchIfStale()
            async let sharedTargets: Void = refreshSharedSuggestionTargets()
            _ = await (recipes, sharedTargets)
            await MainActor.run {
                navigateToPendingRecipeIfNeeded()
            }
        }
    }

    private func refreshSharedSuggestionTargets() async {
        await sharedShoppingListManager.refreshSharedLists()
    }

    private func navigateToPendingRecipeIfNeeded() {
        guard let pendingID = appState.lastViewedRecipeID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pendingID.isEmpty else {
            return
        }

        if selectedRecipe?.id == pendingID {
            return
        }

        if let recipe = recipeListModel.recipes.first(where: { $0.id == pendingID }) {
            selectedRecipe = recipe
            lastViewedRecipeID = pendingID
            print("[RECIPE] Opened shared recipe id=\(pendingID)")
            return
        }

        // Not in the local list (stale cache, or a recipe the sender never
        // synced to CloudKit): fetch it by id from CloudKit, then fall back
        // to the full payload published with the share link.
        guard !isResolvingSharedRecipe else { return }
        isResolvingSharedRecipe = true
        print("[RECIPE] Shared recipe id=\(pendingID) not loaded yet — resolving")
        Task { @MainActor in
            defer { isResolvingSharedRecipe = false }
            if let recipe = await recipeListModel.resolveRecipe(id: pendingID) {
                selectedRecipe = recipe
                lastViewedRecipeID = pendingID
                print("[RECIPE] Opened resolved shared recipe id=\(pendingID)")
            } else {
                appState.lastViewedRecipeID = nil
                appState.showBanner(
                    title: "Recipe not found",
                    message: "That shared recipe isn't available right now.",
                    systemImage: "exclamationmark.triangle",
                    style: .warning
                )
            }
        }
    }

    private func handleRecipeSelection(_ recipe: CloudRecipe) {
        print("[DEBUG] Selected recipe: \(recipe.name), ID: \(recipe.id)")
        self.selectedRecipe = recipe
        self.lastViewedRecipeID = recipe.id
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error = error {
                print("[ERROR] Notification permission request failed: \(error.localizedDescription)")
            } else if granted {
                print("[INFO] Notification permission granted")
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            } else {
                print("[INFO] Notification permission denied")
            }
        }
    }

    // MARK: - Utils

    private func timeAgoSince(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct RecipeSuggestionSheet: View {
    let recipe: CloudRecipe
    @ObservedObject var sharedManager: SharedShoppingListManager
    let onSuggested: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedAnchorID: CKRecord.ID?
    @State private var isSending = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if sharedManager.isLoading && sharedManager.sharedAnchors.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading shared shopping lists...")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else if sharedManager.sharedAnchors.isEmpty {
                        Text("Share a shopping list first, then suggestions can be sent here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sharedManager.sharedAnchors, id: \.recordID) { anchor in
                            Button {
                                selectedAnchorID = anchor.recordID
                            } label: {
                                HStack(spacing: 12) {
                                    Text(listEmoji(for: anchor))
                                        .font(.title3)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(listName(for: anchor))
                                            .foregroundStyle(.primary)
                                        Text("\(sharedManager.itemsDetailed(for: anchor).count) items")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if selectedAnchorID == anchor.recordID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Suggest to")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Suggest Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await sendSuggestion() }
                    } label: {
                        if isSending {
                            ProgressView()
                        } else {
                            Image(systemName: "paperplane.fill")
                        }
                    }
                    .disabled(isSending || selectedAnchor == nil)
                    .accessibilityLabel("Send suggestion")
                }
            }
            .task {
                await sharedManager.refreshSharedLists()
                if selectedAnchorID == nil {
                    selectedAnchorID = sharedManager.sharedAnchors.first?.recordID
                }
            }
        }
    }

    private var selectedAnchor: CKRecord? {
        sharedManager.sharedAnchors.first { $0.recordID == selectedAnchorID }
    }

    private func sendSuggestion() async {
        guard let anchor = selectedAnchor else {
            errorMessage = "Share a shopping list first, then suggestions can be sent."
            return
        }
        isSending = true
        errorMessage = nil
        defer { isSending = false }

        let payload = RecipeSuggestionPayload(
            recipeID: recipe.id,
            recipeName: recipe.name,
            ingredients: recipe.ingredients,
            dietaryTags: recipe.dietaryTags,
            suggestedAt: Date()
        )

        guard let encodedTag = payload.encodedTag else {
            errorMessage = "This recipe could not be prepared for sharing."
            return
        }

        var items = sharedManager.itemsDetailed(for: anchor)
        let alreadySuggested = items.contains { item in
            item.recipeSuggestionPayload?.recipeID == recipe.id
        }

        if !alreadySuggested {
            items.insert(
                SharedShoppingListItem(
                    name: "Cook \(recipe.name)?",
                    quantity: "",
                    unit: "",
                    location: "Suggestion",
                    dietaryTags: [encodedTag]
                ),
                at: 0
            )
            await sharedManager.setItemsDetailed(items, for: anchor)
        }

        onSuggested(listName(for: anchor))
        dismiss()
    }

    private func listName(for anchor: CKRecord) -> String {
        let rawName = (anchor["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawName, !rawName.isEmpty { return rawName }
        if let cached = sharedManager.displayNameByAnchorID[anchor.recordID], !cached.isEmpty { return cached }
        return "Frydge Shopping List"
    }

    private func listEmoji(for anchor: CKRecord) -> String {
        let rawEmoji = (anchor["emoji"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawEmoji, !rawEmoji.isEmpty { return String(rawEmoji.prefix(1)) }
        if let cached = sharedManager.emojiByAnchorID[anchor.recordID], !cached.isEmpty { return String(cached.prefix(1)) }
        return "🛒"
    }
}

// MARK: - Cached image views (use RecipeImageLoader for memory + disk persistence)

private struct RecipeCardImageView: View {
    let recipe: CloudRecipe
    var imageAspectRatio: CGFloat = 0.8
    @StateObject private var loader = RecipeImageLoader()

    var body: some View {
        Group {
            if let img = loader.image {
                GeometryReader { proxy in
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
                .aspectRatio(imageAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                )
            } else {
                // No photo (yet): chapter-coloured artwork with the dish's
                // emoji, so every card has an image. A spinner sits on top
                // while a photo is still being looked up.
                RecipePlaceholderArtwork(recipeName: recipe.name, category: RecipeCategory.classify(recipe))
                    .overlay {
                        if loader.isLoading {
                            ProgressView().tint(.white.opacity(0.9))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                                .padding(14)
                        }
                    }
                    .aspectRatio(imageAspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                    )
            }
        }
        .onAppear { loader.load(recipe: recipe) }
        .onDisappear { loader.cancel() }
        .onChange(of: recipe) { _, newRecipe in loader.load(recipe: newRecipe) }
    }
}

private struct RecipePreviewImageView: View {
    let recipe: CloudRecipe
    let targetSize: CGSize
    @StateObject private var loader = RecipeImageLoader()

    var body: some View {
        Group {
            if let img = loader.image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(max(1, scale(for: img)))
                    .frame(width: targetSize.width, height: targetSize.height)
                    .clipped()
            } else {
                RecipePlaceholderArtwork(recipeName: recipe.name, category: RecipeCategory.classify(recipe))
                    .overlay {
                        if loader.isLoading { ProgressView().tint(.white) }
                    }
                    .frame(width: targetSize.width, height: targetSize.height)
            }
        }
        .onAppear { loader.load(recipe: recipe) }
        .onDisappear { loader.cancel() }
        .onChange(of: recipe) { _, newRecipe in loader.load(recipe: newRecipe) }
    }

    private func scale(for img: UIImage) -> CGFloat {
        guard img.size.width > 0, img.size.height > 0 else { return 1 }
        return max(targetSize.width / img.size.width, targetSize.height / img.size.height)
    }
}

private extension View {
    func recipeLiquidGlass(cornerRadius: CGFloat) -> some View {
        // Deployment target is iOS 27, so Liquid Glass is always available.
        self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
    }
}

private struct TabletRecipeCard: View {
    @State private var showsComments = false
    let recipe: CloudRecipe
    let time: String?
    let matchPercent: Double
    let missingCount: Int
    let isFavourite: Bool
    let open: () -> Void
    let toggleFavourite: () -> Void
    let addMissing: () -> Void
    let suggest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 12) {
                    RecipeCardImageView(recipe: recipe, imageAspectRatio: 1.5)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(recipe.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2, reservesSpace: true)
                            .multilineTextAlignment(.leading)
                        HStack {
                            Label(recipe.serves.isEmpty ? "1" : recipe.serves, systemImage: "person.2")
                            Spacer()
                            if let time { Label(time, systemImage: "clock") }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        ProgressView(value: matchPercent)
                            .tint(matchPercent >= 0.9 ? .green : .accentColor)
                        Text("\(Int(matchPercent * 100))% in your fridge")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            Divider()
            HStack(spacing: 12) {
                Button(action: toggleFavourite) {
                    Image(systemName: isFavourite ? "star.fill" : "star")
                }
                .accessibilityLabel(isFavourite ? "Remove favourite" : "Save favourite")
                .help(isFavourite ? "Remove favourite" : "Save favourite")
                ShareLink(item: RecipeShareText.fullText(for: recipe), subject: Text(recipe.displayName)) {
                    Label("Share recipe", systemImage: "square.and.arrow.up")
                }
                .labelStyle(.iconOnly)
                .help("Share recipe")
                Button("Comments", systemImage: "bubble.left") { showsComments = true }
                    .labelStyle(.iconOnly)
                    .help("Recipe comments")
                    .popover(isPresented: $showsComments) {
                        RecipeCommentsDropdown(recipeID: recipe.id)
                            .padding()
                            .frame(minWidth: 300, idealWidth: 360)
                    }
                Spacer(minLength: 0)
                Button(action: addMissing) {
                    Label(missingCount > 0 ? "Add \(missingCount)" : "In stock", systemImage: "cart.badge.plus")
                        .font(.subheadline.weight(.medium))
                }
                .disabled(missingCount == 0)
                .help("Add missing ingredients to your shopping list")
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 48)
            .padding(.horizontal, 16)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.06))
        }
        .contextMenu {
            Button("Open recipe", systemImage: "book", action: open)
            Button(isFavourite ? "Remove favourite" : "Save favourite", systemImage: "star", action: toggleFavourite)
            Button("Suggest to a shared list", systemImage: "bubble.left.and.bubble.right", action: suggest)
            Button("Add missing ingredients", systemImage: "cart.badge.plus", action: addMissing)
                .disabled(missingCount == 0)
        }
    }
}
