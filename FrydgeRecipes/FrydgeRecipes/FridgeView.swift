import SwiftUI
import CloudKit
import UIKit

/// Keep personal and household inventory visible together when the window has room.
/// AnyLayout preserves row and disclosure state when multitasking changes the width.
struct AdaptiveInventoryColumns<Personal: View, Shared: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var hasColumnWidth = false

    let paperStyle: Bool
    let personal: Personal
    let shared: Shared

    init(
        paperStyle: Bool = false,
        @ViewBuilder personal: () -> Personal,
        @ViewBuilder shared: () -> Shared
    ) {
        self.paperStyle = paperStyle
        self.personal = personal()
        self.shared = shared()
    }

    var body: some View {
        let usesColumns = hasColumnWidth && !dynamicTypeSize.isAccessibilitySize
        let usesPanels = usesColumns || horizontalSizeClass == .regular
        let layout = usesColumns
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: usesPanels ? 20 : 6))

        layout {
            InventoryColumnPanel(isPresented: usesPanels, paperStyle: paperStyle) {
                personal
            }
            InventoryColumnPanel(isPresented: usesPanels, paperStyle: paperStyle) {
                shared
            }
        }
        .padding(.horizontal, usesPanels ? 16 : 0)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: Bool.self) { geometry in
            geometry.size.width >= 760
        } action: { hasColumnWidth = $0 }
    }
}

private struct InventoryColumnPanel<Content: View>: View {
    let isPresented: Bool
    let paperStyle: Bool
    @ViewBuilder let content: Content

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            content
        }
        .padding(.vertical, isPresented ? 12 : 0)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            if isPresented {
                if paperStyle {
                    NotepadPaper()
                } else {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color(.secondarySystemGroupedBackground))
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: isPresented ? 18 : 0)
                .strokeBorder(.primary.opacity(isPresented ? 0.08 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

struct FrydgeView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject var frydgeManager: FrydgeManager
    @EnvironmentObject var sharedFridgeManager: SharedFridgeManager
    @EnvironmentObject var invites: PendingInvites
    @EnvironmentObject var shoppingListManager: ShoppingListManager
    @EnvironmentObject var appState: AppState

    @State private var isShowingProductDetails = false
    @State private var productDetails: ProductProtocol?
    @Environment(\.colorScheme) var colorScheme
    @State private var imageSyncToken: Int = 0
    @State private var recentlyUsedUpIDs: Set<UUID> = []
    @State private var infoSheetItem: StoredIngredient? = nil
    @State private var detailSheetItem: StoredIngredient? = nil

    // MARK: - Move selection state
    @State private var isSelectingToMove: Bool = false
    @State private var selectedMoveIDs: Set<UUID> = []
    /// Shared frydge chosen in the "Move to Shared" picker; non-nil presents the item picker.
    @State private var moveDestination: CKRecord? = nil

    // MARK: - Drag & drop (Mine ⇄ Shared)
    @State private var isDropTargetingMine: Bool = false

    // MARK: - Sync UX / Optional behavior
    @State private var isSyncingNow: Bool = false


    /// Optional: only do the Cloud pull once per app run (prevents repeated “pull” storms)
    private let initialSyncOncePerRun: Bool = true
    @State private var didInitialSyncThisRun: Bool = false

    /// Combine any pre-existing duplicate items once per app run.
    @State private var didConsolidateThisRun: Bool = false

    /// Optional: keep local file loads, but don’t push everything back to Cloud automatically
    /// (This is the key change to stop “sync by accident” behavior.)
    private let autoPushAllOnAppear: Bool = false
    
    // MARK: - Freshness slider state
    @State private var freshnessPercentages: [UUID: Double] = [:]

    /// The in-store basket, opened directly from the header (no tab switch).
    @State private var showBasketSheet = false

    /// Destination for the top "+" add action: nil = Mine, otherwise a shared frydge anchor.
    @State private var addAnchor: CKRecord? = nil

    @State private var showProfileSheet = false

    // MARK: - Weekly planner
    @State private var showWeeklyPlanner = false
    /// Observed so the quick-action button can show how many meals are planned.
    @ObservedObject private var weekPlanStore = WeekPlanStore.shared
    private var plannedMealCount: Int { weekPlanStore.plannedRecipes.count }

    // MARK: - Snacking
    @State private var showSnackPicker = false

    // MARK: - Leftovers
    @ObservedObject private var leftoverManager = LeftoverManager.shared
    @State private var showLeftoverSheet = false
    @State private var pendingLeftoverRecipeName: String = ""

    // MARK: - Use it up (recipes you already have, ranked by what's expiring)
    @StateObject private var recipeModel = RecipeListModel()
    /// Every recipe that qualifies for the strip, best first. The strip shows
    /// one page of these at a time; the refresh button advances to the next.
    @State private var useItUpCandidates: [FridgeRecipePick] = []
    @State private var useItUpPage: Int = 0
    /// Background scoring pass; superseded (cancelled) by the next fridge change.
    @State private var useItUpTask: Task<Void, Never>?
    @State private var selectedSuggestion: CloudRecipe? = nil
    private static let useItUpPageSize = 8

    /// The page of candidates currently on screen, wrapping around so the
    /// last page is always full when there's enough to fill it.
    private var useItUpRecipes: [FridgeRecipePick] {
        let count = useItUpCandidates.count
        guard count > 0 else { return [] }
        let size = Self.useItUpPageSize
        guard count > size else { return useItUpCandidates }
        let start = (useItUpPage * size) % count
        return (0..<size).map { useItUpCandidates[(start + $0) % count] }
    }

    /// Only worth offering a refresh when there's something different to show.
    private var canRefreshUseItUp: Bool { useItUpCandidates.count > 1 }

    // MARK: - Sorting
    // Food type by default — meat and fish at the top, then grains, veg,
    // dairy… — so a glance at the frydge suggests what to cook. Persisted so
    // a different choice survives relaunches. (Key bumped so installs that
    // stored the old default pick up the new one once.)
    @AppStorage("frydge.fridgeSort.v2") private var fridgeSort: FridgeSort = .foodType

    enum FridgeSort: String, CaseIterable {
        case expiry
        case recipe
        case recentlyAdded
        case foodType
        case alphabetical

        var label: String {
            switch self {
            case .expiry: return "Expiry date"
            case .recipe: return "Recipe match"
            case .recentlyAdded: return "Recently added"
            case .foodType: return "Food type"
            case .alphabetical: return "A–Z"
            }
        }
        var icon: String {
            switch self {
            case .expiry: return "calendar"
            case .recipe: return "fork.knife"
            case .recentlyAdded: return "clock"
            case .foodType: return "square.grid.2x2"
            case .alphabetical: return "textformat"
            }
        }
    }

    var body: some View {
        VStack {
            if horizontalSizeClass != .regular {
                headerBar
                    .browsingHeader()
            }

            itemsList
        }
        .background { CookbookBackground().ignoresSafeArea() }
        .navigationTitle(horizontalSizeClass == .regular ? "Fridge" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { inventoryToolbar }
        .sheet(isPresented: $showWeeklyPlanner) {
            WeeklyPlannerView()
                .environmentObject(frydgeManager)
                .environmentObject(shoppingListManager)
        }
        .sheet(isPresented: $showSnackPicker) {
            SnackPickerSheet(items: snackableItems())
                .environmentObject(frydgeManager)
                .environmentObject(shoppingListManager)
        }
        .onAppear {
            // FrydgeManager loads the store in its init and observes remote
            // changes itself. Re-reading it here re-published the whole list
            // (and re-ran every subscriber) each time this tab appeared.
            if !didConsolidateThisRun {
                didConsolidateThisRun = true
                frydgeManager.consolidateDuplicates()
            }
            recentlyUsedUpIDs = Set(loadUsedUpItems().keys.compactMap { UUID(uuidString: $0) })

            recomputeSuggestions()
            Task {
                await recipeModel.fetchIfStale(maxAge: 30 * 60)
                recomputeSuggestions()
            }

            DefrostReminderPlanner.refresh()

            Task {
                // Optional: only sync once per run
                if initialSyncOncePerRun && didInitialSyncThisRun { return }
                didInitialSyncThisRun = true
                await refreshFromCloud(reason: "onAppear")
            }
        }
        .onChange(of: frydgeManager.storedIngredients.count) { _, _ in
            recomputeSuggestions()
            DefrostReminderPlanner.refresh()
        }
        // itemsByFridge isn't Equatable, so watch its total item count instead —
        // shared frydges load async and suggestions should pick up what lands there.
        .onChange(of: sharedFridgeManager.itemsByFridge.values.reduce(0) { $0 + $1.count }) { _, _ in
            recomputeSuggestions()
        }
        .toolbar(horizontalSizeClass == .regular ? .visible : .hidden, for: .navigationBar)
        .onReceive(NotificationCenter.default.publisher(for: .showLeftoverSheet)) { notification in
            let name = notification.userInfo?[LeftoverNotification.recipeNameKey] as? String ?? ""
            pendingLeftoverRecipeName = name
            showLeftoverSheet = true
        }
        // Cook loop finished elsewhere → dismiss any open item sheet so the
        // user lands back on the freshly-updated fridge.
        .onChange(of: appState.dismissFridgeSheetsToken) { _, _ in
            detailSheetItem = nil
            infoSheetItem = nil
        }
        // Force image re-sync triggered from Profile: clear cache and re-fetch
        .onReceive(NotificationCenter.default.publisher(for: .frydgeForceImageSync)) { _ in
            ProductImageCacheManager.shared.clearAll()
            imageSyncToken += 1
        }
        // ✅ Listen for shared frydge changes (CloudKit push notifications)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SharedFrydgeChanged"))) { _ in
            print("[FridgeView] Received SharedFrydgeChanged notification")
            Task {
                await sharedFridgeManager.refreshSharedFrydges()
            }
        }
        // ✅ Listen for CloudKit query notifications (general refresh)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("CloudKitQueryNotificationReceived"))) { notification in
            print("[FridgeView] Received CloudKitQueryNotificationReceived")
            if let userInfo = notification.userInfo,
               let ckNotif = CKNotification(fromRemoteNotificationDictionary: userInfo),
               let queryNotif = ckNotif as? CKQueryNotification,
               let subscriptionID = queryNotif.subscriptionID,
               subscriptionID.contains("SharedFrydge_") {
                print("[FridgeView] Confirmed frydge notification")
                Task {
                    await sharedFridgeManager.refreshSharedFrydges()
                }
            }
        }
    }

    // MARK: - Header
    // Title + [basket, add, profile]. Unlike ShoppingListView there is no
    // separate scan button: receipt and list scanning are secondary actions
    // inside the add sheet.
    @ToolbarContentBuilder
    private var inventoryToolbar: some ToolbarContent {
        if horizontalSizeClass == .regular {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Basket", systemImage: "basket") { showBasketSheet = true }
                addItemControl
                    .keyboardShortcut("n", modifiers: .command)
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Weekly Plan", systemImage: "calendar") { showWeeklyPlanner = true }
                    Button("Snack", systemImage: "fork.knife") { showSnackPicker = true }
                    Button("Profile", systemImage: "person.crop.circle") { showProfileSheet = true }
                }
            }
        }
    }

    @ViewBuilder
    private var addControlLabel: some View {
        if horizontalSizeClass == .regular {
            Label("Add Item", systemImage: "plus")
        } else {
            AddEmojiLabel()
        }
    }

    private var headerBar: some View {
        HStack(spacing: 16) {
            Text("Frydge")
                .font(CookbookTheme.runningHeadFont)
                .fontDesign(.default)
                .tracking(3)
                .foregroundStyle(CookbookTheme.inkSecondary)

            Spacer()

            // Opens the basket itself. The Shopping List screen is only reached
            // through its own tab, never via this button.
            Button {
                showBasketSheet = true
            } label: {
                Image(systemName: "basket.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
            }
            .accessibilityLabel("Open basket")

            // One add button: type, search or scan a barcode, item after item.
            // Receipt scanning and list scanning live inside that sheet as
            // secondary actions, so there's no separate camera button.
            addItemControl

            Button {
                showProfileSheet = true
            } label: {
                Image(systemName: "person.crop.circle")
                    .font(.title)
                    .foregroundColor(.blue)
            }
            .accessibilityLabel("Profile")
        }
        .padding(.horizontal)
        .padding(.top, 10)
    }

    /// The top "+" control. A tap always opens the item search sheet (adding to
    /// Mine), exactly like the shopping list's add button. When the user owns
    /// shared frydges, a long-press additionally offers those as destinations.
    private var addItemControl: some View {
        // Owned and incoming: participants with write access can add too.
        let owned = sharedFridgeManager.sharedFrydgeAnchors
        return Group {
            if owned.isEmpty {
                Button {
                    openAddSearch()
                } label: {
                    addControlLabel
                }
                .accessibilityLabel("Add item")
            } else {
                Menu {
                    Button {
                        openAddSearch()
                    } label: {
                        Label("Add to Mine", systemImage: "house")
                    }
                    Section("Shared frydges") {
                        ForEach(owned, id: \.recordID) { anchor in
                            let name = sharedFridgeManager.namesByFridge[anchor.recordID]
                                ?? (anchor["name"] as? String ?? "Shared Frydge")
                            let emoji = sharedFridgeManager.emojisByFridge[anchor.recordID]
                                ?? (anchor["emoji"] as? String ?? "🧊")
                            Button {
                                addAnchor = anchor
                                productDetails = nil
                                isShowingProductDetails = true
                            } label: {
                                Text("\(emoji) \(name)")
                            }
                        }
                    }
                } label: {
                    addControlLabel
                } primaryAction: {
                    // Tap goes straight to search; long-press reveals the menu.
                    openAddSearch()
                }
                .accessibilityLabel("Add item")
            }
        }
    }

    /// Opens the blank item search sheet for adding to Mine — the same flow the
    /// shopping list's add button uses.
    private func openAddSearch() {
        addAnchor = nil
        productDetails = nil
        isShowingProductDetails = true
    }

    /// Rotating food emoji with a plus badge — the same "add" affordance as
    /// the shopping list's add button. Owns its own rotation timer so the
    /// 2.5s tick only invalidates this tiny view, not the whole fridge screen.
    private struct AddEmojiLabel: View {
        @State private var addEmojiIndex = 0

        var body: some View {
            ZStack(alignment: .bottomTrailing) {
                Text(FoodEmoji.showcase[addEmojiIndex % FoodEmoji.showcase.count])
                    .font(.system(size: 27))
                    .id(addEmojiIndex)
                    .transition(.scale.combined(with: .opacity))
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .blue)
                    .offset(x: 4, y: 4)
            }
            .frame(width: 34, height: 32)
            .task {
                // Rotate the emoji while the view is on screen; cancelled
                // automatically when it leaves.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2.5))
                    withAnimation(.easeInOut(duration: 0.25)) {
                        addEmojiIndex = (addEmojiIndex + 1) % FoodEmoji.showcase.count
                    }
                }
            }
        }
    }

    // MARK: - Cloud refresh (Pull-only by default)
    @MainActor
    private func refreshFromCloud(reason: String) async {
        guard !isSyncingNow else { return }
        isSyncingNow = true
        defer { isSyncingNow = false }

        // ✅ Pull from Cloud.
        // FrydgeManager.syncFromCloud() already does a best-effort tombstone flush first.
        await frydgeManager.syncFromCloud()

        // 🚫 IMPORTANT:
        // Do NOT automatically push *all* items back to Cloud on appear.
        // That pattern causes accidental resurrection / cross-sync weirdness.
        if autoPushAllOnAppear {
            await frydgeManager.syncStoredIngredientsToCloud()
        }

        print("[FrydgeView] Cloud refresh (\(reason)) complete. items=\(frydgeManager.storedIngredients.count)")
    }


    // MARK: - Mine: List
    private var itemsList: some View {
        // ScrollView + LazyVStack (not List): SwiftUI's .dropDestination never fires
        // reliably inside a List, so drag-and-drop between fridges needs a plain
        // scrolling surface. Swipe-to-delete comes from `.swipeActionsContainer()`
        // on this scroll view plus `.swipeActions` on each Mine row, which is the
        // supported way to get row swipes outside a List.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                leftoversSection
                UseItUpSection(
                    recipes: useItUpRecipes,
                    canRefresh: canRefreshUseItUp,
                    onRefresh: refreshUseItUp,
                    onSelect: { selectedSuggestion = $0 }
                )
                if horizontalSizeClass != .regular {
                    quickActionsRow
                }
                AdaptiveInventoryColumns {
                    MineSection(
                        storedIngredients: frydgeManager.storedIngredients,
                        recipes: recipeModel.recipes,
                        fridgeSort: $fridgeSort,
                        isDropTargetingMine: $isDropTargetingMine,
                        imageSyncToken: imageSyncToken,
                        recentlyUsedUpIDs: recentlyUsedUpIDs,
                        isSelectingToMove: isSelectingToMove,
                        onOpenAddSearch: openAddSearch,
                        onTapDetail: { detailSheetItem = $0 },
                        onUsageChange: { updateItemUsage($0, newUsage: $1) },
                        onMarkUsedUp: { markItemAsUsedUp($0) },
                        onAddToList: { addToShoppingList($0) },
                        onDelete: { deleteItem($0) },
                        onDropToMine: { handleDropToMine($0) }
                    )
                } shared: {
                    sharedFridgeSection
                }
                Color.clear.frame(height: horizontalSizeClass == .regular ? 24 : 100)
            }
            .padding(.vertical, 3)
        }
        // One row's swipe actions open at a time; scrolling or tapping elsewhere closes them.
        .swipeActionsContainer()
        .browsingScrollNavigation()
        // Keep the page moving while an item is dragged towards a shared
        // frydge that's scrolled off-screen.
        .dragAutoScroll(for: DraggableFridgeItem.self, bottomInset: 90)
        .scrollContentBackground(.hidden)
        .refreshable {
            print("[FrydgeView] 🔄 Pull-to-refresh triggered")
            await performFullRefresh()
        }
        // Sheets attached to List so they survive rows scrolling offscreen.
        .sheet(isPresented: $isShowingProductDetails) {
            if let anchor = addAnchor {
                // Add straight into a shared frydge. Frydges shared with us live in
                // the shared DB, so pick the database from the anchor's zone owner.
                let addScope = sharedFridgeManager.scope(for: anchor)
                ProductDetailsView(
                    isShowing: $isShowingProductDetails,
                    productDetails: nil,
                    context: .sharedFridge(
                        anchor: anchor,
                        db: addScope == .owned
                            ? sharedFridgeManager.container.privateCloudDatabase
                            : sharedFridgeManager.container.sharedCloudDatabase
                    )
                )
                .environmentObject(frydgeManager)
                .onDisappear {
                    Task { await sharedFridgeManager.loadItems(for: anchor, scope: addScope) }
                }
            } else {
                ProductDetailsView(
                    isShowing: $isShowingProductDetails,
                    productDetails: productDetails ?? OFFProduct(
                        code: nil,
                        productName: "Unknown",
                        ingredientsText: "Details not available",
                        quantity: "0",
                        imageUrl: nil,
                        nutriments: nil
                    ),
                    context: .fridge
                )
                .environmentObject(frydgeManager)
            }
        }
        .sheet(item: $infoSheetItem) { sheetItem in
            FoodInfoView(ingredient: sheetItem.name)
        }
        // "Move items to a shared frydge": the destination picker posts the chosen
        // anchor; look it up and let the user choose which of their items to move.
        .onReceive(NotificationCenter.default.publisher(for: .didPickMoveToSharedFrydgeDestination)) { note in
            guard let name = note.userInfo?["anchorRecordName"] as? String,
                  let anchor = sharedFridgeManager.sharedFrydgeAnchors
                      .first(where: { $0.recordID.recordName == name }) else { return }
            selectedMoveIDs.removeAll()
            moveDestination = anchor
        }
        .sheet(isPresented: Binding(
            get: { moveDestination != nil },
            set: { if !$0 { moveDestination = nil } }
        )) {
            if let anchor = moveDestination {
                MoveItemsPickerSheet(
                    destinationName: displayName(for: anchor),
                    items: frydgeManager.storedIngredients.filter { $0.lifecycle == .fridge },
                    selected: $selectedMoveIDs,
                    onMove: {
                        moveDestination = nil
                        Task { await moveSelectedItems(to: anchor) }
                    }
                )
            }
        }
        .sheet(item: $detailSheetItem) { sheetItem in
            IngredientDetailSheet(
                ingredient: sheetItem,
                onUsageChanged: { newUsage in
                    updateItemUsage(sheetItem, newUsage: newUsage)
                }
            )
            .environmentObject(frydgeManager)
        }
        .sheet(isPresented: $showBasketSheet) {
            StandaloneBasketSheet()
                .environmentObject(frydgeManager)
                .environmentObject(shoppingListManager)
                .environmentObject(sharedFridgeManager)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showProfileSheet) {
            ProfileView()
        }
        .sheet(isPresented: $showLeftoverSheet) {
            LeftoverReminderSheet(recipeName: pendingLeftoverRecipeName)
        }
        .sheet(item: $selectedSuggestion) { recipe in
            NavigationStack {
                RecipeDetailView(recipeListModel: recipeModel, recipe: recipe)
                    .environmentObject(frydgeManager)
                    .environmentObject(shoppingListManager)
            }
        }
    }

    // MARK: - Quick actions

    // One row, two buttons (mirrors ShoppingListView): the calendar opens the
    // weekly planner; Snack opens a searchable picker over what's already in
    // the fridge. Recipe suggestions live in the "Use it up" strip above —
    // the old Suggestions toggle showed the same recipes twice.
    private var quickActionsRow: some View {
        HStack(spacing: 8) {
            Button {
                showWeeklyPlanner = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .foregroundStyle(.blue)
                    Text("Weekly Plan")
                    // Live count of meals planned this week (mirrors ShoppingListView).
                    if plannedMealCount > 0 {
                        Text("\(plannedMealCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue, in: Capsule())
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                plannedMealCount > 0
                    ? "Weekly plan, \(plannedMealCount) meal\(plannedMealCount == 1 ? "" : "s") planned"
                    : "Weekly plan"
            )

            Button {
                showSnackPicker = true
            } label: {
                HStack(spacing: 6) {
                    Text("🍿")
                    Text("Snack")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Snack on something from your fridge")
        }
        .padding(.horizontal)
    }

    // MARK: - Use it up

    /// Names of fresh fridge items expiring within 3 days.
    private var expiringSoonItemNames: [String] {
        let cutoff = Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()
        return frydgeManager.storedIngredients
            .filter { $0.lifecycle == .fridge && !$0.isExpired && $0.expirationDate <= cutoff }
            .map(\.name)
    }

    /// Ranks the user's own saved recipes by how useful they are right now:
    /// recipes that use something about to expire first (most expiring items
    /// used wins), then by how much of the recipe the fridge already covers.
    /// Only recipes that are at least half covered are shown, so the strip is
    /// "things you can actually cook" rather than everything in the book.
    private func recomputeSuggestions() {
        useItUpTask?.cancel()

        let fridgeNames = fridgeItemNames()
        guard !fridgeNames.isEmpty else {
            useItUpCandidates = []
            useItUpPage = 0
            return
        }

        let expiring = expiringSoonItemNames
        let recipes = recipeModel.recipes

        // Scoring every recipe against the fridge is hundreds of thousands of
        // token lookups. It ran on the main thread on every appearance and
        // every fridge change, which is part of why switching to this tab
        // stalled; it now runs on a background task and lands when ready.
        useItUpTask = Task.detached(priority: .userInitiated) {
            let ranked = Self.rankUseItUp(recipes: recipes, fridgeNames: fridgeNames, expiring: expiring)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Keep the user's place in the pages when nothing meaningful
                // changed; otherwise start from the best.
                if ranked.map(\.id) != useItUpCandidates.map(\.id) {
                    useItUpPage = 0
                }
                useItUpCandidates = ranked
            }
        }
    }

    /// Pure scoring pass over a snapshot, safe to run off the main actor.
    nonisolated private static func rankUseItUp(
        recipes: [CloudRecipe],
        fridgeNames: [String],
        expiring: [String]
    ) -> [FridgeRecipePick] {
        // Index the fridge once for the whole pass.
        let fridgeIndex = IngredientMatcher.Index(names: fridgeNames)

        let scored: [FridgeRecipePick] = recipes.compactMap { recipe in
            let total = max(1, recipe.ingredients.count)
            // Same matcher as availability and cook-time deductions, so the
            // strip counts the same matches as the rest of the app.
            let have = IngredientMatcher.coveredLineCount(recipe.ingredients, in: fridgeIndex)
            guard have >= 2 else { return nil }

            // Which expiring items this recipe would use up.
            let usesExpiring = expiring.filter { name in
                recipe.ingredients.contains { IngredientMatcher.matches(name, $0) }
            }
            let coverage = Double(have) / Double(total)
            guard !usesExpiring.isEmpty || coverage >= 0.5 else { return nil }

            return FridgeRecipePick(recipe: recipe, expiringUsed: usesExpiring, have: have, total: total)
        }

        return scored.sorted { a, b in
            if a.expiringUsed.count != b.expiringUsed.count {
                return a.expiringUsed.count > b.expiringUsed.count
            }
            let ca = Double(a.have) / Double(a.total)
            let cb = Double(b.have) / Double(b.total)
            if ca != cb { return ca > cb }
            return a.recipe.name.localizedCaseInsensitiveCompare(b.recipe.name) == .orderedAscending
        }
    }

    /// Refresh button in the "Use it up" header: shows the next page of
    /// qualifying recipes. With only one page's worth, reshuffles that page so
    /// the tap still surfaces something different at the front.
    private func refreshUseItUp() {
        withAnimation(.snappy) {
            if useItUpCandidates.count > Self.useItUpPageSize {
                useItUpPage += 1
            } else {
                useItUpCandidates.shuffle()
            }
        }
    }

    /// Mine + every shared frydge the user can see, so "Suggested for you"
    /// reflects what's actually cookable regardless of which list it's in.
    private func fridgeItemNames() -> [String] {
        let mine = frydgeManager.storedIngredients
            .filter { $0.lifecycle == .fridge && !$0.isExpired }
            .map(\.name)

        let shared = sharedFridgeManager.sharedFrydgeAnchors.flatMap { anchor in
            (sharedFridgeManager.itemsByFridge[anchor.recordID] ?? [])
                .map { StoredIngredient(fromSharedRecord: $0) }
                .filter { $0.lifecycle == .fridge && !$0.isExpired }
                .map(\.name)
        }

        return mine + shared
    }

    /// Mine + every shared frydge, each wired to the right write path —
    /// personal usage updates go through `frydgeManager`, shared ones through
    /// `sharedFridgeManager` (mirrors `SharedFrydgeView.sharedActions(for:)`
    /// so a shared item behaves identically whether opened from there or here).
    private func snackableItems() -> [SnackableItem] {
        let mine = frydgeManager.storedIngredients
            .filter { $0.lifecycle == .fridge && !$0.isExpired }
            .map { item in
                SnackableItem(
                    item: item,
                    onUsageChange: { updateItemUsage(item, newUsage: $0) },
                    actions: nil
                )
            }

        let shared = sharedFridgeManager.sharedFrydgeAnchors.flatMap { anchor -> [SnackableItem] in
            let scope: SharedFridgeManager.ShareScope = sharedFridgeManager.owned.contains { $0.recordID == anchor.recordID }
                ? .owned : .incoming

            return (sharedFridgeManager.itemsByFridge[anchor.recordID] ?? []).compactMap { rec -> SnackableItem? in
                let stored = StoredIngredient(fromSharedRecord: rec)
                guard stored.lifecycle == .fridge, !stored.isExpired else { return nil }
                let recordName = rec.recordID.recordName

                return SnackableItem(
                    item: stored,
                    onUsageChange: { newValue in
                        Task { await sharedFridgeManager.updateSharedItemUsage(recordName: recordName, quantityUsed: newValue) }
                    },
                    actions: IngredientEditActions(
                        setLocation: { newLocation in
                            await sharedFridgeManager.updateSharedItem(
                                rec, in: anchor, scope: scope,
                                newLocationRaw: newLocation, newExpirationDate: nil
                            )
                            if let updated = sharedFridgeManager.itemsByFridge[anchor.recordID]?
                                .first(where: { $0.recordID == rec.recordID }),
                               let d = updated["expirationDate"] as? Date {
                                return d
                            }
                            return (rec["expirationDate"] as? Date) ?? Date()
                        },
                        setExpiration: { newDate in
                            await sharedFridgeManager.updateSharedItem(
                                rec, in: anchor, scope: scope,
                                newLocationRaw: nil, newExpirationDate: newDate
                            )
                        },
                        delete: {
                            _ = await sharedFridgeManager.removeSharedItemAnywhere(recordName: recordName)
                        }
                    )
                )
            }
        }

        return mine + shared
    }

    // MARK: - Leftovers Section

    @ViewBuilder
    private var leftoversSection: some View {
        let active = leftoverManager.activeItems
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Leftovers")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Spacer()
                    Button {
                        leftoverManager.purgeExpired()
                    } label: {
                        Text("Clear expired")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 6)

                LazyVStack(spacing: 6) {
                    ForEach(active) { item in
                        LeftoverCard(
                            item: item,
                            onConsume: { remaining in
                                leftoverManager.updatePortions(id: item.id, portions: remaining)
                            },
                            onDelete: {
                                leftoverManager.remove(id: item.id)
                            }
                        )
                        .padding(.horizontal)
                    }
                }
            }
        }
    }
    
    // MARK: - Pull-to-refresh handler
    @MainActor
    private func performFullRefresh() async {
        print("[FrydgeView] 🔄 Full refresh started")
        
        // Refresh "mine" list from CloudKit
        print("[FrydgeView] 🔄 Syncing personal frydge...")
        await frydgeManager.syncFromCloud()
        
        // Refresh shared frydges from CloudKit
        print("[FrydgeView] 🔄 Syncing shared frydges...")
        await sharedFridgeManager.refreshSharedFrydges()
        
        print("[FrydgeView] ✅ Full refresh complete")
    }

    
    // MARK: - Shared Frydge Section
    
    private var sharedFridgeSection: some View {
        // SharedFridgeView renders its own "Shared frydges" title and drag
        // hint, so this wrapper no longer duplicates them — just hosts it.
        //
        // Drop targeting lives on each shared frydge row inside SharedFridgeView
        // (per-row targets are reliable; one big drop zone wrapping this nested
        // scroll view was not).
        SharedFridgeView()
            .padding(.top, 12)
            .environmentObject(invites)
            .environmentObject(frydgeManager)
            .environmentObject(sharedFridgeManager)
    }

    // MARK: - Drag & drop between Mine and Shared frydges

    /// Handles a shared-frydge item dropped onto the Mine section. Works for both
    /// frydges you own and frydges shared *with* you (participant): the source
    /// record is removed first, and only items that were actually removed get
    /// recreated in Mine — so a read-only share can't leave a duplicate behind.
    private func handleDropToMine(_ dropped: [DraggableFridgeItem]) -> Bool {
        let sharedItems = dropped.filter { $0.fromSharedAnchorRecordName != nil }
        guard !sharedItems.isEmpty else { return false }

        Task { @MainActor in
            var movedNames: [String] = []
            for d in sharedItems {
                let removed = await sharedFridgeManager.removeSharedItemAnywhere(recordName: d.id)
                guard removed else { continue }
                let location = FoodStorageClassifier.normalize(d.location)
                frydgeManager.addProduct(
                    name: d.name,
                    quantity: d.quantity.isEmpty ? "1" : d.quantity,
                    unit: d.unit,
                    expirationDate: d.expirationDate,
                    location: location,
                    dietaryTags: Set(d.dietaryTags),
                    lifecycle: d.lifecycle
                        .flatMap(StoredIngredient.ItemLifecycle.init(rawValue:)) ?? .fridge
                )
                movedNames.append(d.name)
            }
            if !movedNames.isEmpty {
                announceMoved(names: movedNames, destination: "Mine")
            }
        }
        return true
    }

    private func displayName(for anchor: CKRecord) -> String {
        sharedFridgeManager.namesByFridge[anchor.recordID]
            ?? (anchor["name"] as? String ?? "Shared Frydge")
    }

    private func announceMoved(_ items: [StoredIngredient], destination: String) {
        announceMoved(names: items.map(\.name), destination: destination)
    }

    /// Confirmation banner naming what was moved and where.
    private func announceMoved(names: [String], destination: String) {
        guard let first = names.first else { return }
        let message: String
        if names.count == 1 {
            message = "\(first) → \(destination)"
        } else {
            message = "\(first) + \(names.count - 1) more → \(destination)"
        }
        appState.showBanner(title: "Moved", message: message, systemImage: "arrow.left.arrow.right")
    }

    /// Moves a single Mine item into a shared frydge using the canonical record API
    /// (`StoredIngredient` records) that `SharedFrydgeView` renders, then removes the
    /// local copy so the item lives in exactly one place.
    private func moveItem(_ item: StoredIngredient, to anchor: CKRecord) {
        Task {
            let shared = sharedFridgeManager.makeSharedFrydgeItem(
                name: item.name,
                quantity: item.quantity,
                unit: item.unit,
                location: item.location,
                dietaryTags: Array(item.dietaryTags),
                expirationDate: item.expirationDate,
                lifecycle: item.lifecycle.rawValue
            )
            let moved = await sharedFridgeManager.importItemsAndReload(
                [shared], into: anchor, scope: sharedFridgeManager.scope(for: anchor)
            )
            // Only drop the local copy once the shared copy is safely saved.
            guard moved else { return }
            await frydgeManager.deleteItem(item)
        }
    }

    // MARK: - Used Up Item Tracking (24-hour window)
    
    private let usedUpItemsKey = "usedUpFridgeItems"
    
    private func markItemAsUsedUp(_ item: StoredIngredient) {
        var usedUpItems = loadUsedUpItems()
        usedUpItems[item.id.uuidString] = Date()
        saveUsedUpItems(usedUpItems)
        recentlyUsedUpIDs.insert(item.id)
    }
    
    private func loadUsedUpItems() -> [String: Date] {
        guard let data = UserDefaults.standard.data(forKey: usedUpItemsKey),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return [:]
        }
        
        // Clean up items older than 24 hours
        let now = Date()
        return decoded.filter { key, timestamp in
            let hoursSince = now.timeIntervalSince(timestamp) / 3600
            return hoursSince < 24
        }
    }
    
    private func saveUsedUpItems(_ items: [String: Date]) {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: usedUpItemsKey)
        }
    }
    
    // MARK: - Add to Shopping List
    
    private func addToShoppingList(_ item: StoredIngredient) {
        // Add item to shopping list with same details
        shoppingListManager.addToShoppingList(
            name: item.name,
            quantity: item.quantity,
            unit: item.unit,
            location: "Store",
            dietaryTags: item.dietaryTags
        )
        
        // Clear the used-up tracking for this item
        var usedUpItems = loadUsedUpItems()
        usedUpItems.removeValue(forKey: item.id.uuidString)
        saveUsedUpItems(usedUpItems)
        recentlyUsedUpIDs.remove(item.id)
        
        // Optionally delete the item from fridge or reset usage
        // For now, let's reset usage to 0 so they can track the new purchase
        Task {
            await frydgeManager.updateIngredientUsage(item.id, quantityUsed: 0)
        }
    }
    
    // MARK: - Helper: Expires text
    private func expiresText(for item: StoredIngredient) -> String {
        let daysLeft = Calendar.current.dateComponents([.day], from: Date(), to: item.expirationDate).day ?? 0
        
        if item.isExpired {
            let daysPast = abs(daysLeft)
            return daysPast == 0 ? "Expired today" : "Expired \(daysPast) day\(daysPast == 1 ? "" : "s") ago"
        } else if daysLeft == 0 {
            return "Expires today"
        } else if daysLeft == 1 {
            return "Expires in 1 day"
        } else {
            return "Expires in \(daysLeft) days"
        }
    }
    
    // MARK: - Helper: Slider color
    private func sliderColor(for daysLeft: Int) -> Color {
        if daysLeft <= 0 {
            return .red
        } else if daysLeft <= 2 {
            return .orange
        } else if daysLeft <= 5 {
            return .yellow
        } else {
            return .green
        }
    }

    // MARK: - Delete Functions (Mine Only)
    private func deleteItem(_ item: StoredIngredient) {
        Task { await frydgeManager.deleteItem(item) }
    }
    
    // MARK: - Usage Update
    private func updateItemUsage(_ item: StoredIngredient, newUsage: Double) {
        Task {
            await frydgeManager.updateIngredientUsage(item.id, quantityUsed: newUsage)
        }
    }

    /// Bulk move (multi-select mode). Uses the same canonical record API as the
    /// per-item `moveItem(_:to:)` so both paths agree with what `SharedFrydgeView`
    /// renders (previously this wrote to the anchor's `itemsJSON`, which the shared
    /// view never reads — so moved items appeared to vanish).
    private func moveSelectedItems(to anchor: CKRecord) async {
        let ids = selectedMoveIDs
        guard !ids.isEmpty else { return }

        let local = frydgeManager.storedIngredients
            .filter { ids.contains($0.id) && $0.lifecycle == .fridge }
        guard !local.isEmpty else { return }

        let items = local.map {
            sharedFridgeManager.makeSharedFrydgeItem(
                name: $0.name,
                quantity: $0.quantity,
                unit: $0.unit,
                location: $0.location,
                dietaryTags: Array($0.dietaryTags),
                expirationDate: $0.expirationDate
            )
        }

        let moved = await sharedFridgeManager.importItemsAndReload(
            items, into: anchor, scope: sharedFridgeManager.scope(for: anchor)
        )
        guard moved else { return }

        await MainActor.run {
            selectedMoveIDs.removeAll()
            isSelectingToMove = false
        }

        // Remove the local copies so each item lives in exactly one place.
        for item in local {
            await frydgeManager.deleteItem(item)
        }
        announceMoved(local, destination: displayName(for: anchor))
    }
}

/// Lets the user pick which of their own items to move into a shared frydge.
private struct MoveItemsPickerSheet: View {
    let destinationName: String
    let items: [StoredIngredient]
    @Binding var selected: Set<UUID>
    let onMove: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    Text("Nothing in your fridge to move.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items, id: \.id) { item in
                        Button {
                            if selected.contains(item.id) {
                                selected.remove(item.id)
                            } else {
                                selected.insert(item.id)
                            }
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(item.id) ? Color.blue : Color.secondary)
                                Text(item.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Move to \(destinationName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move (\(selected.count))") { onMove() }
                        .disabled(selected.isEmpty)
                }
            }
        }
    }
}

// MARK: - Use it up section: a separate View type with narrow inputs so
// unrelated FrydgeView state changes don't re-run this every body evaluation.

/// One of the user's saved recipes, with why it's being suggested right now.
struct FridgeRecipePick: Identifiable, Equatable {
    let recipe: CloudRecipe
    /// Fridge items expiring within 3 days that this recipe would use.
    let expiringUsed: [String]
    let have: Int
    let total: Int

    var id: String { recipe.id }

    /// "Uses eggs, spinach" — or nil when nothing in it is about to expire.
    var note: String? {
        guard !expiringUsed.isEmpty else { return nil }
        let names = expiringUsed.prefix(2).map { FridgeDisplayName.short(for: $0).lowercased() }
        let extra = expiringUsed.count - names.count
        return "Uses " + names.joined(separator: ", ") + (extra > 0 ? " +\(extra)" : "")
    }

    static func == (lhs: FridgeRecipePick, rhs: FridgeRecipePick) -> Bool {
        lhs.id == rhs.id && lhs.expiringUsed == rhs.expiringUsed && lhs.have == rhs.have && lhs.total == rhs.total
    }
}

/// A compact horizontal strip of recipe photos: the user's own recipes that
/// use what's about to expire (or that the fridge already mostly covers).
/// Replaces the old text list of AI ideas and the separate Suggestions
/// toggle, which showed the same recipes twice.
private struct UseItUpSection: View {
    let recipes: [FridgeRecipePick]
    let canRefresh: Bool
    let onRefresh: () -> Void
    let onSelect: (CloudRecipe) -> Void

    private var expiringCount: Int { recipes.filter { !$0.expiringUsed.isEmpty }.count }

    var body: some View {
        if !recipes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Use it up", systemImage: "sparkles")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(.purple)
                    Spacer()
                    Text(expiringCount > 0
                         ? "Your recipes that use what's expiring"
                         : "Your recipes you can make now")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if canRefresh {
                        Button(action: onRefresh) {
                            Image(systemName: "arrow.clockwise")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.purple)
                                .padding(6)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show other recipes")
                        .accessibilityHint("Swaps in a different set of recipes you can make")
                    }
                }
                .padding(.horizontal)
                .padding(.top, 6)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(recipes) { entry in
                            Button {
                                onSelect(entry.recipe)
                            } label: {
                                SuggestedRecipeCard(
                                    recipe: entry.recipe,
                                    have: entry.have,
                                    total: entry.total,
                                    note: entry.note
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                "\(entry.recipe.name), \(entry.have) of \(entry.total) ingredients"
                                + (entry.note.map { ", \($0)" } ?? "")
                            )
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

// MARK: - Mine section: a separate View type with narrow inputs so unrelated
// FrydgeView state changes (emoji rotation, sheet toggles, drag state elsewhere)
// don't re-run the inventory filter/sort on every body evaluation.

private struct MineSection: View {
    let storedIngredients: [StoredIngredient]
    let recipes: [CloudRecipe]
    @Binding var fridgeSort: FrydgeView.FridgeSort
    @Binding var isDropTargetingMine: Bool
    let imageSyncToken: Int
    let recentlyUsedUpIDs: Set<UUID>
    let isSelectingToMove: Bool
    let onOpenAddSearch: () -> Void
    let onTapDetail: (StoredIngredient) -> Void
    let onUsageChange: (StoredIngredient, Double) -> Void
    let onMarkUsedUp: (StoredIngredient) -> Void
    let onAddToList: (StoredIngredient) -> Void
    let onDelete: (StoredIngredient) -> Void
    let onDropToMine: ([DraggableFridgeItem]) -> Bool

    private var freshItems: [StoredIngredient] {
        sortedForDisplay(storedIngredients.filter { !$0.isExpired && $0.lifecycle == .fridge })
    }
    private var expiredItems: [StoredIngredient] {
        storedIngredients.filter { $0.isExpired && $0.lifecycle == .fridge }
    }

    var body: some View {
        // The whole Mine block (header + rows) is one drop target, so a shared item
        // dropped anywhere over "Mine" — not just on the tiny title — moves in.
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Mine")
                    .font(.title3)
                    .fontWeight(.semibold)

                if isDropTargetingMine {
                    Text("Drop to move here")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                }

                Spacer()

                Menu {
                    ForEach(FrydgeView.FridgeSort.allCases, id: \.self) { option in
                        Button {
                            fridgeSort = option
                        } label: {
                            Label(option.label, systemImage: option.icon)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(fridgeSort.label)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .padding(.top, 6)

            if freshItems.isEmpty && expiredItems.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Add what's in your fridge so you always know what you have — and what to cook with it.")
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        onOpenAddSearch()
                    } label: {
                        Label("Add an Item", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
                // Give an empty fridge a real drop area to aim at.
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            } else {
                ForEach(freshItems, id: \.id) { item in
                    mineRow(item)
                }

                ForEach(expiredItems, id: \.id) { item in
                    mineRow(item)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.blue.opacity(isDropTargetingMine ? 0.10 : 0))
                .padding(.horizontal, 8)
        )
        .dropDestination(for: DraggableFridgeItem.self) { dropped, _ in
            onDropToMine(dropped)
        } isTargeted: { targeting in
            isDropTargetingMine = targeting
        }
    }

    /// A personal ("Mine") item rendered via the shared `FridgeItemRow`.
    @ViewBuilder
    private func mineRow(_ item: StoredIngredient) -> some View {
        FridgeItemRow(
            item: item,
            syncToken: imageSyncToken,
            showAddToList: recentlyUsedUpIDs.contains(item.id),
            onTapDetail: {
                if !isSelectingToMove { onTapDetail(item) }
            },
            onUsageChange: { newValue in
                onUsageChange(item, newValue)
                if newValue >= 100 { onMarkUsedUp(item) }
            },
            onAddToList: { onAddToList(item) }
        )
        .padding(.horizontal)
        // Swipe left to delete (coordinated by `.swipeActionsContainer()` on the
        // scroll view). Long-press still begins a drag onto a shared frydge card;
        // delete is also available in the item's detail sheet.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDelete(item)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .draggable(DraggableFridgeItem(from: item))
    }

    /// Orders fridge items by the chosen sort: soonest expiry first, or by how
    /// many known recipes each item can help cook (most useful first).
    private func sortedForDisplay(_ items: [StoredIngredient]) -> [StoredIngredient] {
        switch fridgeSort {
        case .expiry:
            return items.sorted { $0.expirationDate < $1.expirationDate }
        case .recipe:
            let counts = Dictionary(uniqueKeysWithValues: items.map { ($0.id, recipeUsageCount(for: $0)) })
            return items.sorted {
                let a = counts[$0.id] ?? 0, b = counts[$1.id] ?? 0
                if a == b { return $0.expirationDate < $1.expirationDate }
                return a > b
            }
        case .recentlyAdded:
            // No persisted "date added" field — new items are appended, so the
            // most recently added item is last in the underlying array.
            return Array(items.reversed())
        case .foodType:
            // Same "walk round the shop" order the shopping list uses: meat,
            // dairy, pasta… at the top; nuts, sauces and seasoning at the bottom.
            return items.sorted { ShopAisle.precedes($0.name, $1.name) }
        case .alphabetical:
            return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    /// How many known recipes use this fridge item (shared matcher). One set
    /// intersection per recipe; recipe line tokens are memoised, so sorting
    /// the whole fridge by this stays cheap even with hundreds of recipes.
    private func recipeUsageCount(for item: StoredIngredient) -> Int {
        let itemTokens = IngredientMatcher.tokens(item.name)
        guard !itemTokens.isEmpty else { return 0 }
        return recipes.reduce(0) { count, recipe in
            count + (IngredientMatcher.tokensMatch(IngredientMatcher.recipeTokens(recipe.ingredients), itemTokens) ? 1 : 0)
        }
    }
}

// MARK: - Suggested recipe card: owns its own image loader so photos load for every suggestion

private struct SuggestedRecipeCard: View {
    let recipe: CloudRecipe
    let have: Int
    let total: Int
    /// Why this recipe is here right now ("Uses eggs, spinach"); nil hides the line.
    var note: String? = nil

    @StateObject private var imageLoader = RecipeImageLoader()

    private let cardWidth: CGFloat = 136
    private let imageHeight: CGFloat = 92

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let img = imageLoader.image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    // Same chapter-coloured artwork as the recipe list, so a
                    // recipe without a photo still reads as a picture card.
                    RecipePlaceholderArtwork(recipeName: recipe.name, category: RecipeCategory.classify(recipe))
                        .overlay {
                            if imageLoader.isLoading {
                                ProgressView().tint(.white.opacity(0.9))
                            }
                        }
                }
            }
            .frame(width: cardWidth, height: imageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                // Coverage pill on the photo: "5/7".
                Text("\(have)/\(total)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background((have >= total ? Color.green : Color.black.opacity(0.55)), in: Capsule())
                    .padding(6)
            }

            // Reserve two lines so titles line up across cards.
            Text(recipe.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(note ?? "\(have) of \(total) in your frydge")
                .font(.caption2.weight(note == nil ? .regular : .semibold))
                .foregroundStyle(note == nil ? Color.secondary : Color.orange)
                .lineLimit(1)
        }
        .frame(width: cardWidth, alignment: .leading)
        .onAppear { imageLoader.load(recipe: recipe) }
        .onDisappear { imageLoader.cancel() }
    }
}

// FridgeItemThumbnailView and FridgeItemRow are defined in FridgeItemRow.swift
// (shared by the personal list and the shared frydges).

// SwipeToDeleteRow is defined in SwipeToDeleteRow.swift (shared across the app)

private struct OFFSearchResponse: Decodable {
    let products: [OFFSearchProduct]
}

private struct OFFSearchProduct: Decodable {
    let imageFrontURL: String?
    let imageURL: String?

    enum CodingKeys: String, CodingKey {
        case imageFrontURL = "image_front_url"
        case imageURL = "image_url"
    }
}
