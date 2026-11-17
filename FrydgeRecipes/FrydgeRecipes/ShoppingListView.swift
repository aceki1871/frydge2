//
//  ShoppingListView.swift
//  FrydgeRecipes
//

import SwiftUI
import CoreLocation
import CloudKit
import UIKit
import PhotosUI

// MARK: - Store Branding

// Internal (not private) so InStoreBanner can reuse the same chain logos.
enum StoreBranding {
    @MainActor
    static func logo(for storeName: String) -> some View {
        let normalized = normalizedStoreName(storeName)
        let assetCandidates = assetNames(for: normalized)

        if let resolvedAsset = firstExistingAssetName(in: assetCandidates) {
            return AnyView(
                Image(resolvedAsset)
                    .resizable()
                    .scaledToFit()
            )
        }

        return AnyView(
            Image(systemName: fallbackSystemImage(for: normalized))
                .resizable()
                .scaledToFit()
                .foregroundStyle(.blue)
        )
    }

    private static func normalizedStoreName(_ storeName: String) -> String {
        storeName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func assetNames(for normalizedName: String) -> [String] {
        if normalizedName.contains("woolworth") || normalizedName.contains("woolies") {
            return ["woolworths", "woolworthsnz", "countdown"]
        }
        if normalizedName.contains("countdown") {
            return ["countdown", "woolworths", "woolworthsnz"]
        }
        if normalizedName.contains("pak n save") || normalizedName.contains("paknsave") || (normalizedName.contains("pak") && normalizedName.contains("save")) {
            return ["paknsave", "paknsave_nz", "paknsave-logo"]
        }
        if normalizedName.contains("new world") || normalizedName.contains("newworld") {
            return ["newworld", "newworld_nz", "newworld-logo"]
        }
        if normalizedName.contains("tesco") {
            return ["tesco"]
        }
        if normalizedName.contains("sainsbury") {
            return ["sainsburys", "sainsburys-logo"]
        }
        if normalizedName.contains("waitrose") {
            return ["waitrose"]
        }
        if normalizedName.contains("marks and spencer") || normalizedName.contains("m and s") || normalizedName.contains("m s") {
            return ["mands", "marksandspencer", "marks_and_spencer"]
        }
        if normalizedName.contains("aldi") {
            return ["aldi"]
        }
        if normalizedName.contains("asda") {
            return ["asda"]
        }
        if normalizedName.contains("morrison") {
            return ["morrisons", "morrisons-logo"]
        }
        if normalizedName.contains("four square") || normalizedName.contains("foursquare") {
            return ["foursquare", "four_square"]
        }
        if normalizedName.contains("co op") || normalizedName.contains("coop") {
            return ["coop", "co-op"]
        }
        return []
    }

    /// Asset-catalog lookups are not free and this runs for every store row on
    /// every render, so remember the answer per candidate list. Main-actor
    /// only (called from view bodies).
    @MainActor private static var resolvedAssetCache: [[String]: String?] = [:]

    @MainActor
    private static func firstExistingAssetName(in candidates: [String]) -> String? {
        if let cached = resolvedAssetCache[candidates] {
            return cached
        }
        let resolved = candidates.first { UIImage(named: $0) != nil }
        resolvedAssetCache[candidates] = resolved
        return resolved
    }

    private static func fallbackSystemImage(for normalizedName: String) -> String {
        if normalizedName.contains("chemist") || normalizedName.contains("pharmacy") || normalizedName.contains("boots") || normalizedName.contains("superdrug") {
            return "cross.case.fill"
        }
        return "bag.fill"
    }
}

// MARK: - ShoppingListView

struct ShoppingListView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var productViewModel   = ProductViewModel()
    @StateObject private var geoLocationManager = GeoLocationManager()
    @StateObject private var locationManager    = LocationManager()

    // In-store mode: which shop we're in, and which items it doesn't sell.
    // The model keeps every chain's offers per item (Mine and shared) and
    // greys out the ones the current chain doesn't list.
    @ObservedObject private var inStoreSession = InStoreSession.shared
    @StateObject private var inStoreAvailability = InStoreAvailabilityModel()
    @EnvironmentObject var appState:                AppState
    // @StateObject so the model is created once for this view's lifetime;
    // @ObservedObject with an inline initialiser rebuilt it on every parent
    // re-render, discarding its loaded recipes.
    @StateObject private var recipeListModel = RecipeListModel()
    @EnvironmentObject var frydgeManager:          FrydgeManager
    @EnvironmentObject var shoppingListManager:    ShoppingListManager
    @EnvironmentObject var sharedShoppingListManager: SharedShoppingListManager
    // Needed so a receipt scanned from here can be sent to a shared frydge.
    @EnvironmentObject var sharedFridgeManager: SharedFridgeManager
    @Environment(\.colorScheme) private var colorScheme

    // MARK: UI state
    @State private var showAddedToInventoryMessage = false
    @State private var checkedItems:   Set<UUID> = []
    @State private var showError       = false
    @State private var errorMessage    = ""
    @State private var rooms:          [Room]   = []
    @State private var showProductDetails  = false
    @State private var productDetails:     OFFProduct?
    @State private var stockAvailability:  [UUID: Bool]  = [:]
    @State private var bestOfferByItemID:  [UUID: RetailOffer] = [:]
    @State private var queriedItems:       Set<UUID>     = []
    @State private var recommendedStore:   (name: String, priceText: String?, totalText: String?)? = nil

    // MARK: Drag & drop (Mine ⇄ shared lists)
    @State private var isDropTargetingMineSL = false
    @State private var dropTargetedSharedAnchorID: CKRecord.ID? = nil

    // MARK: Unified item detail (personal + shared open the same sheet)
    private struct ShoppingDetailSelection: Identifiable {
        let item: ShoppingListItem
        /// nil = personal item; otherwise the shared list it belongs to.
        let sharedAnchor: CKRecord?
        /// Set when opened from the store-arrival notification: the store the
        /// shopper is standing in, so the sheet can suggest in-store picks.
        var inStoreName: String? = nil
        var id: UUID { item.id }
    }
    @State private var shoppingDetail: ShoppingDetailSelection? = nil

    // MARK: Item lookup
    @State private var showItemLookupSheet = false
    @State private var lookupItem:         ShoppingListItem? = nil
    @State private var showAvailabilityOptionsSheet = false
    @State private var pendingAvailabilityItem: ShoppingListItem? = nil
    @State private var pendingAvailabilityName: String = ""
    @State private var pendingAvailabilityQuantity: String = ""
    @State private var pendingAvailabilityUnit: String = ""

    // MARK: Dismissed auto-items
    @State private var dismissedAutoItems: Set<String> = []
    private let dismissedKey = "dismissedAutoShoppingItems"

    // MARK: Shared lists
    @State private var expandedSharedAnchors:  Set<CKRecord.ID>                    = []
    @State private var sharedItemsByAnchorID:  [CKRecord.ID: [SharedShoppingListItem]] = [:]
    @State private var checkedSharedItemIDs:   Set<UUID>                           = []
    @State private var sharedTotalsByAnchorID: [CKRecord.ID: String]               = [:]
    @State private var showAddSharedItemSheet  = false
    @State private var showAddRecipeToSharedSheet = false
    @State private var addTargetAnchor:        CKRecord? = nil
    @State private var newSharedItemName       = ""
    @State private var showCreateSharedListSheet = false
    @State private var newSharedListName       = ""
    @State private var newSharedListEmoji      = "🛒"
    @State private var activeShareSheet: (share: CKShare, root: CKRecord)? = nil
    
    // ✅ Invite handling (managed globally by FrydgeRecipesApp)
    @EnvironmentObject private var pendingInvites: PendingInvites
    
    // ✅ Performance: Cache share pairs to avoid repeated CloudKit fetches
    @State private var cachedSharePairs: [CKRecord.ID: (CKShare, CKRecord)] = [:]
    
    // ✅ UX: Track creation progress
    @State private var isCreatingList = false
    @State private var isLoadingManagement: CKRecord.ID? = nil  // Track which list is loading
    @State private var navigationResetID = 0

    // MARK: Editing product details for existing item (NEW)
    @State private var editingItem: ShoppingListItem? = nil
    @State private var showEditingProductDetails = false
    @State private var photoDetailItem: ShoppingListItem? = nil
    
    // MARK: Invitations sheet
    @State private var showInvitationsSheet = false
    
    
    // MARK: Move/drag state
    @State private var isSelectingToMove = false
    @State private var selectedMoveIDs: Set<UUID> = []
    @StateObject private var dragState = DragState()

    // Receipt and list scanning live inside the add sheet (see
    // ProductDetailsView), the same as FridgeView, so there is no header
    // camera button or scan state here.
    @State private var showProfileSheet = false

    // MARK: Basket (in-store mode)
    @State private var showBasketSheet = false

    // One-time optional Sign in with Apple offer before the first sharing action.
    @State private var showSharingSignInPrompt = false

    // MARK: Weekly planner
    @State private var showWeeklyPlanner = false
    /// Observed so the quick-action button can show how many meals are planned.
    @ObservedObject private var weekPlanStore = WeekPlanStore.shared

    // MARK: AI shopping suggestions
    @State private var shoppingSuggestions: [ShoppingSuggestion] = []
    @State private var isLoadingSuggestions = false
    @State private var showSuggestions = false

    // MARK: Add-button emoji rotation
    @State private var addEmojiIndex = 0
    /// Compact layout and this tab on screen: the only time the add-button
    /// emoji should be cycling.
    private var isAddEmojiAnimating: Bool {
        horizontalSizeClass != .regular && appState.selectedTab == .shoppingList
    }

    /// Whether location can tell us when the shopper has left a store.
    private var isLocationAuthorized: Bool {
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }

    // MARK: Tick-off grace period + undo
    /// Ticking an item marks it and waits a few seconds before it really moves
    /// to the fridge, so a mis-tap can be undone. Keyed by item id.
    @State private var pendingTickTasks: [UUID: Task<Void, Never>] = [:]
    @State private var tickToast: TickToast?
    private let tickGracePeriod: Duration = .seconds(5)

    private struct TickToast: Equatable {
        let itemID: UUID
        let name: String
        var committed = false
    }

    private let roomsFileName = "roomsData.json"

    // MARK: - Sorting ("Mine" list only — shared lists keep their own order)
    // Food type by default so the list reads in the same order as the frydge.
    // Persisted so a different choice survives relaunches. (Key bumped so
    // installs that stored the old default pick up the new one once.)
    @AppStorage("frydge.shoppingSort.v2") private var shoppingSort: ShoppingSort = .foodType

    enum ShoppingSort: String, CaseIterable {
        case recentlyAdded
        case foodType
        case priceHighToLow
        case priceLowToHigh
        case alphabetical

        var label: String {
            switch self {
            case .recentlyAdded: return "Recently added"
            case .foodType: return "Food type"
            case .priceHighToLow: return "Price: high to low"
            case .priceLowToHigh: return "Price: low to high"
            case .alphabetical: return "A–Z"
            }
        }
        var icon: String {
            switch self {
            case .recentlyAdded: return "clock"
            case .foodType: return "square.grid.2x2"
            case .priceHighToLow: return "arrow.down.right.circle"
            case .priceLowToHigh: return "arrow.up.right.circle"
            case .alphabetical: return "textformat"
            }
        }
    }

    // MARK: - Budget (set in Profile → Grocery Budget)
    @AppStorage(GroceryBudget.amountKey) private var budgetAmount: Double = 0
    @AppStorage(GroceryBudget.periodKey) private var budgetPeriodRaw: String = BudgetPeriod.weekly.rawValue
    @ObservedObject private var receiptStore = ReceiptStore.shared

    private var shoppingItems: [ShoppingListItem] {
        // While in a store, items that chain doesn't sell sink to the end of
        // whatever order is active (stable), so the walk-round order survives
        // for the things you can actually pick up.
        inStoreAvailability.sinkingGreyed(sortedShoppingItems)
    }

    private var sortedShoppingItems: [ShoppingListItem] {
        let raw = shoppingListManager.shoppingListItems
        switch shoppingSort {
        case .recentlyAdded:
            // No persisted "date added" field — new items are appended, so the
            // most recently added item is last in the underlying array.
            return Array(raw.reversed())
        case .foodType:
            // Same "walk round the shop" order the fridge uses: meat, dairy,
            // pasta… at the top; nuts, sauces and seasoning at the bottom.
            return raw.sorted { ShopAisle.precedes($0.name, $1.name) }
        case .priceHighToLow:
            return sortedByPrice(raw, descending: true)
        case .priceLowToHigh:
            return sortedByPrice(raw, descending: false)
        case .alphabetical:
            return raw.sorted {
                ProductShorthand.short(for: $0.name)
                    .localizedCaseInsensitiveCompare(ProductShorthand.short(for: $1.name)) == .orderedAscending
            }
        }
    }

    /// Priced items first in the requested direction; items without a known
    /// price keep A–Z order at the end so they don't scatter through the list.
    private func sortedByPrice(_ items: [ShoppingListItem], descending: Bool) -> [ShoppingListItem] {
        items.sorted { a, b in
            let pa = bestOfferByItemID[a.id]?.numericPrice
            let pb = bestOfferByItemID[b.id]?.numericPrice
            switch (pa, pb) {
            case let (x?, y?) where x != y:
                return descending ? x > y : x < y
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return ProductShorthand.short(for: a.name)
                    .localizedCaseInsensitiveCompare(ProductShorthand.short(for: b.name)) == .orderedAscending
            }
        }
    }

    /// Sum of the best known prices on the Mine list; nil when nothing is priced.
    private var mineEstimatedTotalValue: Double? {
        let pricedOffers = shoppingItems.compactMap { bestOfferByItemID[$0.id] }
        guard !pricedOffers.isEmpty else { return nil }
        return pricedOffers.reduce(0.0) { partial, offer in
            partial + (offer.numericPrice ?? 0)
        }
    }

    private var mineEstimatedTotalText: String? {
        guard let total = mineEstimatedTotalValue else { return nil }

        // Formatter creation is expensive and this runs on every body pass.
        let isWhole = total.truncatingRemainder(dividingBy: 1) == 0
        return total.formatted(
            .currency(code: "NZD").precision(.fractionLength(isWhole ? 0 : 2))
        )
    }

    /// Compact budget read-out under the Mine heading: receipts spent this
    /// period (solid) plus this list's estimate (lighter) against the budget.
    private var budgetLine: some View {
        let period = BudgetPeriod(rawValue: budgetPeriodRaw) ?? .weekly
        let spent = receiptStore.total(in: period.interval())
        let planned = mineEstimatedTotalValue ?? 0
        let remaining = budgetAmount - spent - planned
        let tint = GroceryBudget.tint(fraction: budgetAmount > 0 ? (spent + planned) / budgetAmount : 0)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "target")
                Text("Budget \(GroceryBudget.money(budgetAmount))/\(period.shortLabel)")
                Spacer(minLength: 8)
                Text(remaining >= 0
                     ? "\(GroceryBudget.money(remaining)) left after this list"
                     : "\(GroceryBudget.money(-remaining)) over")
                    .foregroundStyle(remaining >= 0 ? Color.secondary : tint)
                    .fontWeight(remaining >= 0 ? .regular : .semibold)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            BudgetProgressBar(budget: budgetAmount, spent: spent, planned: planned, compact: true)
        }
        .padding(.leading, horizontalSizeClass == .regular ? 16 : NotepadTheme.marginWidth + 12)
        .padding(.trailing, 16)
        .accessibilityElement(children: .combine)
    }

    private var mineHeaderTotalText: String {
        mineEstimatedTotalText ?? "$0"
    }
    
    // MARK: Move button
    
    @State private var showMoveSheet = false
    
    private var moveButton: some View {
        HStack {
            if isSelectingToMove {
                Button("Cancel") {
                    isSelectingToMove = false
                    selectedMoveIDs.removeAll()
                }
                .buttonStyle(.bordered)
                
                Button("Move \(selectedMoveIDs.count)") {
                    showMoveSheet = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedMoveIDs.isEmpty)
            } else {
                Button {
                    isSelectingToMove = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right.circle")
                        Text("Move to Shared")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
        .sheet(isPresented: $showMoveSheet) {
            MoveToSharedShoppingListSheet(
                onCancel: {
                    showMoveSheet = false
                },
                onMove: { anchor in
                    Task {
                        await moveSelectedItems(to: anchor)
                        showMoveSheet = false
                    }
                }
            )
            .environmentObject(sharedShoppingListManager)
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showAddedToInventoryMessage {
                    Text("Added to Inventory")
                        .font(.headline)
                        .foregroundColor(.blue)
                        .transition(.slide)
                        .padding(.top, 5)
                }

                if horizontalSizeClass != .regular {
                    headerView
                        .browsingHeader()
                }

                // ScrollView + LazyVStack (not List): SwiftUI's .dropDestination
                // never fires reliably inside a List, so drag-and-drop between the
                // personal list and shared lists needs a plain scrolling surface.
                // Swipe-to-delete comes from `.swipeActionsContainer()` on this
                // scroll view plus `.swipeActions` on each Mine row, which is the
                // supported way to get row swipes outside a List.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        recommendedStoreBanner
                        if horizontalSizeClass != .regular {
                            quickActionsRow
                        }
                        if showSuggestions {
                            ShoppingSuggestionsCard(
                                suggestions: shoppingSuggestions,
                                isLoading: isLoadingSuggestions,
                                onAdd: { suggestion in
                                    shoppingListManager.addToShoppingList(suggestion.name)
                                    shoppingSuggestions.removeAll { $0.id == suggestion.id }
                                },
                                onRefresh: { Task { await loadSuggestions() } }
                            )
                        }
                        AdaptiveInventoryColumns(paperStyle: horizontalSizeClass != .regular) {
                            mineSection
                        } shared: {
                            sharedSection
                        }

                        // Blank ruled lines continue down the page like a real
                        // pad; also clears the floating tab bar.
                        if horizontalSizeClass != .regular {
                            NotepadBlankLines(count: 10)
                        } else {
                            Color.clear.frame(height: 24)
                        }
                    }
                    .padding(.vertical, 3)
                    // Rows slide closed rather than vanishing when an item
                    // is ticked off or added.
                    .animation(.easeInOut(duration: 0.3), value: listAnimationToken)
                }
                // One row's swipe actions open at a time; scrolling or tapping elsewhere closes them.
                .swipeActionsContainer()
                .browsingScrollNavigation()
                // Keep the page moving while an item is dragged towards a
                // shared list that's scrolled off-screen.
                .dragAutoScroll(for: DraggableShoppingItem.self, bottomInset: 90)
                .overlay(alignment: .bottom) { tickUndoToast }
                .scrollContentBackground(.hidden)
                // ✅ Pull-to-refresh for both mine and shared lists
                .refreshable {
                    print("[ShoppingListView] 🔄 Pull-to-refresh triggered")
                    await performFullRefresh()
                }
                // Sheets for the Mine section (attached to the List, not a row,
                // so presentation survives the anchor row scrolling offscreen).
                .sheet(isPresented: $showAvailabilityOptionsSheet) {
                    AvailabilityOptionsSheet(
                        name: $pendingAvailabilityName,
                        quantity: $pendingAvailabilityQuantity,
                        unit: $pendingAvailabilityUnit,
                        onCancel: {
                            showAvailabilityOptionsSheet = false
                        },
                        onConfirm: {
                            let finalName = pendingAvailabilityName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !finalName.isEmpty else { return }

                            let source = pendingAvailabilityItem
                            lookupItem = ShoppingListItem(
                                name: finalName,
                                quantity: pendingAvailabilityQuantity.trimmingCharacters(in: .whitespacesAndNewlines),
                                unit: pendingAvailabilityUnit.trimmingCharacters(in: .whitespacesAndNewlines),
                                location: source?.location ?? "Store",
                                dietaryTags: source?.dietaryTags ?? []
                            )
                            showAvailabilityOptionsSheet = false
                            showItemLookupSheet = true
                        }
                    )
                    .presentationDetents([.medium])
                }
                .sheet(isPresented: $showProductDetails) {
                    ProductDetailsView(
                        isShowing: $showProductDetails,
                        productDetails: productDetails ?? OFFProduct(
                            code: nil, productName: "", ingredientsText: "",
                            quantity: "", imageUrl: nil, nutriments: nil
                        ),
                        context: .shopping
                    )
                    .environmentObject(frydgeManager)
                    .environmentObject(shoppingListManager)
                }
                .sheet(isPresented: $showItemLookupSheet) {
                    if let item = lookupItem {
                        ShoppingItemLookupSheet(item: item, recipeListModel: recipeListModel, onDismiss: { showItemLookupSheet = false })
                            .environmentObject(shoppingListManager)
                    } else {
                        VStack(spacing: 12) { ProgressView(); Text("Loading…").foregroundColor(.secondary) }
                            .presentationDetents([.medium])
                    }
                }
                .sheet(isPresented: $showEditingProductDetails) {
                    EditableShoppingProductDetailsSheet(
                        isShowing: $showEditingProductDetails,
                        originalItem: editingItem,
                        onSave: { original, updatedProduct in
                            updateShoppingListItem(original, with: updatedProduct)
                            editingItem = nil
                        }
                    )
                    .environmentObject(frydgeManager)
                    .environmentObject(shoppingListManager)
                }
                .sheet(item: $shoppingDetail) { sel in
                    ShoppingListItemDetailSheet(
                        item: sel.item,
                        inStoreName: sel.inStoreName,
                        onDelete: {
                            if let anchor = sel.sharedAnchor {
                                if let it = (sharedItemsByAnchorID[anchor.recordID] ?? [])
                                    .first(where: { $0.id == sel.item.id }) {
                                    Task { await deleteSharedItem(it, from: anchor) }
                                }
                            } else {
                                shoppingListManager.removeFromShoppingList(id: sel.item.id)
                            }
                        }
                    )
                }
                // Sheets for the Shared section.
                .sheet(isPresented: $showAddSharedItemSheet) { addSharedItemSheet }
                .sheet(isPresented: $showAddRecipeToSharedSheet) {
                    RecipePickerSheet(model: recipeListModel, title: "Add Recipe to List") { recipe in
                        addRecipeToSharedList(recipe)
                    }
                }
                .sheet(isPresented: $showCreateSharedListSheet) { createSharedListSheet }
                .sheet(item: Binding(
                    get: {
                        activeShareSheet.map { ShareSheetItem(share: $0.share, root: $0.root) }
                    },
                    set: { newValue in
                        activeShareSheet = newValue.map { ($0.share, $0.root) }
                    }
                )) { item in
                    sharedListManagementSheet(for: item)
                }
            }
            .background {
                CookbookBackground().ignoresSafeArea()
            }
            .navigationTitle(horizontalSizeClass == .regular ? "Shopping List" : "frydge")
            .toolbar { inventoryToolbar }
            .sheet(isPresented: $showWeeklyPlanner) {
                WeeklyPlannerView()
                    .environmentObject(frydgeManager)
                    .environmentObject(shoppingListManager)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(horizontalSizeClass == .regular ? .visible : .hidden, for: .navigationBar)
            .onAppear(perform: onAppear)
            .onChange(of: shoppingListManager.shoppingListItems, initial: false) { oldValue, newValue in
                onItemsChanged(oldValue, newValue)
            }
            .alert(isPresented: $showError) {
                Alert(title: Text("Error"), message: Text(errorMessage), dismissButton: .default(Text("OK")))
            }
            // ✅ Listen for shared shopping list changes (CloudKit push notifications)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SharedShoppingListChanged"))) { _ in
                print("[ShoppingListView] Received SharedShoppingListChanged notification")
                Task {
                    // ✅ Respect throttling even for push notifications (prevents rapid-fire refreshes)
                    if shouldPerformSharedListRefresh() {
                        await sharedShoppingListManager.refreshSharedLists()
                        await refreshStoreDrivenUI()
                        recordSharedListRefresh()
                    } else {
                        print("[ShoppingListView] ⏭️ Skipping notification-triggered refresh (too soon)")
                    }
                }
            }
            // ✅ Listen for CloudKit query notifications (general refresh)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("CloudKitQueryNotificationReceived"))) { notification in
                print("[ShoppingListView] Received CloudKitQueryNotificationReceived")
                if let userInfo = notification.userInfo,
                   let ckNotif = CKNotification(fromRemoteNotificationDictionary: userInfo),
                   let queryNotif = ckNotif as? CKQueryNotification,
                   let subscriptionID = queryNotif.subscriptionID,
                   subscriptionID.contains("SharedShoppingList_") {
                    print("[ShoppingListView] Confirmed shopping list notification")
                    Task {
                        // ✅ Respect throttling even for query notifications
                        if shouldPerformSharedListRefresh() {
                            await sharedShoppingListManager.refreshSharedLists()
                            await refreshStoreDrivenUI()
                            recordSharedListRefresh()
                        } else {
                            print("[ShoppingListView] ⏭️ Skipping query notification refresh (too soon)")
                        }
                    }
                }
            }
            // Force image re-sync triggered from Profile
            .onReceive(NotificationCenter.default.publisher(for: .frydgeForceImageSync)) { _ in
                Task {
                    stockAvailability.removeAll()
                    bestOfferByItemID.removeAll()
                    await refreshStoreDrivenUI()
                }
            }
            .sheet(isPresented: $showBasketSheet) {
                ShoppingBasketSheet(
                    items: shoppingItems,
                    offers: bestOfferByItemID,
                    totalText: mineHeaderTotalText,
                    checkedItems: $checkedItems,
                    onToggle: toggleCheckmark,
                    availability: inStoreAvailability.availability,
                    inStoreChainName: inStoreSession.current?.chainDisplayName
                )
                .environmentObject(frydgeManager)
                .environmentObject(shoppingListManager)
                .environmentObject(sharedShoppingListManager)
                .environmentObject(sharedFridgeManager)
                .environmentObject(appState)
                .environmentObject(pendingInvites)
            }
            .sheet(isPresented: $showProfileSheet) {
                ProfileView()
            }
        }
        // The notepad look is set in SF Rounded (see NotepadTheme.noteFont).
        // Applying the design here means every text style on the page and in
        // the sheets it presents picks it up, instead of each `.font(...)`
        // having to opt in and silently drifting back to plain SF.
        .fontDesign(.rounded)
        .id(navigationResetID)
        .onChange(of: appState.tabResetCounters[.shoppingList]) { _, _ in
            navigationResetID += 1
        }
        .onChange(of: appState.openBasketRequested) { _, requested in
            guard requested else { return }
            showBasketSheet = true
            appState.openBasketRequested = false
        }
        // Arriving at (or leaving) a store re-resolves every row against the
        // new chain; the offers themselves don't need refetching.
        .onChange(of: inStoreSession.current) { _, _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                inStoreAvailability.recompute()
            }
        }
        .onAppear {
            inStoreSession.refreshExpiry()
            inStoreAvailability.recompute()
            if let location = locationManager.location {
                inStoreSession.endIfLeft(location: location)
            }
        }
        // The list's own When-In-Use fixes end an arrival session once the
        // shopper is well clear of the store, no Leave tap needed.
        .onChange(of: locationManager.location) { _, location in
            guard let location else { return }
            inStoreSession.endIfLeft(location: location)
        }
        .onChange(of: appState.pendingShoppingItemDetail) { _, request in
            presentRequestedItemDetail(request)
        }
        .onAppear {
            if appState.openBasketRequested {
                showBasketSheet = true
                appState.openBasketRequested = false
            }
            presentRequestedItemDetail(appState.pendingShoppingItemDetail)
        }
    }

    /// Opens the detail sheet for an item tapped in the store-arrival
    /// notification. The id may already be gone (ticked into the fridge), so
    /// fall back to a name match, then to a name-only item so the nutrition
    /// and recipe sections still have something to show.
    private func presentRequestedItemDetail(_ request: ShoppingItemDetailRequest?) {
        guard let request else { return }
        appState.pendingShoppingItemDetail = nil

        let items = shoppingListManager.shoppingListItems
        let wantedKey = normKey(request.name)
        let found = items.first { $0.id.uuidString == request.itemID }
            ?? items.first { !wantedKey.isEmpty && normKey($0.name) == wantedKey }
        let item = found ?? ShoppingListItem(name: request.name.isEmpty ? "Item" : request.name)

        // Only one sheet can be up; make sure the basket isn't holding the slot.
        showBasketSheet = false
        DispatchQueue.main.async {
            shoppingDetail = ShoppingDetailSelection(item: item, sharedAnchor: nil, inStoreName: request.storeName)
        }
    }

    // MARK: - Header

    // Same layout as FridgeView: title + [basket, add, profile]. Like the
    // fridge there is no separate camera button: receipt and list scanning
    // are secondary actions inside the add sheet.
    @ToolbarContentBuilder
    private var inventoryToolbar: some ToolbarContent {
        if horizontalSizeClass == .regular {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Basket", systemImage: "basket") { showBasketSheet = true }
                addItemControl
                    .keyboardShortcut("n", modifiers: .command)
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Weekly Plan", systemImage: "calendar") { showWeeklyPlanner = true }
                    Button(showSuggestions ? "Hide Suggestions" : "Show Suggestions", systemImage: "sparkles") {
                        withAnimation(.easeInOut(duration: 0.2)) { showSuggestions.toggle() }
                        if showSuggestions, shoppingSuggestions.isEmpty {
                            Task { await loadSuggestions() }
                        }
                    }
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
            addEmojiLabel
        }
    }

    private var headerView: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Frydge")
                    .font(CookbookTheme.runningHeadFont)
                    .fontDesign(.default)
                    .tracking(3)
                    .foregroundStyle(CookbookTheme.inkSecondary)

                Text("Shopping List")
                    .font(.title)
                    .fontWeight(.bold)
            }

            Spacer()

            Button {
                showBasketSheet = true
            } label: {
                Image(systemName: "basket.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
            }
            .accessibilityLabel("Open basket")

            // One add button: type, search or scan a barcode, item after item.
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
        .padding(.horizontal, 16)
        .padding(.top, 5)
        .padding(.bottom, 10)
    }

    // MARK: - Add control (mirrors FridgeView)

    /// Shared shopping lists the current user owns, so they can be offered as
    /// add destinations. Owner-only because participants write through a
    /// different database.
    private var ownedSharedLists: [CKRecord] {
        sharedShoppingListManager.anchors.filter { sharedShoppingListManager.isOwnerCached(for: $0) }
    }

    /// The top "+" control. A tap always opens the item search sheet (adding
    /// to Mine), exactly like the fridge's add button. When the user owns
    /// shared lists, a long-press additionally offers those as destinations.
    private var addItemControl: some View {
        let owned = ownedSharedLists
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
                    Section("Shared lists") {
                        ForEach(owned, id: \.recordID) { anchor in
                            let id = anchor.recordID
                            let name = sharedShoppingListManager.namesByAnchorID[id]
                                ?? (anchor["name"] as? String ?? "Shared Shopping List")
                            let emoji = sharedShoppingListManager.emojisByAnchorID[id]
                                ?? (anchor["emoji"] as? String ?? "🛒")
                            Button {
                                addTargetAnchor = anchor
                                showAddSharedItemSheet = true
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
        .task(id: isAddEmojiAnimating) {
            guard isAddEmojiAnimating else { return }
            // Rotate the emoji only while this tab is the one on screen. The
            // page stays mounted behind other tabs, so without the tab check
            // this loop would keep animating an invisible view.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation(.easeInOut(duration: 0.25)) {
                    addEmojiIndex = (addEmojiIndex + 1) % FoodEmoji.showcase.count
                }
            }
        }
    }

    /// Opens the blank item search sheet for adding to Mine.
    private func openAddSearch() {
        productDetails = nil
        showProductDetails = true
    }

    /// Rotating food emoji with a plus badge — the same "add" affordance as
    /// the fridge's add button.
    private var addEmojiLabel: some View {
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
    }

    // MARK: - Quick actions

    // Compact replacement for the always-visible suggestions card and the
    // header calendar icon: one row, two buttons. Suggestions expand on demand;
    // the calendar opens the weekly planner.
    private var quickActionsRow: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showSuggestions.toggle() }
                if showSuggestions, shoppingSuggestions.isEmpty {
                    Task { await loadSuggestions() }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple)
                    Text("Suggestions")
                    Image(systemName: showSuggestions ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show suggestions")

            Button {
                showWeeklyPlanner = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .foregroundStyle(.blue)
                    Text("Weekly Plan")
                    // Live count of meals planned this week, so the button
                    // doubles as a glanceable status before opening it.
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
        }
        .padding(.horizontal, 16)
    }

    private var plannedMealCount: Int { weekPlanStore.plannedRecipes.count }

    // MARK: - Recommended store banner

    @ViewBuilder
    private var recommendedStoreBanner: some View {
        if let store = inStoreSession.current {
            // In a store: say which one and how much of the list is here.
            // "Best place to buy today" is hidden meanwhile — suggesting a
            // different shop while standing in this one isn't helpful.
            let ids = shoppingListManager.shoppingListItems.map(\.id)
                + sharedItemsByAnchorID.values.flatMap { $0.map(\.id) }
            let counts = inStoreAvailability.counts(for: ids)
            // Location ends an arrival session by itself (geofence exit or a
            // fix well outside the store), so Leave only appears for a manual
            // pick or when the user hasn't let us use their location.
            let canLeaveByLocation = store.source != .manual && isLocationAuthorized
            InStoreBanner(store: store, here: counts.here, notHere: counts.notHere, showsLeave: !canLeaveByLocation) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    inStoreSession.end()
                }
            }
        } else if let rec = recommendedStore {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    StoreBranding.logo(for: rec.name)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Best place to buy today")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(rec.name)
                            .font(.headline)
                    }
                    Spacer()
                    if let total = rec.totalText, !total.isEmpty {
                        Button {
                            showBasketSheet = true
                        } label: {
                            Text(total)
                                .font(.headline)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .notepadGlass(cornerRadius: 18)
                .padding(.horizontal)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.3), value: rec.name)
        }
    }

    // MARK: - Mine section

    /// Emits List rows directly (header, then one row per item) so that
    /// `.swipeActions` bind to real List rows. Section sheets live on the List.
    @ViewBuilder
    private var mineSection: some View {
        // The whole Mine block is one drop target, so a shared-list item dropped
        // anywhere over "Mine" moves back into your personal list.
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if horizontalSizeClass == .regular {
                    Text("My List (\(shoppingItems.count))").font(.headline)
                } else {
                    NotepadHeading(text: "Mine", count: shoppingItems.count)
                }
                if isDropTargetingMineSL {
                    Text("Drop to move here")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                }
                Spacer()

                Menu {
                    ForEach(ShoppingSort.allCases, id: \.self) { option in
                        Button {
                            shoppingSort = option
                        } label: {
                            Label(option.label, systemImage: option.icon)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(shoppingSort.label)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.blue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, horizontalSizeClass == .regular ? 16 : NotepadTheme.marginWidth + 12)
            .padding(.trailing, 16)
            .padding(.top, 6)

            if budgetAmount > 0 {
                budgetLine
            }

            if shoppingItems.isEmpty {
                Text("You have everything you need.")
                    .font(NotepadTheme.noteFont(.body))
                    .foregroundColor(.green)
                    .padding(.leading, horizontalSizeClass == .regular ? 16 : NotepadTheme.marginWidth + 12)
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .notepadRow()
            } else {
                mineList
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.blue.opacity(isDropTargetingMineSL ? 0.10 : 0))
                .padding(.horizontal, 8)
        )
        .dropDestination(for: DraggableShoppingItem.self) { dropped, _ in
            handleDropToMineShopping(dropped)
        } isTargeted: { targeting in
            isDropTargetingMineSL = targeting
        }
    }

    @Namespace private var glassNamespace

    private var mineList: some View {
        // Each row is a Liquid Glass card floating on the paper. One container
        // so the cards render together and morph as rows are added or ticked
        // away rather than popping in and out.
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 8) {
                ForEach(shoppingItems, id: \.id) { item in
                    mineRow(item)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// One glass card: tick, thumbnail, name with its pack size, dietary
    /// badges and the best price.
    private func mineRow(_ item: ShoppingListItem) -> some View {
        let isChecked = checkedItems.contains(item.id)
        let offer = bestOfferByItemID[item.id]

        return HStack(spacing: 12) {
            NotepadCheckbox(isChecked: isChecked) {
                toggleCheckmark(for: item)
            }

            Button {
                shoppingDetail = ShoppingDetailSelection(item: item, sharedAnchor: nil)
            } label: {
                ShoppingItemImageView(
                    name: item.name,
                    quantity: item.quantity,
                    unit: item.unit,
                    offer: offer
                )
            }
            .buttonStyle(.plain)

            Button {
                shoppingDetail = ShoppingDetailSelection(item: item, sharedAnchor: nil)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        notepadItemName(ProductShorthand.short(for: item.name), isChecked: isChecked)
                        if let pack = packLabel(for: item, offer: offer) {
                            quantityPill(pack, isChecked: isChecked)
                        }
                    }

                    HStack(spacing: 8) {
                        badgesForShoppingItem(item)
                    }

                    availabilityAwarePriceInfo(id: item.id, name: item.name)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .padding(.leading, 2)
        .padding(.trailing, 12)
        .opacity(isChecked ? 0.65 : 1)
        // In a store that doesn't sell this: faded in place, still tappable.
        .inStoreGreyed(inStoreAvailability.isGreyed(item.id))
        .contentShape(.rect(cornerRadius: 18))
        // Ticked rows take a green tint so the trolley reads at a glance.
        .glassEffect(
            isChecked ? .regular.tint(Color.green.opacity(0.22)) : .regular.interactive(),
            in: .rect(cornerRadius: 18)
        )
        .glassEffectID(item.id, in: glassNamespace)
        // Swipe left to delete (coordinated by `.swipeActionsContainer()` on the
        // scroll view). Long-press still begins a drag onto a shared list; tap
        // opens the detail sheet (delete is also there); the checkmark still
        // purchases into the fridge.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                deleteShoppingItem(item)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        // Swipe right while in a store to correct the app's guess.
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            inStoreCorrectionButtons(itemName: item.name, id: item.id)
        }
        .draggable(DraggableShoppingItem(from: item))
    }

    /// The usual price line, or — while in a store — the availability caption
    /// when the chain doesn't (or might not) sell the item. Shared by Mine
    /// and shared-list rows.
    @ViewBuilder
    private func availabilityAwarePriceInfo(id: UUID, name: String) -> some View {
        if let store = inStoreSession.current,
           let availability = inStoreAvailability.availability(for: id),
           availability.isGreyed || availability.isUnsure {
            InStoreAvailabilityCaption(availability: availability, chainName: store.chainDisplayName)
        } else {
            priceInfo(id: id, name: name)
        }
    }

    /// Leading-edge swipe actions while in a store: "They have it" on a greyed
    /// row, "Not here" on a normal one, plus "Reset" once a correction exists.
    /// Keyed by item name + chain, so fixing milk on a shared list fixes milk
    /// on Mine too.
    @ViewBuilder
    private func inStoreCorrectionButtons(itemName: String, id: UUID) -> some View {
        if inStoreSession.current != nil {
            if inStoreAvailability.isGreyed(id) {
                Button {
                    inStoreAvailability.setOverride(true, itemName: itemName)
                } label: {
                    Label("They have it", systemImage: "checkmark.circle")
                }
                .tint(.green)
            } else {
                Button {
                    inStoreAvailability.setOverride(false, itemName: itemName)
                } label: {
                    Label("Not here", systemImage: "xmark.circle")
                }
                .tint(.gray)
            }
            if inStoreAvailability.hasOverride(itemName: itemName) {
                Button {
                    inStoreAvailability.clearOverride(itemName: itemName)
                } label: {
                    Label("Reset", systemImage: "arrow.uturn.backward")
                }
                .tint(.orange)
            }
        }
    }

    /// Pack size to show beside the name: the item's own amount when it has
    /// one, else the matched product's pack ("2 L"), else the smallest pack
    /// the shops sell for that food. Items added by name alone used to land
    /// as "1" with no unit, which the row hid entirely — so nothing showed.
    private func packLabel(for item: ShoppingListItem, offer: RetailOffer?) -> String? {
        let quantity = item.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = item.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        if !(quantity.isEmpty || quantity == "1") || !unit.isEmpty {
            return formatPack(quantity: quantity.isEmpty ? "1" : quantity, unit: unit)
        }
        if let offer {
            let parsed = offer.parsedQuantityAndUnit
            if !(parsed.quantity == "1" && parsed.unit.isEmpty) {
                return formatPack(quantity: parsed.quantity, unit: parsed.unit)
            }
        }
        if let pack = PackSizeRules.defaultPackDisplay(name: item.name) {
            return formatPack(quantity: pack.quantity, unit: pack.unit)
        }
        return nil
    }

    /// "2 L", "500 g", "×6".
    private func formatPack(quantity: String, unit: String) -> String {
        let countUnits: Set<String> = ["", "ea", "each", "x", "pcs", "pc"]
        let cleanedUnit = countUnits.contains(unit.lowercased()) ? "" : unit
        let shown = FridgeUnits.display(quantity: quantity, unit: cleanedUnit)
        if shown.unit.isEmpty { return "×\(shown.quantity)" }
        return "\(shown.quantity) \(shown.unit)"
    }

    private func quantityPill(_ text: String, isChecked: Bool) -> some View {
        Text(text)
            .font((horizontalSizeClass == .regular ? Font.caption.weight(.semibold) : NotepadTheme.noteFont(.caption, weight: .semibold)).monospacedDigit())
            .foregroundStyle(isChecked ? NotepadTheme.fadedInk(colorScheme) : NotepadTheme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(NotepadTheme.accent.opacity(isChecked ? 0.08 : 0.14), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }

    /// Item name in ink; checked items are struck through.
    private func notepadItemName(_ text: String, isChecked: Bool) -> some View {
        Text(text)
            .font(horizontalSizeClass == .regular ? .body.weight(.medium) : NotepadTheme.noteFont(.body, weight: .medium))
            .foregroundStyle(isChecked ? NotepadTheme.fadedInk(colorScheme) : NotepadTheme.ink(colorScheme))
            .strikethrough(isChecked, color: NotepadTheme.fadedInk(colorScheme))
            .lineLimit(horizontalSizeClass == .regular ? 2 : 1)
            .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private func availabilityDot(for id: UUID) -> some View {
        if let available = stockAvailability[id] {
            Circle()
                .fill(available ? Color.green : Color.red)
                .frame(width: 10, height: 10)
        } else {
            ProgressView().frame(width: 10, height: 10)
        }
    }

    @ViewBuilder
    private func nearestCheapestInfo(for item: ShoppingListItem) -> some View {
        priceInfo(id: item.id, name: item.name)
    }

    /// At-a-glance short label (+ quantity) for a shared shopping item.
    private func sharedShorthandDisplay(_ it: SharedShoppingListItem) -> String {
        let short = ProductShorthand.short(for: it.name)
        let q = it.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = it.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty || q == "1" { return short }
        if u.isEmpty { return "\(short) ×\(q)" }
        return "\(short) \(q)\(u)"
    }

    @ViewBuilder
    private func priceInfo(id: UUID, name: String) -> some View {
        if let offer = bestOfferByItemID[id] {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)

                Text(offer.storeName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if let priceText = offer.priceText, !priceText.isEmpty {
                    Text(priceText)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
            }
        } else if let observed = ObservedPriceStore.shared.latest(for: name) {
            // No live offer yet — show what the user last actually paid.
            HStack(spacing: 6) {
                Image(systemName: observed.isSpecial ? "tag.fill" : "clock.arrow.circlepath")
                    .font(.system(size: 9))
                    .foregroundColor(observed.isSpecial ? .orange : .secondary)
                Text("Last paid \(observed.priceText)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if let store = observed.store, !store.isEmpty {
                    Text("· \(store)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        } else if let available = stockAvailability[id], !available {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Text("No stock found")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } else {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Checking nearby stores")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Shared section

    /// Section header, then one glass card per shared list (header + items
    /// when expanded) floating on top of the notepad.
    @ViewBuilder
    private var sharedSection: some View {
        HStack(alignment: .firstTextBaseline) {
            if horizontalSizeClass == .regular {
                Text("Shared Lists").font(.headline)
            } else {
                NotepadHeading(text: "Shared")
            }
            Spacer()
            Button {
                // First sharing action: offer (don't require) an Apple ID link.
                if AppleSignInGate.shouldOfferBeforeSharing {
                    showSharingSignInPrompt = true
                } else {
                    showCreateSharedListSheet = true
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Create shared list")
            .sheet(isPresented: $showSharingSignInPrompt) {
                AppleSignInPromptSheet(actionDescription: "create a shared shopping list") {
                    showCreateSharedListSheet = true
                }
            }
        }
        .padding(.leading, horizontalSizeClass == .regular ? 16 : NotepadTheme.marginWidth + 12)
        .padding(.trailing, 16)
        .padding(.top, 12)

        if sharedShoppingListManager.anchors.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Share a list with your household so everyone can see and tick off the same items.")
                    .font(NotepadTheme.noteFont(.body))
                    .foregroundStyle(NotepadTheme.fadedInk(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    if AppleSignInGate.shouldOfferBeforeSharing {
                        showSharingSignInPrompt = true
                    } else {
                        showCreateSharedListSheet = true
                    }
                } label: {
                    Label("Create a Shared List", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.glassProminent)
            }
            .padding(16)
            .notepadGlass()
            .padding(.leading, horizontalSizeClass == .regular ? 16 : NotepadTheme.marginWidth + 12)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ForEach(sharedShoppingListManager.anchors, id: \.recordID) { anchor in
                // Whole list block (header + items) is one drop target so an item
                // dragged from Mine (or another shared list) drops onto it. A glass
                // card sets each shared list apart from the flat "Mine" paper.
                VStack(alignment: .leading, spacing: 0) {
                    sharedAnchorRow(anchor)

                    if expandedSharedAnchors.contains(anchor.recordID) {
                        sharedItemRows(for: anchor)
                    }
                }
                .notepadGlass(cornerRadius: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.blue.opacity(dropTargetedSharedAnchorID == anchor.recordID ? 0.10 : 0))
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .dropDestination(for: DraggableShoppingItem.self) { dropped, _ in
                    handleDropToSharedList(dropped, anchor: anchor)
                } isTargeted: { targeting in
                    dropTargetedSharedAnchorID = targeting ? anchor.recordID
                        : (dropTargetedSharedAnchorID == anchor.recordID ? nil : dropTargetedSharedAnchorID)
                }
            }
        }
    }

    /// Management/sharing sheet for a shared list (presented from the List).
    private func sharedListManagementSheet(for item: ShareSheetItem) -> some View {
        // Native members / permissions / rename / leave sheet — the same one
        // shared frydges use — instead of the raw system sharing controller.
        // Inviting still goes through the system sheet from inside it.
        let id = item.root.recordID
        return ShareManagementSheet(
            container: sharedShoppingListManager.container,
            database: databaseForAnchor(item.root),
            kind: .shoppingList,
            share: item.share,
            rootRecord: item.root,
            initialName: sharedShoppingListManager.displayNameByAnchorID[id],
            onChanged: {
                // Name / emoji / members may have changed: drop the cached pair
                // so the next open refetches, and refresh the list headers.
                cachedSharePairs.removeValue(forKey: id)
                Task { await sharedShoppingListManager.refreshSharedLists() }
            },
            onDeleted: {
                cachedSharePairs.removeValue(forKey: id)
                sharedItemsByAnchorID.removeValue(forKey: id)
                expandedSharedAnchors.remove(id)
                activeShareSheet = nil
                Task { await sharedShoppingListManager.refreshSharedLists() }
            },
            onLeft: {
                cachedSharePairs.removeValue(forKey: id)
                sharedItemsByAnchorID.removeValue(forKey: id)
                expandedSharedAnchors.remove(id)
                activeShareSheet = nil
                Task { await sharedShoppingListManager.refreshSharedLists() }
            },
            onStoppedSharing: {
                cachedSharePairs.removeValue(forKey: id)
                Task { await sharedShoppingListManager.refreshSharedLists() }
            }
        )
    }

    private func sharedAnchorRow(_ anchor: CKRecord) -> some View {
        let id      = anchor.recordID
        let name    = sharedShoppingListManager.namesByAnchorID[id]  ?? (anchor["name"]  as? String ?? "Shared Shopping List")
        let emoji   = sharedShoppingListManager.emojisByAnchorID[id] ?? (anchor["emoji"] as? String ?? "🛒")
        let expanded = expandedSharedAnchors.contains(id)

        let itemCount = (sharedItemsByAnchorID[id] ?? sharedShoppingListManager.itemsDetailed(for: anchor)).count

        // Card header (SharedListSharingViews.swift): identity opens the
        // members sheet, the people button is the invite shortcut, the
        // chevron expands the items.
        return SharedListCardHeader(
            emoji: emoji,
            name: name,
            isOwner: sharedShoppingListManager.isOwnerCached(for: anchor),
            itemCount: itemCount,
            totalText: sharedTotalsByAnchorID[id],
            notHereCount: inStoreAvailability.counts(for: (sharedItemsByAnchorID[id] ?? []).map(\.id)).notHere,
            isExpanded: expanded,
            isLoading: isLoadingManagement == id,
            onOpenManage: { openSharedListManagement(for: anchor) },
            onToggleExpand: { toggleSharedAnchor(anchor) }
        )
    }

    /// Opens the members / sharing sheet for a list, using the cached share
    /// pair when there is one so it appears instantly.
    private func openSharedListManagement(for anchor: CKRecord) {
        let anchorID = anchor.recordID
        guard isLoadingManagement == nil else { return }

        if let cached = cachedSharePairs[anchorID] {
            activeShareSheet = cached
            return
        }

        isLoadingManagement = anchorID
        Task {
            do {
                let pair = try await sharedShoppingListManager.ensureSharePair(for: anchor)
                await MainActor.run {
                    cachedSharePairs[anchorID] = pair
                    activeShareSheet = pair
                    isLoadingManagement = nil
                }
            } catch {
                print("[ShoppingListView] Failed to load management: \(error)")
                await MainActor.run {
                    isLoadingManagement = nil
                    errorMessage = "Failed to load sharing details. Try again."
                    showError = true
                }
            }
        }
    }

    @ViewBuilder
    private func sharedItemRows(for anchor: CKRecord) -> some View {
        let id    = anchor.recordID
        // Greyed (not sold here) rows sink to the bottom of this list only.
        let items = inStoreAvailability.sinkingGreyed(sharedItemsByAnchorID[id] ?? [])

        if items.isEmpty {
            Text("No items")
                .font(NotepadTheme.noteFont(.body))
                .foregroundStyle(NotepadTheme.fadedInk(colorScheme))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.leading, NotepadTheme.marginWidth + 24)
                .notepadRow()
        } else {
            ForEach(items, id: \.id) { it in
                let isChecked = checkedSharedItemIDs.contains(it.id)

                // Same notepad row as Mine, indented under the list heading.
                HStack(spacing: 12) {
                    NotepadCheckbox(isChecked: isChecked) {
                        toggleSharedItemCheck(anchor: anchor, item: it)
                    }
                    .frame(width: NotepadTheme.marginWidth)

                    ShoppingItemImageView(
                        name: it.name,
                        quantity: it.quantity,
                        unit: it.unit,
                        offer: bestOfferByItemID[it.id]
                    )
                    .padding(.leading, 12)

                    // ✅ Product Details (matching "mine" section)
                    Button {
                        // Same detail sheet as personal items; delete routes to the shared list.
                        shoppingDetail = ShoppingDetailSelection(item: shoppingItem(from: it), sharedAnchor: anchor)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            notepadItemName(sharedShorthandDisplay(it), isChecked: isChecked)

                            HStack(spacing: 8) {
                                badgesForSharedItem(it)
                            }

                            // ✅ Store availability info (matching "mine" section)
                            availabilityAwarePriceInfo(id: it.id, name: it.name)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                .opacity(isChecked ? 0.65 : 1)
                // Same in-store treatment as Mine rows.
                .inStoreGreyed(inStoreAvailability.isGreyed(it.id))
                .padding(.trailing, 16)
                .notepadRow()
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    inStoreCorrectionButtons(itemName: it.name, id: it.id)
                }
                // Long-press starts a drag (onto Mine or another shared list). Tap
                // opens the detail sheet where delete lives.
                .draggable(DraggableShoppingItem(from: shoppingItem(from: it)))
            }
        }
    }

    private struct ShareSheetItem: Identifiable {
        let share: CKShare
        let root: CKRecord

        var id: String {
            "\(root.recordID.zoneID.ownerName)|\(root.recordID.zoneID.zoneName)|\(root.recordID.recordName)|\(share.recordID.recordName)"
        }
    }

    private func databaseForAnchor(_ anchor: CKRecord) -> CKDatabase {
        let zid = anchor.recordID.zoneID
        if zid.ownerName == CKCurrentUserDefaultName && zid.zoneName == "ShoppingListZone" {
            return sharedShoppingListManager.container.privateCloudDatabase
        }
        return sharedShoppingListManager.container.sharedCloudDatabase
    }

// MARK: - Shared list sheets

    private var addSharedItemSheet: some View {
        NavigationStack {
            // ✅ Use ProductDetailsView with onConfirmStructured callback
            // This callback fires BEFORE any automatic save, preventing dual-list addition
            ProductDetailsView(
                isShowing: $showAddSharedItemSheet,
                productDetails: OFFProduct(
                    code: nil,
                    productName: "",
                    ingredientsText: "",
                    quantity: "",
                    imageUrl: nil,
                    nutriments: nil
                ),
                context: .shopping, // Use .shopping for UI behavior (shows "Shopping" location option)
                onConfirmStructured: { name, quantity, unit in
                    guard let anchor = addTargetAnchor else {
                        showAddSharedItemSheet = false
                        addTargetAnchor = nil
                        return
                    }
                    
                    let productName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !productName.isEmpty else {
                        showAddSharedItemSheet = false
                        addTargetAnchor = nil
                        return
                    }
                    
                    // ✅ IMMEDIATELY update local state for instant UI (don't wait for CloudKit)
                    let id = anchor.recordID
                    var current = sharedItemsByAnchorID[id] ?? sharedShoppingListManager.itemsDetailed(for: anchor)
                    
                    // Create new item from ProductDetailsView result
                    let newItem = SharedShoppingListItem(
                        name: productName,
                        quantity: quantity.trimmingCharacters(in: .whitespacesAndNewlines),
                        unit: unit.trimmingCharacters(in: .whitespacesAndNewlines),
                        location: "Store",
                        dietaryTags: [] // Could extract from product if available
                    )
                    
                    current.append(newItem)
                    
                    // ✅ Update UI state IMMEDIATELY (synchronous, instant)
                    sharedItemsByAnchorID[id] = current
                    
                    // Auto-expand the list so you can see the new item
                    expandedSharedAnchors.insert(id)
                    
                    // Dismiss sheet immediately
                    showAddSharedItemSheet = false
                    addTargetAnchor = nil
                    
                    print("[ShoppingListView] ✅ Added '\(productName)' to shared list ONLY (local)")
                    
                    // ✅ Upload to CloudKit in BACKGROUND (async, non-blocking)
                    Task {
                        guard await saveSharedEdit(current, for: anchor) else { return }
                        print("[ShoppingListView] ☁️ Uploaded '\(productName)' to CloudKit")
                        
                        // ✅ Post notification for other users
                        await notifySharedListChanged(for: anchor)
                        
                        // ✅ Search for store availability for the newly added item
                        searchStockAvailability(for: newItem)
                        
                        // ✅ Recompute total for the shared list
                        await computeSharedTotal(for: anchor)
                    }
                }
            )
            .environmentObject(frydgeManager)
            .environmentObject(shoppingListManager)
        }
    }

    /// Expands a recipe's ingredients into the currently-targeted shared shopping
    /// list, appending to whatever is already there and syncing to CloudKit.
    private func addRecipeToSharedList(_ recipe: CloudRecipe) {
        guard let anchor = addTargetAnchor else { return }
        let id = anchor.recordID

        var current = sharedItemsByAnchorID[id] ?? sharedShoppingListManager.itemsDetailed(for: anchor)
        let existingNames = Set(current.map { $0.name.lowercased() })

        var added = 0
        for raw in recipe.ingredients {
            let parsed = RecipeIngredientParser.parse(raw)
            guard !parsed.name.isEmpty, !existingNames.contains(parsed.name.lowercased()) else { continue }
            current.append(
                SharedShoppingListItem(
                    name: parsed.name,
                    quantity: parsed.quantity,
                    unit: parsed.unit,
                    location: "Store",
                    dietaryTags: []
                )
            )
            added += 1
        }

        guard added > 0 else { return }

        // Instant UI, then background sync (mirrors the single-item add path).
        sharedItemsByAnchorID[id] = current
        expandedSharedAnchors.insert(id)

        Task {
            guard await saveSharedEdit(current, for: anchor) else { return }
            await notifySharedListChanged(for: anchor)
            await computeSharedTotal(for: anchor)
        }
    }

    /// Glass create flow (SharedListSharingViews.swift): icon picker, name,
    /// quick picks, then straight into the invite sheet.
    private var createSharedListSheet: some View {
        CreateSharedListSheet(
            name: $newSharedListName,
            emoji: $newSharedListEmoji,
            isCreating: isCreatingList,
            onCreate: { createList() },
            onCancel: {
                showCreateSharedListSheet = false
                newSharedListName = ""
                newSharedListEmoji = "🛒"
            }
        )
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
    
    // ✅ Extracted create function for reusability
    private func createList() {
        let name = newSharedListName.trimmingCharacters(in: .whitespacesAndNewlines)
        let emoji = newSharedListEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isCreatingList else { return }

        isCreatingList = true

        Task {
            do {
                // ✅ Create the list in CloudKit
                let anchor = try await sharedShoppingListManager.createShoppingListAnchor(
                    named: name,
                    emoji: emoji.isEmpty ? "🛒" : emoji
                )
                
                print("[ShoppingListView] ✅ Anchor created: \(anchor.recordID.recordName)")
                print("[ShoppingListView] ✅ Manager now has \(sharedShoppingListManager.anchors.count) anchors")
                
                // ✅ Create the share pair immediately
                let sharePair = try await sharedShoppingListManager.ensureSharePair(for: anchor)
                
                await MainActor.run {
                    // ✅ IMMEDIATELY add the new anchor to local state (don't wait for refresh)
                    sharedItemsByAnchorID[anchor.recordID] = []
                    
                    // Auto-expand the newly created list
                    expandedSharedAnchors.insert(anchor.recordID)
                    
                    // Cache the share pair for instant loading
                    cachedSharePairs[anchor.recordID] = sharePair
                    
                    // Reset form and dismiss creation sheet
                    newSharedListName = ""
                    newSharedListEmoji = "🛒"
                    isCreatingList = false
                    showCreateSharedListSheet = false
                    
                    print("[ShoppingListView] ✅ Created and expanded list: \(name)")
                    
                    // ✅ Mark that we should NOT auto-refresh for at least 60 seconds
                    // This prevents the newly created list from being removed by a query that hasn't indexed it yet
                    UserDefaults.standard.set(Date().addingTimeInterval(60), forKey: lastSharedRefreshKey)
                    
                    // ✅ AUTO-OPEN the management/sharing screen
                    activeShareSheet = sharePair
                }
                
                // ✅ Schedule a delayed refresh after CloudKit has time to index (2 minutes)
                Task {
                    try? await Task.sleep(nanoseconds: 120_000_000_000) // 120 seconds
                    print("[ShoppingListView] 🔄 Performing delayed refresh after list creation")
                    await sharedShoppingListManager.refreshSharedLists()
                }
                
                print("[ShoppingListView] ✅ Creation complete, scheduled delayed refresh")
                
            } catch {
                print("[ShoppingListView] Failed to create list: \(error)")
                await MainActor.run {
                    isCreatingList = false
                    errorMessage = "Failed to create list: \(error.localizedDescription)"
                    showError = true
                }
            }
        }
    }

    // MARK: - Helpers / reusable

    private func badgesForShoppingItem(_ item: ShoppingListItem) -> some View {
        HStack(spacing: 6) {
            let tags = Set(item.dietaryTags.map { $0.uppercased() })
            if tags.contains("DF") { DietaryBadgeChip(tag: "DF", tone: .brand) }
            if tags.contains("GF") { DietaryBadgeChip(tag: "GF", tone: .brand) }
            if tags.contains("V")  { DietaryBadgeChip(tag: "V", tone: .brand) }
        }
    }
    private func badgesForSharedItem(_ item: SharedShoppingListItem) -> some View {
        HStack(spacing: 6) {
            let tags = Set(item.dietaryTags.map { $0.uppercased() })
            if tags.contains("DF") { DietaryBadgeChip(tag: "DF", tone: .brand) }
            if tags.contains("GF") { DietaryBadgeChip(tag: "GF", tone: .brand) }
            if tags.contains("V")  { DietaryBadgeChip(tag: "V", tone: .brand) }
        }
    }

    private func sizeString(_ it: SharedShoppingListItem) -> String? {
        let parts = [it.quantity, it.unit]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parts.isEmpty { return nil }
        if it.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "x\(it.quantity.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return parts.joined(separator: " ")
    }
    private func shoppingItem(from sharedItem: SharedShoppingListItem) -> ShoppingListItem {
        // Preserve the id so drag payloads and the detail sheet's delete can match
        // this back to the shared item it came from.
        ShoppingListItem(
            id: sharedItem.id,
            name: sharedItem.name,
            quantity: sharedItem.quantity,
            unit: sharedItem.unit,
            location: sharedItem.location,
            dietaryTags: Set(sharedItem.dietaryTags)
        )
    }

    private func normKey(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    // MARK: - Actions

    private func onAppear() {
        print("[ShoppingListView] ⏰ onAppear started")
        showInvitationsSheet = !pendingInvites.metas.isEmpty
        let arr = UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []
        dismissedAutoItems = Set(arr.map { normKey($0) })

        frydgeManager.loadStoredIngredientsFromFile()
        print("[ShoppingListView] ✅ Loaded ingredients from file")

        Task { @MainActor in
            print("[ShoppingListView] 🌐 Starting network operations...")
            await frydgeManager.syncFromCloud()
            print("[ShoppingListView] ✅ Frydge synced from cloud")
            
            frydgeManager.loadFridgeData()
            print("[ShoppingListView] ✅ Fridge data loaded")
            
            await shoppingListManager.syncFromCloud()
            print("[ShoppingListView] ✅ Shopping list synced from cloud")
            
            loadRooms()
            print("[ShoppingListView] ✅ Rooms loaded")

            // Start local item searches and image warming immediately.
            prewarmMineStoreVisuals()
            print("[ShoppingListView] ✅ Store visuals prewarmed")

            // ✅ Only refresh shared lists if we don't have any locally (first launch)
            // or if it's been more than 30 seconds since last refresh
            let shouldRefresh = sharedShoppingListManager.anchors.isEmpty || shouldPerformSharedListRefresh()
            if shouldRefresh {
                await sharedShoppingListManager.refreshSharedLists()
                print("[ShoppingListView] ✅ Shared lists refreshed - found \(sharedShoppingListManager.anchors.count) lists")
                recordSharedListRefresh()
            } else {
                print("[ShoppingListView] ⏭️ Skipping shared list refresh (too soon) - showing \(sharedShoppingListManager.anchors.count) cached lists")
            }
            
            await primeStoreDrivenUIOnLoad()

            await loadSuggestions()
            print("[ShoppingListView] ✅ onAppear complete")
        }
    }

    @available(iOS 26.0, *)
    private func loadSuggestions() async {
        guard !isLoadingSuggestions else { return }
        isLoadingSuggestions = true
        let fridgeNames = frydgeManager.storedIngredients.map(\.name)
            + frydgeManager.ingredients
        let listedNames = shoppingListManager.shoppingListItems.map(\.name)
        let results = await ShoppingSuggestionService.shared.suggestions(
            recipes: recipeListModel.recipes,
            fridgeItems: fridgeNames,
            alreadyOnList: listedNames
        )
        shoppingSuggestions = results
        isLoadingSuggestions = false
    }

    // MARK: - Refresh throttling helpers
    
    private let lastSharedRefreshKey = "lastSharedListRefreshTimestamp"
    private let minimumRefreshInterval: TimeInterval = 2 // 2 seconds (reduced from 30 to fix UI flicker)
    
    private func shouldPerformSharedListRefresh() -> Bool {
        guard let lastRefresh = UserDefaults.standard.object(forKey: lastSharedRefreshKey) as? Date else {
            return true // Never refreshed before
        }
        let timeSince = Date().timeIntervalSince(lastRefresh)
        if timeSince > minimumRefreshInterval {
            return true
        } else {
            print("[ShoppingListView] ⏭️ Throttled: Last refresh was \(Int(timeSince))s ago (minimum: \(Int(minimumRefreshInterval))s)")
            return false
        }
    }
    
    private func recordSharedListRefresh() {
        UserDefaults.standard.set(Date(), forKey: lastSharedRefreshKey)
    }
    
    // ✅ Pull-to-refresh handler - refreshes both mine and shared lists
    private func performFullRefresh() async {
        print("[ShoppingListView] 🔄 Full refresh started")
        
        // Refresh "mine" list from CloudKit
        print("[ShoppingListView] 🔄 Syncing personal shopping list...")
        await shoppingListManager.syncFromCloud()
        
        // Refresh shared lists from CloudKit
        print("[ShoppingListView] 🔄 Syncing shared shopping lists...")
        await sharedShoppingListManager.refreshSharedLists()
        
        // Refresh store pricing/availability data
        print("[ShoppingListView] 🔄 Refreshing store data...")
        await refreshStoreDrivenUI()
        
        // Record the refresh time
        recordSharedListRefresh()
        
        print("[ShoppingListView] ✅ Full refresh complete")
    }

    private func onItemsChanged(_ old: [ShoppingListItem], _ newItems: [ShoppingListItem]) {
        let existing = Set(newItems.map { $0.id })
        checkedItems = checkedItems.intersection(existing)

        // An item deleted (swipe, sync, move to a shared list) while its tick
        // was still in the grace period must not be "purchased" into the fridge
        // when the timer fires, and its Undo toast is now meaningless. Only ids
        // that were on the Mine list are considered, so pending shared-list
        // ticks are left alone.
        let removed = Set(old.map { $0.id }).subtracting(existing)
        for id in removed {
            guard let task = pendingTickTasks.removeValue(forKey: id) else { continue }
            task.cancel()
            if tickToast?.itemID == id, tickToast?.committed == false {
                withAnimation { tickToast = nil }
            }
        }

        for item in newItems { searchStockAvailability(for: item) }
        
        // ✅ Recompute recommended store when items change
        Task {
            await computeRecommendedStore()
        }
    }

    private func prewarmMineStoreVisuals() {
        for item in shoppingItems {
            searchStockAvailability(for: item)
        }
    }

    private func primeStoreDrivenUIOnLoad() async {
        // Always let StockAvailability pull the freshest device coordinate when available.
        StockAvailability.currentLocationProvider = {
            resolvedCurrentCoordinate()
        }

        // First pass: immediate load using whatever coordinate is already available.
        await refreshStoreDrivenUI()

        // Second pass: shortly after load, so the first resolved location can update nearest-store results.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await refreshStoreDrivenUI()
    }

    private func refreshStoreDrivenUI() async {
        queriedItems.removeAll()
        stockAvailability.removeAll()
        bestOfferByItemID.removeAll()
        inStoreAvailability.reset()

        let mineItems = shoppingItems
        let anchors = sharedShoppingListManager.anchors
        var sharedSnapshot: [(anchor: CKRecord, items: [SharedShoppingListItem])] = []
        sharedSnapshot.reserveCapacity(anchors.count)

        // First priority: kick off store searches for everything so rows can populate fast.
        for item in mineItems {
            searchStockAvailability(for: item)
        }

        for anchor in anchors {
            let id = anchor.recordID
            let items = sharedShoppingListManager.itemsDetailed(for: anchor)
            sharedItemsByAnchorID[id] = items
            sharedSnapshot.append((anchor, items))

            for item in items {
                searchStockAvailability(for: item)
            }
        }

        // Secondary work: totals and recommendation can happen after the row searches are underway.
        await withTaskGroup(of: Void.self) { group in
            for snapshot in sharedSnapshot {
                group.addTask {
                    await computeSharedTotal(for: snapshot.anchor)
                }
            }

            group.addTask {
                await computeRecommendedStore()
            }
        }
    }
    private func resolvedCurrentCoordinate() -> CLLocationCoordinate2D? {
        if let coordinate = extractCoordinate(from: locationManager) {
            return coordinate
        }

        if let coordinate = extractCoordinate(from: geoLocationManager) {
            return coordinate
        }

        return nil
    }

    private func extractCoordinate(from source: Any) -> CLLocationCoordinate2D? {
        let directCoordinateKeys: Set<String> = [
            "currentCoordinate", "coordinate", "lastCoordinate", "userCoordinate"
        ]
        let locationKeys: Set<String> = [
            "location", "currentLocation", "lastLocation", "userLocation"
        ]

        for child in Mirror(reflecting: source).children {
            guard let label = child.label else { continue }
            let value = unwrapOptional(child.value)

            if directCoordinateKeys.contains(label),
               let coordinate = value as? CLLocationCoordinate2D {
                return coordinate
            }

            if locationKeys.contains(label),
               let location = value as? CLLocation {
                return location.coordinate
            }
        }

        return nil
    }

    private func unwrapOptional(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        return mirror.children.first?.value
    }

    private func openItemLookup(for item: ShoppingListItem) {
        lookupItem = item
        showItemLookupSheet = true
    }

    private func openAvailabilityOptions(for item: ShoppingListItem) {
        pendingAvailabilityItem = item
        pendingAvailabilityName = item.name
        pendingAvailabilityQuantity = item.quantity
        pendingAvailabilityUnit = item.unit
        showAvailabilityOptionsSheet = true
    }

    private func toggleSharedAnchor(_ anchor: CKRecord) {
        let id = anchor.recordID
        if expandedSharedAnchors.contains(id) {
            expandedSharedAnchors.remove(id)
        } else {
            expandedSharedAnchors.insert(id)
            if sharedItemsByAnchorID[id] == nil {
                let items = sharedShoppingListManager.itemsDetailed(for: anchor)
                sharedItemsByAnchorID[id] = items
                for it in items { searchStockAvailability(for: it) }
                Task { await computeSharedTotal(for: anchor) }
            }
        }
    }

    private func toggleCheckmark(for item: ShoppingListItem) {
        // Tapping a ticked (still pending) row is the quickest undo.
        if pendingTickTasks[item.id] != nil {
            undoTick(itemID: item.id)
            return
        }

        beginTick(itemID: item.id, name: item.name, mark: { checkedItems.insert(item.id) }) {
            await shoppingListManager.purchaseItem(item.id, into: frydgeManager)
            ActivityManager.updateActivity(checkedItem: item.name)
            checkedItems.remove(item.id)
            let key = normKey(item.name)
            if dismissedAutoItems.contains(key) {
                dismissedAutoItems.remove(key)
                UserDefaults.standard.set(Array(dismissedAutoItems), forKey: dismissedKey)
            }
        }
    }

    private func toggleSharedItemCheck(anchor: CKRecord, item: SharedShoppingListItem) {
        if pendingTickTasks[item.id] != nil {
            undoTick(itemID: item.id)
            return
        }

        beginTick(itemID: item.id, name: item.name, mark: { checkedSharedItemIDs.insert(item.id) }) {
            // Remove from the shared list
            let id = anchor.recordID
            var current = sharedItemsByAnchorID[id] ?? sharedShoppingListManager.itemsDetailed(for: anchor)
            current.removeAll { $0.id == item.id }

            // Update UI immediately
            sharedItemsByAnchorID[id] = current
            checkedSharedItemIDs.remove(item.id)

            // Upload to CloudKit in background; only add to the personal frydge
            // inventory once the removal is saved, so a failed save can't leave
            // the item both on the shared list and in the inventory.
            Task {
                guard await saveSharedEdit(current, for: anchor) else { return }
                frydgeManager.addToInventory(item.name)

                // ✅ Notify other users
                await notifySharedListChanged(for: anchor)

                await computeSharedTotal(for: anchor)
            }
        }
    }

    // MARK: Tick grace period

    /// Marks the row straight away, shows the undo toast, and only runs `commit`
    /// (the real move into the fridge) once the grace period passes untouched.
    private func beginTick(
        itemID: UUID,
        name: String,
        mark: () -> Void,
        commit: @escaping @MainActor () async -> Void
    ) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            mark()
            tickToast = TickToast(itemID: itemID, name: name)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        pendingTickTasks[itemID] = Task { @MainActor in
            try? await Task.sleep(for: tickGracePeriod)
            guard !Task.isCancelled else { return }
            pendingTickTasks[itemID] = nil

            await commit()

            // Flip the toast to "moved to your frydge" briefly, then fade it out.
            guard tickToast?.itemID == itemID else { return }
            withAnimation { tickToast?.committed = true }
            try? await Task.sleep(for: .seconds(1.5))
            if tickToast?.itemID == itemID {
                withAnimation { tickToast = nil }
            }
        }
    }

    /// Cancels a pending tick and puts the row back exactly as it was.
    private func undoTick(itemID: UUID) {
        pendingTickTasks[itemID]?.cancel()
        pendingTickTasks[itemID] = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            checkedItems.remove(itemID)
            checkedSharedItemIDs.remove(itemID)
            if tickToast?.itemID == itemID { tickToast = nil }
        }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    /// Changes whenever a row is added or removed anywhere on the page.
    private var listAnimationToken: Int {
        shoppingItems.count + sharedItemsByAnchorID.values.reduce(0) { $0 + $1.count }
    }

    /// Sticky-note toast at the foot of the page with an Undo button while the
    /// tick is still pending.
    @ViewBuilder
    private var tickUndoToast: some View {
        if let toast = tickToast {
            HStack(spacing: 10) {
                Image(systemName: toast.committed ? "refrigerator" : "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(toast.committed ? Color.blue : Color.green)

                Text(toast.committed ? "\(toast.name) moved to your frydge" : "Ticked off \(toast.name)")
                    .font(NotepadTheme.noteFont(.subheadline, weight: .medium))
                    .foregroundStyle(NotepadTheme.ink(colorScheme))
                    .lineLimit(1)

                Spacer(minLength: 4)

                if !toast.committed {
                    Button {
                        undoTick(itemID: toast.itemID)
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel("Undo ticking off \(toast.name)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .notepadGlass(cornerRadius: 22)
            .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 6)
            .padding(.horizontal, 16)
            // Clears the floating tab bar.
            .padding(.bottom, 96)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func deleteSharedItem(_ item: SharedShoppingListItem, from anchor: CKRecord) async {
        let id = anchor.recordID
        var current = sharedItemsByAnchorID[id] ?? sharedShoppingListManager.itemsDetailed(for: anchor)
        current.removeAll { $0.id == item.id }
        
        // ✅ Update UI IMMEDIATELY (synchronous, instant)
        await MainActor.run {
            sharedItemsByAnchorID[id] = current
            checkedSharedItemIDs.remove(item.id)
        }
        
        // ✅ Upload to CloudKit in BACKGROUND (async, non-blocking)
        Task {
            guard await saveSharedEdit(current, for: anchor) else { return }
            print("[ShoppingListView] ☁️ Deleted item from CloudKit")
            
            // ✅ Notify other users
            await notifySharedListChanged(for: anchor)
            
            await computeSharedTotal(for: anchor)
        }
    }

    private func moveSelectedItems(to anchor: CKRecord) async {
        let ids = selectedMoveIDs
        guard !ids.isEmpty else { return }
        let selected = shoppingItems.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return }

        var detailed = sharedShoppingListManager.itemsDetailed(for: anchor)
        for s in selected {
            detailed.append(SharedShoppingListItem(
                name: s.name, quantity: s.quantity, unit: s.unit,
                location: s.location, dietaryTags: Array(s.dietaryTags)
            ))
        }
        
        // ✅ Update UI IMMEDIATELY (synchronous, instant)
        await MainActor.run {
            // Remove from personal list
            for id in ids { shoppingListManager.removeFromShoppingList(id: id) }
            
            // Add to dismissed auto-items
            for s in selected { dismissedAutoItems.insert(normKey(s.name)) }
            UserDefaults.standard.set(Array(dismissedAutoItems), forKey: dismissedKey)
            
            // Update shared list UI
            sharedItemsByAnchorID[anchor.recordID] = detailed
            
            // Clear selection
            selectedMoveIDs.removeAll()
            isSelectingToMove = false
            
            print("[ShoppingListView] ✅ Moved \(selected.count) items (local)")
        }
        
        // ✅ Upload to CloudKit in BACKGROUND (async, non-blocking)
        Task {
            let saved = await sharedShoppingListManager.setItemsDetailed(detailed, for: anchor)
            guard saved else {
                // Upload failed (offline, read-only share): put the items back.
                await MainActor.run {
                    restoreFailedMove(selected, to: anchor)
                }
                return
            }
            print("[ShoppingListView] ☁️ Uploaded moved items to CloudKit")

            // ✅ Notify other users
            await notifySharedListChanged(for: anchor)
            
            // Search for availability for moved items
            for item in detailed {
                searchStockAvailability(for: item)
            }
            
            await computeSharedTotal(for: anchor)
        }
    }

    /// Moves a single personal item into a shared list (long-press "Move to…" path).
    /// Mirrors `moveSelectedItems` but for one item, so a press-and-hold move works
    /// without entering multi-select move mode.
    private func moveShoppingItem(_ item: ShoppingListItem, to anchor: CKRecord) {
        var detailed = sharedShoppingListManager.itemsDetailed(for: anchor)
        detailed.append(SharedShoppingListItem(
            name: item.name, quantity: item.quantity, unit: item.unit,
            location: item.location, dietaryTags: Array(item.dietaryTags)
        ))

        // Update UI immediately (instant), upload in the background.
        shoppingListManager.removeFromShoppingList(id: item.id)
        dismissedAutoItems.insert(normKey(item.name))
        UserDefaults.standard.set(Array(dismissedAutoItems), forKey: dismissedKey)
        sharedItemsByAnchorID[anchor.recordID] = detailed

        Task {
            let saved = await sharedShoppingListManager.setItemsDetailed(detailed, for: anchor)
            guard saved else {
                restoreFailedMove([item], to: anchor)
                return
            }
            await notifySharedListChanged(for: anchor)
            for it in detailed { searchStockAvailability(for: it) }
            await computeSharedTotal(for: anchor)
        }
    }

    /// Saves an optimistic edit to a shared list. If CloudKit rejects it (offline,
    /// read-only share) the UI is put back to what the server still has and the
    /// user is told, instead of showing a change that was never saved.
    @discardableResult
    private func saveSharedEdit(_ items: [SharedShoppingListItem], for anchor: CKRecord) async -> Bool {
        let saved = await sharedShoppingListManager.setItemsDetailed(items, for: anchor)
        if !saved {
            await MainActor.run {
                sharedItemsByAnchorID[anchor.recordID] = sharedShoppingListManager.itemsDetailed(for: anchor)
                appState.showBanner(
                    title: "Not saved",
                    message: sharedShoppingListManager.lastError ?? "The shared list wasn't updated.",
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
        return saved
    }

    /// A move into a shared list didn't reach CloudKit: bring the items back to the
    /// personal list and show the shared list as the server still has it.
    private func restoreFailedMove(_ items: [ShoppingListItem], to anchor: CKRecord) {
        for it in items {
            shoppingListManager.addToShoppingList(
                name: it.name,
                quantity: it.quantity,
                unit: it.unit,
                location: it.location,
                dietaryTags: it.dietaryTags
            )
            dismissedAutoItems.remove(normKey(it.name))
        }
        UserDefaults.standard.set(Array(dismissedAutoItems), forKey: dismissedKey)
        sharedItemsByAnchorID[anchor.recordID] = sharedShoppingListManager.itemsDetailed(for: anchor)
        appState.showBanner(
            title: "Couldn't move",
            message: sharedShoppingListManager.lastError ?? "The shared list wasn't updated, so your items were kept.",
            systemImage: "exclamationmark.triangle"
        )
    }

    /// Moves a shared-list item back into the user's own list (long-press path).
    /// Removes it from the shared list's JSON and adds it to the personal list.
    private func moveSharedItemToPersonal(_ item: SharedShoppingListItem, from anchor: CKRecord) {
        var detailed = sharedShoppingListManager.itemsDetailed(for: anchor)
        detailed.removeAll { $0.id == item.id }

        // Update the shared list UI immediately, upload in the background, and only
        // add to the personal list once the removal is saved — otherwise a failed
        // upload leaves the item in both lists.
        sharedItemsByAnchorID[anchor.recordID] = detailed
        checkedSharedItemIDs.remove(item.id)

        Task {
            let saved = await sharedShoppingListManager.setItemsDetailed(detailed, for: anchor)
            guard saved else {
                sharedItemsByAnchorID[anchor.recordID] = sharedShoppingListManager.itemsDetailed(for: anchor)
                appState.showBanner(
                    title: "Couldn't move",
                    message: sharedShoppingListManager.lastError ?? "The shared list wasn't updated.",
                    systemImage: "exclamationmark.triangle"
                )
                return
            }
            shoppingListManager.addToShoppingList(
                name: item.name,
                quantity: item.quantity,
                unit: item.unit,
                location: item.location.isEmpty ? "Store" : item.location,
                dietaryTags: Set(item.dietaryTags)
            )
            await notifySharedListChanged(for: anchor)
            await computeSharedTotal(for: anchor)
        }
    }

    /// Moves a shared-list item from one shared list into another (long-press path).
    private func moveSharedItemBetween(_ item: SharedShoppingListItem, from src: CKRecord, to dst: CKRecord) {
        guard src.recordID != dst.recordID else { return }

        var srcItems = sharedShoppingListManager.itemsDetailed(for: src)
        srcItems.removeAll { $0.id == item.id }
        var dstItems = sharedShoppingListManager.itemsDetailed(for: dst)
        dstItems.append(item)

        sharedItemsByAnchorID[src.recordID] = srcItems
        sharedItemsByAnchorID[dst.recordID] = dstItems

        Task {
            // Add to the destination first: if the second save fails the item is
            // duplicated rather than lost.
            let addedToDst = await sharedShoppingListManager.setItemsDetailed(dstItems, for: dst)
            guard addedToDst else {
                sharedItemsByAnchorID[src.recordID] = sharedShoppingListManager.itemsDetailed(for: src)
                sharedItemsByAnchorID[dst.recordID] = sharedShoppingListManager.itemsDetailed(for: dst)
                appState.showBanner(
                    title: "Couldn't move",
                    message: sharedShoppingListManager.lastError ?? "The destination list wasn't updated.",
                    systemImage: "exclamationmark.triangle"
                )
                return
            }
            let removedFromSrc = await sharedShoppingListManager.setItemsDetailed(srcItems, for: src)
            if !removedFromSrc {
                sharedItemsByAnchorID[src.recordID] = sharedShoppingListManager.itemsDetailed(for: src)
            }
            await notifySharedListChanged(for: src)
            await notifySharedListChanged(for: dst)
            await computeSharedTotal(for: src)
            await computeSharedTotal(for: dst)
        }
    }

    // MARK: - Drag-and-drop resolution

    /// Finds which shared list (and item) currently holds a given item id.
    private func sharedSource(for id: UUID) -> (CKRecord, SharedShoppingListItem)? {
        for anchor in sharedShoppingListManager.anchors {
            if let it = (sharedItemsByAnchorID[anchor.recordID] ?? []).first(where: { $0.id == id }) {
                return (anchor, it)
            }
        }
        return nil
    }

    /// A drop onto the Mine section: move any shared-list items back to the personal list.
    private func handleDropToMineShopping(_ dropped: [DraggableShoppingItem]) -> Bool {
        var didMove = false
        for d in dropped {
            if let (anchor, it) = sharedSource(for: d.id) {
                moveSharedItemToPersonal(it, from: anchor)
                didMove = true
            }
        }
        return didMove
    }

    /// A drop onto a shared list: bring in a personal item, or move an item from
    /// another shared list. Items already in this list are ignored.
    private func handleDropToSharedList(_ dropped: [DraggableShoppingItem], anchor: CKRecord) -> Bool {
        var didMove = false
        for d in dropped {
            if let personal = shoppingListManager.shoppingListItems.first(where: { $0.id == d.id }) {
                moveShoppingItem(personal, to: anchor)
                didMove = true
            } else if let (srcAnchor, it) = sharedSource(for: d.id), srcAnchor.recordID != anchor.recordID {
                moveSharedItemBetween(it, from: srcAnchor, to: anchor)
                didMove = true
            }
        }
        return didMove
    }

    private func deleteItem(at offsets: IndexSet) {
        let items = offsets.map { shoppingItems[$0] }
        for it in items { dismissedAutoItems.insert(normKey(it.name)) }
        UserDefaults.standard.set(Array(dismissedAutoItems), forKey: dismissedKey)
        for it in items { shoppingListManager.removeFromShoppingList(id: it.id) }
    }

    private func deleteShoppingItem(_ item: ShoppingListItem) {
        dismissedAutoItems.insert(normKey(item.name))
        UserDefaults.standard.set(Array(dismissedAutoItems), forKey: dismissedKey)
        shoppingListManager.removeFromShoppingList(id: item.id)
    }

    private func loadRooms() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(roomsFileName)
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Room].self, from: data) {
            rooms = decoded
        }
    }

    // MARK: - Stock availability

    private func searchStockAvailability(for item: ShoppingListItem) {
        searchStockAvailability(id: item.id, name: item.name, quantity: item.quantity, unit: item.unit)
    }

    private func searchStockAvailability(for item: SharedShoppingListItem) {
        searchStockAvailability(id: item.id, name: item.name, quantity: item.quantity, unit: item.unit)
    }

    private func searchStockAvailability(id: UUID, name: String, quantity: String, unit: String) {
        guard !queriedItems.contains(id) else { return }
        queriedItems.insert(id)
        stockAvailability[id] = nil
        bestOfferByItemID[id] = nil

        // Includes the item's already-pack-sized quantity/unit so GroceryQueryBuilder
        // can extract a size hint and ProductMatcher favors the offer whose pack size
        // actually matches what's needed, not just any product with a matching name.
        let query = GroceryQueryBuilder.sizeAwareQuery(name: name, quantity: quantity, unit: unit)

        Task {
            // Every chain's offers, not just the cheapest: the in-store model
            // needs to know which stores list the item. If the user has a
            // preferred product for it, that one still wins the "best" slot.
            let fetched = await StockAvailability.fetchAllOffers(for: query)
            let offers = fetched.preferred.map { [$0] } ?? fetched.offers
            await MainActor.run {
                inStoreAvailability.record(
                    id: id,
                    name: name,
                    offers: fetched.offers,
                    usedPreferredShortcut: fetched.preferred != nil && fetched.offers.isEmpty
                )
            }
            let best = offers
                .map { RetailOffer(from: $0) }
                .sorted {
                    switch ($0.numericPrice, $1.numericPrice) {
                    case let (l?, r?): return l != r ? l < r : $0.storeName < $1.storeName
                    case (_?, nil):    return true
                    case (nil, _?):    return false
                    default:           return $0.storeName < $1.storeName
                    }
                }
                .first

            if let best {
                await ProductImageCacheManager.shared.updateFromRemoteURLString(
                    best.imageURL?.absoluteString,
                    name: name,
                    quantity: "",
                    unit: "",
                    productName: best.productTitle ?? name,
                    storeName: best.storeName
                )
            }

            await MainActor.run {
                if let best {
                    bestOfferByItemID[id] = best
                    stockAvailability[id] = true
                } else {
                    stockAvailability[id] = false
                }
            }
        }
    }

    /// The offers a row would show for this item, fetched with the same
    /// size-aware query the row uses. Totals and the recommended store used
    /// to look items up by bare name, which is a different cache key, so
    /// every item cost a second (and for shared lists a third) worker call
    /// per refresh. Sharing the query means these join the row's in-flight
    /// request or hit its cache instead.
    private func rowOffers(name: String, quantity: String, unit: String) async -> [StockAvailability.StoreOffer] {
        let query = GroceryQueryBuilder.sizeAwareQuery(name: name, quantity: quantity, unit: unit)
        let fetched = await StockAvailability.fetchAllOffers(for: query)
        return fetched.preferred.map { [$0] } ?? fetched.offers
    }

    // MARK: - Recommended store

    private func computeRecommendedStore() async {
        var aggregates: [String: (count: Int, lowestPrice: Double?, currency: String, total: Double)] = [:]

        // ✅ Collect all items from both "Mine" and all shared lists
        var allItems: [(id: UUID, name: String, quantity: String, unit: String)] = []

        // Add items from "Mine" list
        for item in shoppingItems {
            allItems.append((id: item.id, name: item.name, quantity: item.quantity, unit: item.unit))
        }

        // Add items from all shared lists
        for anchor in sharedShoppingListManager.anchors {
            let sharedItems = sharedShoppingListManager.itemsDetailed(for: anchor)
            for item in sharedItems {
                allItems.append((id: item.id, name: item.name, quantity: item.quantity, unit: item.unit))
            }
        }

        // If no items at all, clear recommendation
        guard !allItems.isEmpty else {
            await MainActor.run { recommendedStore = nil }
            return
        }

        // Compute best store across all items
        for item in allItems {
            let offers = await rowOffers(name: item.name, quantity: item.quantity, unit: item.unit)
            var perItemMin: [String: (price: Double, currency: String)] = [:]
            for o in offers {
                guard let price = o.price else { continue }
                if let existing = perItemMin[o.store] {
                    if price < existing.price { perItemMin[o.store] = (price, o.currencyCode) }
                } else {
                    perItemMin[o.store] = (price, o.currencyCode)
                }
            }
            for (store, min) in perItemMin {
                var agg = aggregates[store] ?? (0, nil, min.currency, 0)
                agg.count += 1
                agg.lowestPrice = agg.lowestPrice.map { Swift.min($0, min.price) } ?? min.price
                if agg.currency.isEmpty { agg.currency = min.currency }
                agg.total += min.price
                aggregates[store] = agg
            }
        }

        guard let best = aggregates.max(by: { $0.value.count < $1.value.count }) else {
            await MainActor.run { recommendedStore = nil }
            return
        }

        let code = best.value.currency
        func fmt(_ v: Double?) -> String? {
            guard let v else { return nil }
            let f = NumberFormatter()
            f.numberStyle = .currency
            f.currencyCode = code.isEmpty ? (Locale.current.currency?.identifier ?? "NZD") : code
            f.maximumFractionDigits = 2
            f.minimumFractionDigits = v.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2
            return f.string(from: NSNumber(value: v))
        }

        await MainActor.run {
            recommendedStore = (
                name: best.key,
                priceText: fmt(best.value.lowestPrice),
                totalText: fmt(best.value.total)
            )
        }
    }

    private func computeSharedTotal(for anchor: CKRecord) async {
        let items = sharedShoppingListManager.itemsDetailed(for: anchor)
        var total: Double = 0
        var currency = Locale.current.currency?.identifier ?? "NZD"
        for it in items {
            let offers = await rowOffers(name: it.name, quantity: it.quantity, unit: it.unit)
            if let min = offers.compactMap({ o -> (Double, String)? in
                guard let p = o.price else { return nil }; return (p, o.currencyCode)
            }).min(by: { $0.0 < $1.0 }) {
                total += min.0
                if !min.1.isEmpty { currency = min.1 }
            }
        }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = total.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2
        let formatted = f.string(from: NSNumber(value: total)) ?? ""
        await MainActor.run { sharedTotalsByAnchorID[anchor.recordID] = formatted }
    }
    
    // MARK: - Update shopping list item helper (NEW)
    private func updateShoppingListItem(_ old: ShoppingListItem, with new: OFFProduct) {
        guard let index = shoppingListManager.shoppingListItems.firstIndex(where: { $0.id == old.id }) else {
            return
        }

        var items = shoppingListManager.shoppingListItems
        var updatedItem = items[index]

        let newName = new.productName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? old.name
        updatedItem.name = newName.isEmpty ? old.name : newName

        let newQuantity = new.quantity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? old.quantity
        updatedItem.quantity = newQuantity

        items[index] = updatedItem
        shoppingListManager.shoppingListItems = items
    }
    
    // MARK: - Notification helper for shared list changes
    private func notifySharedListChanged(for anchor: CKRecord) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: Notification.Name("SharedShoppingListChanged"),
                object: nil,
                userInfo: ["anchorID": anchor.recordID.recordName]
            )
        }
    }
}

// MARK: - EditableShoppingProductDetailsSheet

// EditableShoppingProductDetailsSheet: wrapper for editing shopping item product details and saving back
private struct EditableShoppingProductDetailsSheet: View {
    @Binding var isShowing: Bool
    let originalItem: ShoppingListItem?
    let onSave: (ShoppingListItem, OFFProduct) -> Void

    @State private var draftProduct: OFFProduct
    @EnvironmentObject private var frydgeManager: FrydgeManager
    @EnvironmentObject private var shoppingListManager: ShoppingListManager

    init(
        isShowing: Binding<Bool>,
        originalItem: ShoppingListItem?,
        onSave: @escaping (ShoppingListItem, OFFProduct) -> Void
    ) {
        self._isShowing = isShowing
        self.originalItem = originalItem
        self.onSave = onSave

        let seed = originalItem.map { item in
            OFFProduct(
                code: nil,
                productName: item.name,
                ingredientsText: "",
                quantity: item.quantity,
                imageUrl: nil,
                nutriments: nil
            )
        } ?? OFFProduct(
            code: nil,
            productName: "",
            ingredientsText: "",
            quantity: "",
            imageUrl: nil,
            nutriments: nil
        )

        _draftProduct = State(initialValue: seed)
    }

    var body: some View {
        ProductDetailsView(
            isShowing: $isShowing,
            productDetails: draftProduct,
            context: .shopping,
            onConfirm: { updatedProduct in
                guard let originalItem else {
                    isShowing = false
                    return
                }
                onSave(originalItem, updatedProduct)
                isShowing = false
            }
        )
        .environmentObject(frydgeManager)
        .environmentObject(shoppingListManager)
    }
}
 
// MARK: - Item Lookup Sheet

private struct ShoppingItemLookupSheet: View {
    let item: ShoppingListItem
    let recipeListModel: RecipeListModel
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var shoppingListManager: ShoppingListManager
    @State private var isLoadingOFF    = true
    @State private var offProduct:     OFFProduct? = nil
    @State private var frydgeProduct:  FrydgeProduct? = nil
    @State private var ratingsFacts:   ProductNutritionFacts? = nil
    @State private var offError:       String?     = nil
    @State private var isLoadingOffers = true
    @State private var offers:         [RetailOffer] = []
    @State private var offersError:    String?       = nil
    @State private var previewRecipe: CloudRecipe? = nil
    @State private var popupRecipe:   CloudRecipe? = nil

    private var searchQuery: String {
        item.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Query that includes the item's weight/volume so GroceryQueryBuilder can extract a size hint.
    /// e.g. item name="butter", quantity="500", unit="g" → "500g butter"
    private var sizeAwareSearchQuery: String {
        GroceryQueryBuilder.sizeAwareQuery(name: item.name, quantity: item.quantity, unit: item.unit)
    }

    /// Recipes that use this item, via the shared token matcher so brand
    /// words, pack sizes and prefixes ("ice" in "rice") can't create a match.
    private var matchingRecipes: [CloudRecipe] {
        let itemTokens = IngredientMatcher.tokens(item.name)
        guard !itemTokens.isEmpty else { return [] }
        return recipeListModel.recipes.filter { recipe in
            IngredientMatcher.tokensMatch(IngredientMatcher.recipeTokens(recipe.ingredients), itemTokens)
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let half = max(180, geo.size.height * 0.28)
                ScrollView {
                    VStack(spacing: 12) {
                        productCard(minHeight: half)
                            .padding(.horizontal)

                        Divider().padding(.horizontal)

                        if let product = frydgeProduct {
                            environmentalSection(for: product)
                                .padding(.horizontal)
                        }

                        offersSection

                        if !matchingRecipes.isEmpty {
                            recipesSection
                                .padding(.horizontal)
                                .padding(.bottom, 20)
                        }
                    }
                    .padding(.top, 10)
                    .frame(minHeight: geo.size.height, alignment: .top)
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss(); dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await refreshAll() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh")
                }
            }
            .task { await refreshAll() }
            .overlay {
                if let recipe = popupRecipe {
                    ZStack {
                        Color.black.opacity(0.55)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                    popupRecipe = nil
                                }
                            }
                        RecipePopupCard(recipe: recipe) {
                            previewRecipe = recipe
                            popupRecipe = nil
                        }
                        .padding(.horizontal, 28)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: popupRecipe?.id)
                }
            }
        }
        .presentationDetents([.large])
        .sheet(item: $previewRecipe) { recipe in
            NavigationStack {
                RecipeDetailView(recipeListModel: recipeListModel, recipe: recipe)
            }
        }
    }

    // MARK: Environmental Impact

    @ViewBuilder
    private func environmentalSection(for product: FrydgeProduct) -> some View {
        // Same two-tile ratings block as the product card: food quality on
        // the left, environmental impact on the right. The Worker's own
        // Eco-Score column is sparse, so the facts are enriched with Open
        // Food Facts' live Green-Score or a typical-impact estimate.
        let facts = ratingsFacts ?? ProductNutritionFacts(product: product)

        // The outer stack always exists so the enrichment task runs even
        // when the Worker record has no ratings yet.
        VStack(alignment: .leading, spacing: 0) {
            if facts.hasRatings {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ratings")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ProductRatingsView(facts: facts)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1))
                )
            }
        }
        .task(id: product.code) {
            ratingsFacts = await ProductNutritionFacts(product: product)
                .enriched(name: item.name, barcode: product.code)
        }
    }

    // MARK: Recipes section

    @ViewBuilder
    private var recipesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recipes using \(item.name)")
                .font(.headline)

            VStack(spacing: 6) {
                ForEach(matchingRecipes.prefix(6)) { recipe in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            popupRecipe = recipe
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Group {
                                if let img = recipeRowImage(recipe) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                } else if let urlString = recipe.imageSourceURL,
                                          !urlString.isEmpty,
                                          let url = URL(string: urlString) {
                                    CachedAsyncImage(url: url) { phase in
                                        if case .success(let img) = phase {
                                            img.resizable().scaledToFill()
                                        } else {
                                            Color.orange.opacity(0.15)
                                        }
                                    }
                                } else {
                                    ZStack {
                                        Color.orange.opacity(0.15)
                                        Image(systemName: "fork.knife")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 7))

                            Text(recipe.name)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Spacer()

                            if let serves = Int(recipe.serves.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                Text("👤 \(serves)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1))
        )
    }


    // MARK: Product card

    @ViewBuilder
    private func productCard(minHeight: CGFloat) -> some View {
        Group {
            if isLoadingOFF {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Looking up OpenFoodFacts…").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: minHeight)
            } else if let p = offProduct {
                OFFDetailsCard(product: p, fallbackTitle: item.name)
                    .frame(maxWidth: .infinity, alignment: .top)
            } else if let offer = offers.first {
                fallbackOfferCard(offer)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1))
        )
    }

    @ViewBuilder
    private func fallbackOfferCard(_ offer: RetailOffer) -> some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text((offer.productTitle?.isEmpty == false ? offer.productTitle! : item.name))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let quantityLabel = productQuantityLabel(across: offers, fallback: offer) {
                    Text(quantityLabel)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Group {
                if let imageURL = offer.imageURL {
                    CachedAsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFit()
                        default:
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.gray.opacity(0.15))
                                Image(systemName: offer.placeholderSymbolName ?? "photo")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.gray.opacity(0.15))
                        Image(systemName: offer.placeholderSymbolName ?? "photo")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 160)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(16)
    }

    private func productQuantityLabel(across offers: [RetailOffer], fallback: RetailOffer) -> String? {
        let candidates = offers.isEmpty ? [fallback] : offers
        for candidate in candidates {
            let details = candidate.detailsText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !details.isEmpty { return details }
        }
        for candidate in candidates {
            let parsed = candidate.parsedQuantityAndUnit
            let unit = parsed.unit.trimmingCharacters(in: .whitespacesAndNewlines)
            if !unit.isEmpty {
                let quantity = parsed.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(quantity)\(unit)"
            }
        }
        return nil
    }

    // MARK: Offers section

    @ViewBuilder
    private var offersSection: some View {
        if isLoadingOffers {
            VStack(spacing: 12) {
                ProgressView()
                Text("Checking stores…").foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else if offers.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "cart").font(.title2)
                Text("No store results yet").font(.headline)
                Text(offersError ?? "No offers returned.")
                    .font(.caption).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            // Inline list (avoids nested ScrollView issues)
            VStack(spacing: 0) {
                Text("Stores")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 4)

                ForEach(offers) { offer in
                    StoreOfferRow(offer: offer)
                        .padding(.horizontal)
                    Divider().padding(.leading)
                }
            }
        }
    }

    // MARK: Load

    private func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await loadOFF() }
            group.addTask { await loadOffers() }
        }
    }

    private func loadOFF() async {
        await MainActor.run { isLoadingOFF = true; offError = nil; offProduct = nil; frydgeProduct = nil }
        let query = searchQuery
        let found: FrydgeProduct?
        do {
            found = try await withThrowingTaskGroup(of: FrydgeProduct?.self) { group in
                group.addTask { try await OpenFoodFactsService.shared.searchRich(query).first }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    throw CancellationError()
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch {
            found = nil
        }
        // Keep the slimmed OFFProduct for existing UI (nutrition card), and the
        // richer FrydgeProduct for the ratings badges (Nutri-Score / NOVA / Eco).
        await MainActor.run {
            frydgeProduct = found
            offProduct = found?.asOFFProduct
            isLoadingOFF = false
        }
    }


    private func loadOffers() async {
        await MainActor.run { isLoadingOffers = true; offersError = nil; offers = [] }
        let query = sizeAwareSearchQuery  // includes weight/unit so GroceryQueryBuilder can extract a size hint

        let rawOffers = await withTaskGroup(of: [StockAvailability.StoreOffer].self) { group in
            group.addTask { await StockAvailability.fetchOffers(for: query) }
            group.addTask {
                do { try await Task.sleep(for: .seconds(12)) } catch {}
                return []
            }
            let result = await group.next() ?? []
            group.cancelAll()
            return result
        }

        // Retail offers are already filtered and sorted by StockAvailability.
        let sorted: [RetailOffer] = rawOffers
            .map { RetailOffer(from: $0) }
            .sorted {
                // Priced offers sort before unpriced; within each group sort by price then name
                switch ($0.numericPrice, $1.numericPrice) {
                case let (l?, r?): return l != r ? l < r : $0.storeName < $1.storeName
                case (_?, nil):    return true
                case (nil, _?):    return false
                default:           return $0.storeName < $1.storeName
                }
            }

        // Deduplicate: keep only the cheapest offer per store (array is already price-sorted)
        var seen = Set<String>()
        let mapped = sorted.filter { offer in
            let key = offer.storeName.lowercased().trimmingCharacters(in: .whitespaces)
            return seen.insert(key).inserted
        }

        await MainActor.run {
            offers = mapped
            isLoadingOffers = false
            if mapped.isEmpty { offersError = "No retailers returned any results." }
        }

        // Auto-fill quantity/unit from best offer when the item has none yet
        if item.quantity == "1", item.unit.isEmpty, let best = mapped.first {
            let parsed = best.parsedQuantityAndUnit
            if !parsed.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await MainActor.run {
                    shoppingListManager.addToShoppingList(name: item.name, quantity: parsed.quantity, unit: parsed.unit)
                }
            }
        }
    }
}

// MARK: - Recipe Quick Preview

private struct RecipeQuickPreview: View {
    let recipe: CloudRecipe
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Header meta
                    HStack(spacing: 16) {
                        Label(recipe.pan.isEmpty ? "Pan" : recipe.pan, systemImage: "frying.pan")
                        Spacer()
                        if let serves = Int(recipe.serves.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            Label("\(serves) serving\(serves == 1 ? "" : "s")", systemImage: "person.2")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                    Divider()

                    // Ingredients
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ingredients")
                            .font(.headline)
                            .padding(.horizontal)

                        ForEach(recipe.ingredients, id: \.self) { ingredient in
                            HStack(alignment: .top, spacing: 10) {
                                Circle()
                                    .frame(width: 6, height: 6)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 6)
                                Text(ingredient)
                                    .font(.subheadline)
                            }
                            .padding(.horizontal)
                        }
                    }

                    // Steps / instructions
                    if !recipe.steps.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Method")
                                .font(.headline)
                                .padding(.horizontal)
                            ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .top, spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 22, height: 22)
                                        .background(.orange, in: Circle())
                                    Text(step.text)
                                        .font(.subheadline)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.horizontal)
                            }
                        }
                    } else if !recipe.instructions.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Method")
                                .font(.headline)
                                .padding(.horizontal)
                            Text(recipe.instructions)
                                .font(.subheadline)
                                .padding(.horizontal)
                        }
                    }

                    if !recipe.dietaryTags.isEmpty {
                        Divider()
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(recipe.dietaryTags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                            .padding(.horizontal)
                        }
                    }

                    Spacer(minLength: 40)
                }
                .padding(.top, 12)
            }
            .navigationTitle(recipe.name)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - OFF Details Card

private struct OFFDetailsCard: View {
    let product: OFFProduct
    let fallbackTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Group {
                    if let urlStr = product.imageUrl, let url = URL(string: urlStr) {
                        CachedAsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img): img.resizable().scaledToFill()
                            default:
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.gray.opacity(0.15))
                                    Image(systemName: "photo").foregroundColor(.secondary)
                                }
                            }
                        }
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.gray.opacity(0.15))
                            Image(systemName: "photo").foregroundColor(.secondary)
                        }
                    }
                }
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(product.productName?.isEmpty == false ? product.productName! : fallbackTitle)
                        .font(.headline).lineLimit(2)
                    if let q = product.quantity, !q.isEmpty {
                        Text(q).font(.subheadline).foregroundColor(.secondary)
                    }
                    if let code = product.code, !code.isEmpty {
                        Text("Barcode: \(code)").font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer()
            }

            if let score = NutritionEngine.score(for: product.nutriments) {
                NutritionScorePanel(score: score, nutriments: product.nutriments)
            }
        }
        .padding(16)
    }
}

private struct NutritionScorePanel: View {
    let score: Int
    let nutriments: OFFNutriments?

    private var tone: NutritionTone { NutritionEngine.tone(for: score) }

    private var toneColor: Color {
        switch tone {
        case .good: return .green
        case .okay: return .orange
        case .poor:  return .red
        }
    }

    private var toneLabel: String {
        switch tone {
        case .good: return "Good nutritional profile"
        case .okay: return "Moderate nutritional profile"
        case .poor:  return "Poor nutritional profile"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(toneColor)
                        .frame(width: 64, height: 64)
                    VStack(spacing: 0) {
                        Text("\(score)")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text("/10")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Nutrition Score")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(toneLabel)
                        .font(.caption)
                        .foregroundColor(toneColor)
                        .fontWeight(.medium)
                }
                Spacer()
            }

            let rows = NutritionEngine.summaryRows(for: nutriments)
            if !rows.isEmpty {
                VStack(spacing: 6) {
                    ForEach(Array(Swift.stride(from: 0, to: rows.count, by: 2)), id: \.self) { i in
                        HStack(spacing: 8) {
                            nutritionCell(label: rows[i].0, value: rows[i].1)
                            if i + 1 < rows.count {
                                nutritionCell(label: rows[i + 1].0, value: rows[i + 1].1)
                            } else {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(toneColor.opacity(0.08))
        .cornerRadius(14)
    }

    private func nutritionCell(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption2)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - RetailOffer model

struct RetailOffer: Identifiable, Hashable {
    let id          = UUID()
    let storeName:    String
    let priceText:    String?
    let numericPrice: Double?
    let url:          URL?
    let imageURL:     URL?
    let placeholderSymbolName: String?
    let productTitle: String?
    let detailsText: String?

    var resolvedTitle: String {
        let trimmed = productTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? storeName : trimmed
    }

    var parsedQuantityAndUnit: (quantity: String, unit: String) {
        let source = detailsText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !source.isEmpty else { return ("1", "") }

        let patterns = [
            #"(\\d+(?:[\\.,]\\d+)?)\\s*(kg|g|mg|l|ml|cl|oz|lb|pack|pk|ea|each|bottle|can|cans|jar|tub|tray|pkt|pouch|roll|sheet)s?\b"#,
            #"\\b(kg|g|mg|l|ml|cl|oz|lb)\\s*(\\d+(?:[\\.,]\\d+)?)\\b"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(source.startIndex..<source.endIndex, in: source)
                if let match = regex.firstMatch(in: source, options: [], range: range), match.numberOfRanges >= 3 {
                    let first = Range(match.range(at: 1), in: source).map { String(source[$0]) } ?? ""
                    let second = Range(match.range(at: 2), in: source).map { String(source[$0]) } ?? ""

                    if first.rangeOfCharacter(from: .decimalDigits) != nil {
                        return (first.replacingOccurrences(of: ",", with: "."), second)
                    } else if second.rangeOfCharacter(from: .decimalDigits) != nil {
                        return (second.replacingOccurrences(of: ",", with: "."), first)
                    }
                }
            }
        }

        return ("1", "")
    }

    init(storeName: String, priceText: String?, numericPrice: Double?,
         url: URL?, imageURL: URL?, placeholderSymbolName: String?, productTitle: String?, detailsText: String?) {
        self.storeName    = storeName
        self.priceText    = priceText
        self.numericPrice = numericPrice
        self.url          = url
        self.imageURL     = imageURL
        self.placeholderSymbolName = placeholderSymbolName
        self.productTitle = productTitle
        self.detailsText  = detailsText
    }

    init(from offer: StockAvailability.StoreOffer) {
        self.init(
            storeName:    offer.store,
            priceText:    RetailOffer.fmt(offer.price, code: offer.currencyCode),
            numericPrice: offer.price,
            url:          offer.productURL,
            imageURL:     offer.imageURL,
            placeholderSymbolName: nil,
            productTitle: offer.productTitle,
            detailsText:  offer.detailsText
        )
    }

    private static func fmt(_ price: Double?, code: String) -> String? {
        guard let price else { return nil }
        let f = NumberFormatter()
        f.numberStyle  = .currency
        f.currencyCode = code.isEmpty ? (Locale.current.currency?.identifier ?? code) : code
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = price.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2
        return f.string(from: NSNumber(value: price))
    }
}

// MARK: - Store Offer Row
private struct RecipePopupCard: View {
    let recipe: CloudRecipe
    let onTap: () -> Void

    // Same resolution chain as the recipe cards: memory → disk cache →
    // CKAsset → remote URL (retried) → CloudKit. Previously this card only
    // read the CKAsset temp file and otherwise fell back to a bare AsyncImage.
    @StateObject private var imageLoader = RecipeImageLoader()

    var body: some View {
        VStack(spacing: 0) {
            imageArea
                .frame(maxWidth: .infinity)
                .frame(height: 260)
                .clipped()

            VStack(spacing: 6) {
                Text(recipe.name)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                Label("Tap to open recipe", systemImage: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.4), radius: 28, x: 0, y: 12)
        .onTapGesture { onTap() }
        .onAppear { imageLoader.load(recipe: recipe) }
        .onDisappear { imageLoader.cancel() }
    }

    @ViewBuilder
    private var imageArea: some View {
        if let img = recipe.image ?? imageLoader.image {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else if imageLoader.isLoading {
            placeholderGradient.overlay(ProgressView().tint(.white))
        } else {
            placeholderGradient
        }
    }

    private var placeholderGradient: some View {
        ZStack {
            LinearGradient(
                colors: [.orange.opacity(0.5), .red.opacity(0.35)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: "fork.knife")
                .font(.system(size: 64))
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}

// Same image logic for the row thumbnail
private func recipeRowImage(_ recipe: CloudRecipe) -> UIImage? {
    if let img = recipe.image { return img }
    if let fileURL = recipe.imageAsset?.fileURL {
        return UIImage.frydgeBounded(contentsOf: fileURL, maxPixelSize: ImageBudget.thumbnail)
    }
    return nil
}

private struct StoreOfferRow: View {
    let offer: RetailOffer
    @EnvironmentObject private var shoppingListManager: ShoppingListManager
    @Environment(\.dismiss) private var dismiss

    private var priceLabel: String {
        let trimmed = offer.priceText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Price unavailable" : trimmed
    }

    private func addOfferToShoppingList() {
        let parsed = offer.parsedQuantityAndUnit
        shoppingListManager.addToShoppingList(
            name: offer.resolvedTitle,
            quantity: parsed.quantity,
            unit: parsed.unit,
            location: "Store",
            dietaryTags: []
        )
        dismiss()
    }

    var body: some View {
        Button {
            addOfferToShoppingList()
        } label: {
            HStack(spacing: 10) {
                StoreBranding.logo(for: offer.storeName)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(offer.storeName)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if let product = offer.productTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !product.isEmpty, product.localizedCaseInsensitiveCompare(offer.storeName) != .orderedSame {
                        Text(product)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Text(priceLabel)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)

                Circle()
                    .fill(Color.green)
                    .frame(width: 10, height: 10)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
    }
}

// This view now uses native List swipe actions; SwipeToDeleteRow.swift is still
// used by the Fridge / Shared Fridge / Leftovers screens.

// MARK: - Move Sheet

private struct MoveToSharedShoppingListSheet: View {
    @EnvironmentObject var sharedShoppingListManager: SharedShoppingListManager
    @Environment(\.dismiss) private var dismiss

    let onCancel: () -> Void
    let onMove:   (CKRecord) -> Void

    var body: some View {
        NavigationStack {
            List {
                if sharedShoppingListManager.anchors.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.2.fill")
                        Text("No shared shopping lists").font(.headline)
                        Text("Create or accept a shared shopping list first.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(sharedShoppingListManager.anchors, id: \.recordID) { anchor in
                        let id    = anchor.recordID
                        let name  = sharedShoppingListManager.namesByAnchorID[id]  ?? (anchor["name"]  as? String ?? "Shared Shopping List")
                        let emoji = sharedShoppingListManager.emojisByAnchorID[id] ?? (anchor["emoji"] as? String ?? "🛒")
                        Button { onMove(anchor); dismiss() } label: {
                            HStack(spacing: 10) {
                                Text(emoji)
                                Text(name).foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundColor(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Move to Shared")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel(); dismiss() }
                }
            }
            .task { await sharedShoppingListManager.refreshSharedLists() }
        }
    }
}



// MARK: - Preview

#Preview {
    ShoppingListView()
        .environmentObject(AppState())
        .environmentObject(FrydgeManager())
        .environmentObject(ShoppingListManager())
        .environmentObject(SharedShoppingListManager())
}


private struct AvailabilityOptionsSheet: View {
    @Binding var name: String
    @Binding var quantity: String
    @Binding var unit: String

    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Confirm product before checking prices")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Product")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Product name", text: $name)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Quantity")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("e.g. 2", text: $quantity)
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.decimalPad)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Unit")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("e.g. kg, ml, pack", text: $unit)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.bordered)

                    Spacer()

                    Button("Check Prices") { onConfirm() }
                        .buttonStyle(.borderedProminent)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .navigationTitle("Availability")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Shopping Item Image View

private struct ShoppingItemImageView: View {
    let name: String
    let quantity: String
    let unit: String
    let offer: RetailOffer?
    @ObservedObject private var photoLibrary = UserPhotoLibrary.shared
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let img = photoLibrary.firstUIImage(for: name) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let offer, let url = offer.imageURL {
                CachedAsyncImage(url: url) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill()
                    } else {
                        imagePlaceholder
                    }
                }
            } else {
                imagePlaceholder
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .task {
            await loadAndCache()
        }
    }

    private var imagePlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.systemGray6))
            Text(FoodEmoji.emoji(for: name))
                .font(.title3)
        }
    }

    private func loadAndCache() async {
        // A specific store offer carries its own photo for the exact product that
        // matched — key its cache entry by the offer itself (store + product title),
        // never by the generic shopping-list item name. Otherwise the first offer
        // ever seen for e.g. "Milk" permanently wins the shared "milk" cache slot,
        // and every other brand's offer for the same item shows that first photo.
        if let offer, let offerURL = offer.imageURL {
            let offerKey = ProductImageCacheManager.shared.imageCacheKey(
                name: "\(offer.storeName) \(offer.productTitle ?? name)",
                quantity: "",
                unit: ""
            )
            if let cached = ProductImageCacheManager.shared.uiImage(forKey: offerKey) {
                await MainActor.run { image = cached }
                return
            }
            do {
                try await ProductImageCacheManager.shared.storeImage(
                    from: offerURL,
                    forKey: offerKey,
                    productName: offer.productTitle ?? name,
                    storeName: offer.storeName
                )
                if let cached = ProductImageCacheManager.shared.uiImage(forKey: offerKey) {
                    await MainActor.run { image = cached }
                }
            } catch {}
            return
        }

        let key = ProductImageCacheManager.shared.imageCacheKey(name: name, quantity: "", unit: "")

        if let cached = ProductImageCacheManager.shared.uiImage(forKey: key) {
            await MainActor.run { image = cached }
            return
        }

        if let url = await fetchOFFImageURL(for: name) {
            do {
                try await ProductImageCacheManager.shared.storeImage(
                    from: url,
                    forKey: key,
                    productName: name,
                    storeName: nil
                )
                if let cached = ProductImageCacheManager.shared.uiImage(forKey: key) {
                    await MainActor.run { image = cached }
                }
                return
            } catch {}
        }

        // Last resort: a photo another Frydge user contributed for this name.
        if let community = await CommunityPhotoStore.shared.firstPhoto(barcode: nil, name: name) {
            await MainActor.run { image = community.image }
        }
    }

    private func fetchOFFImageURL(for query: String) async -> URL? {
        guard let products = try? await OpenFoodFactsService.shared.search(query) else { return nil }
        guard let match = products.first(where: { product in
            guard let name = product.productName, !name.isEmpty else { return true }
            return isFoodRelevant(responseText: name, query: query)
        }), let rawURL = match.imageUrl, let imageURL = URL(string: rawURL) else { return nil }
        return imageURL
    }
}

private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

// MARK: - Shopping List Item Detail Sheet

struct ShoppingListItemDetailSheet: View {
    let item: ShoppingListItem
    /// The supermarket the shopper is currently in (from the store-arrival
    /// notification). Enables the "while you're here" picks section.
    var inStoreName: String? = nil
    /// Removes the item from wherever it lives (personal or a shared list).
    var onDelete: (() -> Void)? = nil

    /// A recipe this item makes together with other things in the basket.
    private struct BasketRecipe: Identifiable {
        let recipe: CloudRecipe
        /// Other shopping list items the recipe uses (short names).
        let basketMates: [String]
        /// Ingredient lines covered by neither the fridge nor the basket.
        let stillMissing: [String]
        var id: String { recipe.id }
    }

    /// Something on the shelves of the current store that finishes a recipe.
    private struct InStorePick: Identifiable {
        let id = UUID()
        let ingredient: String
        let forRecipe: String
        let offer: RetailOffer
    }

    @State private var basketRecipes: [BasketRecipe] = []
    @State private var inStorePicks: [InStorePick] = []
    @State private var isLoadingInStore = false
    @State private var addedPickIDs: Set<UUID> = []

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var shoppingListManager: ShoppingListManager
    @EnvironmentObject private var frydgeManager: FrydgeManager
    @EnvironmentObject private var sharedShoppingListManager: SharedShoppingListManager
    @EnvironmentObject private var appState: AppState

    @StateObject private var recipeListModel = RecipeListModel()

    @State private var userPhotos: [UIImage] = []
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var carouselIndex: Int = 0
    @State private var headerImage: UIImage?
    @State private var matchingRecipes: [CloudRecipe] = []
    @State private var selectedRecipe: CloudRecipe?
    @State private var isLoadingRecipes = false
    @State private var offNutrition: OFFProduct?
    @State private var edamamNutrition: EdamamFoodResult?
    @State private var isLoadingNutrition = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    Divider()
                    nutritionSection
                    Divider()
                    infoSection
                    if !item.dietaryTags.isEmpty {
                        Divider()
                        dietaryTagsSection
                    }
                    Divider()
                    recipesSection
                    Divider()
                    basketRecipesSection
                    if let inStoreName {
                        Divider()
                        inStoreSection(inStoreName)
                    }
                }
                .padding()
            }
            .navigationTitle("Item Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if let onDelete {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(role: .destructive) {
                            onDelete()
                            dismiss()
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            .task {
                userPhotos = UserPhotoLibrary.shared.photos(for: item.name).compactMap { UIImage.frydgeBounded(data: $0, maxPixelSize: ImageBudget.display) }
                await loadHeaderImage()
                await loadMatchingRecipes()
                computeBasketRecipes()
                await loadNutrition()
                await loadInStorePicks()
            }
            .navigationDestination(item: $selectedRecipe) { recipe in
                RecipeDetailView(recipeListModel: recipeListModel, recipe: recipe)
                    .environmentObject(frydgeManager)
                    .environmentObject(shoppingListManager)
                    .environmentObject(sharedShoppingListManager)
                    .environmentObject(appState)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            let allImages: [UIImage] = userPhotos + (headerImage.map { [$0] } ?? [])

            ZStack(alignment: .bottomTrailing) {
                if allImages.isEmpty {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.systemGray5))
                        Text(FoodEmoji.emoji(for: item.name))
                            .font(.system(size: 64))
                    }
                } else {
                    TabView(selection: $carouselIndex) {
                        ForEach(allImages.indices, id: \.self) { i in
                            Image(uiImage: allImages[i])
                                .resizable()
                                .scaledToFill()
                                .clipped()
                                .tag(i)
                                .overlay(alignment: .topTrailing) {
                                    if i < userPhotos.count {
                                        Button { deleteUserPhoto(at: i) } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.title2)
                                                .foregroundStyle(.white)
                                                .shadow(color: .black.opacity(0.4), radius: 3)
                                        }
                                        .padding(10)
                                    }
                                }
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: allImages.count > 1 ? .always : .never))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                        .padding(10)
                }
            }
            .frame(height: 200)
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let img = UIImage.frydgeBounded(data: data, maxPixelSize: ImageBudget.upload),
                       let jpeg = img.jpegData(compressionQuality: 0.8) {
                        userPhotos.insert(img, at: 0)
                        UserPhotoLibrary.shared.addPhoto(jpeg, for: item.name)
                        carouselIndex = 0
                    }
                    selectedPhotoItem = nil
                }
            }

            Text(item.name)
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Info

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Information")
                .font(.headline)

            HStack {
                Text("Quantity:")
                    .foregroundColor(.secondary)
                Spacer()
                Text({
                    let q = item.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
                    let u = item.unit.trimmingCharacters(in: .whitespacesAndNewlines)
                    if u.lowercased() == "ea", !q.isEmpty { return "x\(q)" }
                    return q + (u.isEmpty ? "" : " \(u)")
                }())
                    .fontWeight(.medium)
            }

            HStack {
                Text("Location:")
                    .foregroundColor(.secondary)
                Spacer()
                Text(item.location.isEmpty ? "Not specified" : item.location)
                    .fontWeight(.medium)
            }
        }
    }

    // MARK: - Dietary Tags

    private var dietaryTagsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dietary Tags")
                .font(.headline)
            HStack(spacing: 6) {
                ForEach(Array(item.dietaryTags).sorted(), id: \.self) { tag in
                    DietaryBadgeChip(tag: tag, tone: .brand)
                }
            }
        }
    }

    // MARK: - Nutrition

    private var nutritionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Nutrition")
                    .font(.headline)
                Spacer()
                if isLoadingNutrition {
                    ProgressView().scaleEffect(0.7)
                } else if offNutrition?.nutriments == nil, edamamNutrition != nil {
                    Text("via Edamam")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                } else if offNutrition?.nutriments != nil {
                    Text("via Open Food Facts")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }

            if !isLoadingNutrition {
                let kcal    = offNutrition?.nutriments?.energyKcal ?? edamamNutrition?.calories
                let fat     = offNutrition?.nutriments?.fat         ?? edamamNutrition?.fatG
                let carbs   = offNutrition?.nutriments?.carbs       ?? edamamNutrition?.carbsG
                let protein = offNutrition?.nutriments?.proteins    ?? edamamNutrition?.proteinG
                let fiber   = edamamNutrition?.fiberG

                if kcal == nil, fat == nil, carbs == nil, protein == nil {
                    Text("Nutrition data not available")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        nutritionRow("Energy",  value: kcal,    unit: "kcal")
                        nutritionRow("Protein", value: protein, unit: "g")
                        nutritionRow("Fat",     value: fat,     unit: "g")
                        nutritionRow("Carbs",   value: carbs,   unit: "g")
                        if let fiber { nutritionRow("Fiber", value: fiber, unit: "g") }
                    }
                    Text("Per 100 g")
                        .font(.caption).foregroundStyle(.tertiary).padding(.top, 2)
                }
            }
        }
    }

    private func nutritionRow(_ label: String, value: Double?, unit: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).font(.subheadline)
            Spacer()
            if let value {
                Text(String(format: "%.1f %@", value, unit)).font(.subheadline).fontWeight(.medium)
            } else {
                Text("—").font(.subheadline).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Recipes

    private var recipesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recipes Using This").font(.headline)
                Spacer()
                if isLoadingRecipes { ProgressView().scaleEffect(0.8) }
            }

            if isLoadingRecipes {
                Color.clear.frame(height: 1)
            } else if matchingRecipes.isEmpty {
                Text("No recipes found for this ingredient")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(matchingRecipes.prefix(6), id: \.id) { recipe in
                        Button { selectedRecipe = recipe } label: {
                            HStack(spacing: 12) {
                                recipeRowImage(recipe)
                                    .frame(width: 40, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(recipe.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary).lineLimit(2)
                                    if !recipe.ingredients.isEmpty {
                                        Text("\(recipe.ingredients.count) ingredient\(recipe.ingredients.count == 1 ? "" : "s")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 10).padding(.horizontal, 12)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.ultraThinMaterial))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Cook from your basket

    private var basketRecipesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Cook From Your Basket").font(.headline)
                Spacer()
                if isLoadingRecipes { ProgressView().scaleEffect(0.8) }
            }

            if isLoadingRecipes {
                Color.clear.frame(height: 1)
            } else if basketRecipes.isEmpty {
                Text("Nothing else in your basket pairs with this yet.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(basketRecipes.prefix(4)) { entry in
                        Button { selectedRecipe = entry.recipe } label: {
                            HStack(spacing: 12) {
                                recipeRowImage(entry.recipe)
                                    .frame(width: 40, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.recipe.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary).lineLimit(2)
                                    Text(basketMatesLine(entry.basketMates))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    if entry.stillMissing.isEmpty {
                                        Text("Everything covered")
                                            .font(.caption2).foregroundStyle(.green)
                                    } else {
                                        Text("\(entry.stillMissing.count) more to grab")
                                            .font(.caption2).foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 10).padding(.horizontal, 12)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.ultraThinMaterial))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// "With Milk, Butter and Flour from your basket" (+N more when long).
    private func basketMatesLine(_ mates: [String]) -> String {
        let shown = Array(mates.prefix(3))
        let extra = mates.count - shown.count
        let list = shown.formatted(.list(type: .and))
        return extra > 0 ? "With \(list) +\(extra) more from your basket" : "With \(list) from your basket"
    }

    // MARK: - While you're in the store

    private func inStoreSection(_ store: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "storefront").foregroundStyle(.blue)
                Text("While You're at \(StoreChain.shortName(for: store))")
                    .font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
                if isLoadingInStore { ProgressView().scaleEffect(0.8) }
            }

            if inStorePicks.isEmpty {
                Text(isLoadingInStore
                     ? "Checking what's on the shelves…"
                     : "No extra picks found here for your recipes.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                Text("Grab these to finish recipes from your basket.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(spacing: 8) {
                    ForEach(inStorePicks) { pick in
                        HStack(spacing: 12) {
                            offerThumbnail(pick.offer, fallbackName: pick.ingredient)
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(pick.offer.resolvedTitle)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary).lineLimit(2)
                                Text("Finishes \(pick.forRecipe)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                if let price = pick.offer.priceText, !price.isEmpty {
                                    Text(price).font(.subheadline.weight(.semibold))
                                }
                                Button {
                                    addPickToList(pick)
                                } label: {
                                    Label(addedPickIDs.contains(pick.id) ? "Added" : "Add",
                                          systemImage: addedPickIDs.contains(pick.id) ? "checkmark" : "plus")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(addedPickIDs.contains(pick.id))
                            }
                        }
                        .padding(.vertical, 10).padding(.horizontal, 12)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.ultraThinMaterial))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func offerThumbnail(_ offer: RetailOffer, fallbackName: String) -> some View {
        if let url = offer.imageURL {
            CachedAsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    ingredientPlaceholder(fallbackName)
                }
            }
        } else {
            ingredientPlaceholder(fallbackName)
        }
    }

    private func ingredientPlaceholder(_ name: String) -> some View {
        ZStack {
            Color(.systemGray5)
            Text(FoodEmoji.emoji(for: name)).font(.title3)
        }
    }

    private func addPickToList(_ pick: InStorePick) {
        let parsed = pick.offer.parsedQuantityAndUnit
        shoppingListManager.addToShoppingList(
            name: pick.ingredient.localizedCapitalized,
            quantity: parsed.quantity,
            unit: parsed.unit,
            location: "Shopping",
            dietaryTags: []
        )
        addedPickIDs.insert(pick.id)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @ViewBuilder
    private func recipeRowImage(_ recipe: CloudRecipe) -> some View {
        if let img = recipe.image {
            Image(uiImage: img).resizable().scaledToFill()
        } else if let assetURL = recipe.imageAsset?.fileURL,
                  let img = UIImage.frydgeBounded(contentsOf: assetURL, maxPixelSize: ImageBudget.thumbnail) {
            Image(uiImage: img).resizable().scaledToFill()
        } else if let urlStr = recipe.imageSourceURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
            CachedAsyncImage(url: url) { phase in
                if case .success(let image) = phase { image.resizable().scaledToFill() }
                else { recipeImagePlaceholder }
            }
        } else {
            recipeImagePlaceholder
        }
    }

    private var recipeImagePlaceholder: some View {
        ZStack {
            Color.orange.opacity(0.15)
            Image(systemName: "fork.knife").font(.caption).foregroundStyle(.orange)
        }
    }

    // MARK: - Actions

    private func deleteUserPhoto(at index: Int) {
        guard index < userPhotos.count else { return }
        userPhotos.remove(at: index)
        UserPhotoLibrary.shared.removePhoto(at: index, for: item.name)
        let total = userPhotos.count + (headerImage != nil ? 1 : 0)
        if carouselIndex >= total { carouselIndex = max(0, total - 1) }
    }

    private func loadHeaderImage() async {
        let key = ProductImageCacheManager.shared.imageCacheKey(name: item.name, quantity: "", unit: "")
        if let cached = ProductImageCacheManager.shared.uiImage(forKey: key) {
            headerImage = cached; return
        }
        await ProductImageCacheManager.shared.prefetchIfNeeded(for: item.name)
        if let cached = ProductImageCacheManager.shared.uiImage(forKey: key) {
            headerImage = cached
        }
    }

    private func loadNutrition() async {
        isLoadingNutrition = true
        let off: OFFProduct? = await withCheckedContinuation { cont in
            FoodInfoService().fetchFoodInfo(for: item.name) { result in
                cont.resume(returning: try? result.get())
            }
        }
        offNutrition = off
        if off?.nutriments == nil {
            edamamNutrition = await EdamamService.shared.fetchFood(for: item.name)
        }
        isLoadingNutrition = false
    }

    private func loadMatchingRecipes() async {
        isLoadingRecipes = true
        applyRecipeFilter()
        isLoadingRecipes = false
        await recipeListModel.fetchIfStale(maxAge: 5 * 60)
        applyRecipeFilter()
    }

    /// Shared token matcher, so this sheet agrees with the fridge item sheet
    /// and the recipe list about which recipes use an item.
    private func applyRecipeFilter() {
        let itemTokens = IngredientMatcher.tokens(item.name)
        guard !itemTokens.isEmpty else { matchingRecipes = []; return }
        matchingRecipes = recipeListModel.recipes.filter { recipe in
            IngredientMatcher.tokensMatch(IngredientMatcher.recipeTokens(recipe.ingredients), itemTokens)
        }
    }

    /// Of the recipes using this item, which also use something else in the
    /// basket (the rest of the shopping list)? Ranked by how much of the
    /// basket they consume, then by how little is still left to buy.
    private func computeBasketRecipes() {
        let itemTokens = IngredientMatcher.tokens(item.name)
        let others = shoppingListManager.shoppingListItems
            .filter { $0.id != item.id && !IngredientMatcher.tokensMatch(IngredientMatcher.tokens($0.name), itemTokens) }
            .map { (name: ProductShorthand.short(for: $0.name), tokens: IngredientMatcher.tokens($0.name)) }
            .filter { !$0.tokens.isEmpty }
        guard !others.isEmpty else { basketRecipes = []; return }

        basketRecipes = matchingRecipes.compactMap { recipe -> BasketRecipe? in
            let recipeTokens = IngredientMatcher.recipeTokens(recipe.ingredients)
            let mates = others
                .filter { IngredientMatcher.tokensMatch(recipeTokens, $0.tokens) }
                .map(\.name)
            guard !mates.isEmpty else { return nil }

            // Start from what the fridge can't cover, then strike out the
            // lines this item or the rest of the basket will supply.
            let stillMissing = frydgeManager.recipeMatch(for: recipe).missing.filter { line in
                let lineTokens = IngredientMatcher.recipeLineTokens(line)
                if IngredientMatcher.tokensMatch(lineTokens, itemTokens) { return false }
                return !others.contains { IngredientMatcher.tokensMatch(lineTokens, $0.tokens) }
            }
            return BasketRecipe(recipe: recipe, basketMates: mates, stillMissing: stillMissing)
        }
        .sorted { a, b in
            if a.basketMates.count != b.basketMates.count { return a.basketMates.count > b.basketMates.count }
            if a.stillMissing.count != b.stillMissing.count { return a.stillMissing.count < b.stillMissing.count }
            return a.recipe.name.localizedCaseInsensitiveCompare(b.recipe.name) == .orderedAscending
        }
    }

    /// For the store the shopper is standing in: the still-missing
    /// ingredients of the best basket recipes (or, with no basket pairing,
    /// of the top recipes using this item), looked up against that
    /// retailer's shelves. Cheapest matching offer per ingredient.
    private func loadInStorePicks() async {
        guard let store = inStoreName else { return }
        let brandKey = StoreChain.key(for: store)
        let itemTokens = IngredientMatcher.tokens(item.name)

        // (recipe name, missing ingredient lines) sources, best first.
        let sources: [(recipe: String, lines: [String])]
        if basketRecipes.isEmpty {
            sources = matchingRecipes.prefix(3).map { recipe in
                let missing = frydgeManager.recipeMatch(for: recipe).missing.filter {
                    !IngredientMatcher.tokensMatch(IngredientMatcher.recipeLineTokens($0), itemTokens)
                }
                return (recipe.name, missing)
            }
        } else {
            sources = basketRecipes.prefix(3).map { ($0.recipe.name, $0.stillMissing) }
        }

        var candidates: [(ingredient: String, recipe: String)] = []
        var seen = Set<String>()
        outer: for source in sources {
            for line in source.lines {
                let parsed = RecipeIngredientParser.parse(line).name
                let name = RecipeReadiness.cleanedName(parsed.isEmpty ? line : parsed)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
                candidates.append((name, source.recipe))
                if candidates.count >= 6 { break outer }
            }
        }
        guard !candidates.isEmpty else { inStorePicks = []; return }

        isLoadingInStore = true
        defer { isLoadingInStore = false }

        let picks: [InStorePick] = await withTaskGroup(of: InStorePick?.self) { group in
            for candidate in candidates {
                group.addTask {
                    // Retailer lookups can hang; cap each one so the sheet
                    // never waits on a slow store for long.
                    let offers = await withTaskGroup(of: [StockAvailability.StoreOffer].self) { race in
                        race.addTask { await StockAvailability.fetchOffers(for: candidate.ingredient) }
                        race.addTask {
                            try? await Task.sleep(for: .seconds(10))
                            return []
                        }
                        let first = await race.next() ?? []
                        race.cancelAll()
                        return first
                    }
                    let best = offers
                        .filter { StoreChain.key(for: $0.store) == brandKey }
                        .sorted {
                            switch ($0.price, $1.price) {
                            case let (l?, r?): return l < r
                            case (_?, nil):    return true
                            default:           return false
                            }
                        }
                        .first
                    return best.map {
                        InStorePick(ingredient: candidate.ingredient, forRecipe: candidate.recipe, offer: RetailOffer(from: $0))
                    }
                }
            }
            var found: [InStorePick] = []
            for await pick in group {
                if let pick { found.append(pick) }
            }
            return found
        }

        // Keep the recipe grouping stable rather than arrival order.
        let recipeOrder = sources.map(\.recipe)
        inStorePicks = picks.sorted { a, b in
            let ia = recipeOrder.firstIndex(of: a.forRecipe) ?? .max
            let ib = recipeOrder.firstIndex(of: b.forRecipe) ?? .max
            if ia != ib { return ia < ib }
            return a.ingredient.localizedCaseInsensitiveCompare(b.ingredient) == .orderedAscending
        }
    }
}

// MARK: - Shopping Basket Sheet

struct ShoppingBasketSheet: View {
    let items: [ShoppingListItem]
    let offers: [UUID: RetailOffer]
    let totalText: String
    @Binding var checkedItems: Set<UUID>
    let onToggle: (ShoppingListItem) -> Void
    /// In-store availability per item id (empty when not in a store). Items
    /// the store doesn't sell render greyed and sort after the rest.
    var availability: [UUID: StoreAvailability] = [:]
    /// Chain we're standing in, for the "Not at X" caption.
    var inStoreChainName: String? = nil

    private func isUnavailable(_ item: ShoppingListItem) -> Bool {
        availability[item.id]?.isGreyed ?? false
    }

    @Environment(\.dismiss) private var dismiss
    @State private var detailItem: ShoppingListItem? = nil

    // In-store barcode scanning
    @State private var showScanner = false
    @State private var scanBarcode = ""
    @State private var scanProduct: ProductProtocol? = nil
    @State private var scanFeedback: String? = nil
    @State private var scanFeedbackIsHit = false
    @State private var showReceiptScan = false

    @EnvironmentObject private var frydgeManager: FrydgeManager
    @EnvironmentObject private var shoppingListManager: ShoppingListManager
    @EnvironmentObject private var sharedShoppingListManager: SharedShoppingListManager
    @EnvironmentObject private var sharedFridgeManager: SharedFridgeManager
    @EnvironmentObject private var appState: AppState

    /// Alphabetical by the name shown in the row, so the basket reads like a
    /// checklist instead of in the order items happened to be added.
    private func sortedForBasket(_ items: [ShoppingListItem]) -> [ShoppingListItem] {
        items.sorted {
            ProductShorthand.short(for: $0.name)
                .localizedCaseInsensitiveCompare(ProductShorthand.short(for: $1.name)) == .orderedAscending
        }
    }

    /// Unticked items, A–Z, with anything this store doesn't sell at the end.
    private var uncheckedItems: [ShoppingListItem] {
        let unchecked = sortedForBasket(items.filter { !checkedItems.contains($0.id) })
        guard !availability.isEmpty else { return unchecked }
        return unchecked.filter { !isUnavailable($0) } + unchecked.filter { isUnavailable($0) }
    }
    private var gotItems: [ShoppingListItem]       { sortedForBasket(items.filter {  checkedItems.contains($0.id) }) }
    private var progress: Double { items.isEmpty ? 0 : Double(gotItems.count) / Double(items.count) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(uncheckedItems.isEmpty ? "All done!" : "\(uncheckedItems.count) item\(uncheckedItems.count == 1 ? "" : "s") to go")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(totalText)
                                .font(.title2)
                                .fontWeight(.bold)
                        }
                        Spacer()
                        ZStack {
                            Circle()
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 5)
                            Circle()
                                .trim(from: 0, to: progress)
                                .stroke(Color.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(.easeInOut, value: progress)
                            Text("\(Int(progress * 100))%")
                                .font(.caption2)
                                .fontWeight(.semibold)
                        }
                        .frame(width: 52, height: 52)
                    }
                    .padding(.vertical, 6)
                }

                if !uncheckedItems.isEmpty {
                    Section("Still to get") {
                        ForEach(uncheckedItems) { item in
                            BasketItemRow(
                                item: item,
                                offer: offers[item.id],
                                isChecked: false,
                                unavailableAt: isUnavailable(item) ? inStoreChainName : nil
                            )
                                .contentShape(Rectangle())
                                .onTapGesture { detailItem = item }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button { onToggle(item) } label: {
                                        Label("Got it", systemImage: "checkmark.circle.fill")
                                    }
                                    .tint(.green)
                                }
                        }
                    }
                }

                if !gotItems.isEmpty {
                    Section("Got it ✓") {
                        ForEach(gotItems) { item in
                            BasketItemRow(item: item, offer: offers[item.id], isChecked: true)
                                .contentShape(Rectangle())
                                .onTapGesture { detailItem = item }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button { onToggle(item) } label: {
                                        Label("Undo", systemImage: "xmark.circle")
                                    }
                                    .tint(.gray)
                                }
                        }
                    }
                }

                // Finish the shop by scanning the receipt (records spend and tops
                // up the fridge). Sits at the very end of the list so it reads as
                // the last step, after everything has been ticked off.
                Section {
                    Button {
                        showReceiptScan = true
                    } label: {
                        Label("Scan Receipt to Finish", systemImage: "doc.text.viewfinder")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }
            .navigationTitle("Basket")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan", systemImage: "barcode.viewfinder")
                    }
                }
            }
            // Tick items off by scanning them as you pick them up.
            .fullScreenCover(isPresented: $showScanner) {
                BarcodeScannerView(
                    isShowing: $showScanner,
                    scannedBarcode: $scanBarcode,
                    productDetails: $scanProduct,
                    onNutritionScanned: { _ in },
                    onFrontLabelDetected: { _ in },
                    onProductResolved: { product in checkOffScanned(product) }
                )
            }
            // Primary action stays pinned: move the ticked-off items into the
            // fridge. (The receipt-scan finish is the last row of the list.)
            .safeAreaInset(edge: .bottom) {
                if !gotItems.isEmpty {
                    Button {
                        finishShop()
                    } label: {
                        Label("Add \(gotItems.count) to Fridge", systemImage: "refrigerator")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
            .sheet(isPresented: $showReceiptScan) {
                ReceiptScanView()
                    .environmentObject(frydgeManager)
                    .environmentObject(sharedFridgeManager)
            }
            // Brief scan feedback banner.
            .overlay(alignment: .top) {
                if let scanFeedback {
                    Text(scanFeedback)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(scanFeedbackIsHit ? Color.green : Color.orange,
                                    in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .sheet(item: $detailItem) { item in
                ShoppingListItemDetailSheet(item: item)
                    .environmentObject(frydgeManager)
                    .environmentObject(shoppingListManager)
                    .environmentObject(sharedShoppingListManager)
                    .environmentObject(appState)
            }
        }
    }

    // MARK: - Scan → check off

    /// Matches a scanned product to an unchecked basket item and ticks it off.
    private func checkOffScanned(_ product: ProductProtocol) {
        let scanned = (product.productName ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scanned.isEmpty else { return }

        if let match = uncheckedItems.first(where: { nameMatches($0.name, scanned) }) {
            onToggle(match)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showScanFeedback("✓ \(match.name)", hit: true)
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            showScanFeedback("Not on your list", hit: false)
        }
    }

    /// Loose name match: substring either way, or a shared word of 3+ letters.
    private func nameMatches(_ itemName: String, _ scanned: String) -> Bool {
        let item = itemName.lowercased()
        if scanned.contains(item) || item.contains(scanned) { return true }
        let itemTokens = Set(item.split(separator: " ").map(String.init).filter { $0.count >= 3 })
        let scanTokens = Set(scanned.split(separator: " ").map(String.init).filter { $0.count >= 3 })
        return !itemTokens.isDisjoint(with: scanTokens)
    }

    private func showScanFeedback(_ text: String, hit: Bool) {
        withAnimation { scanFeedback = text; scanFeedbackIsHit = hit }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { if scanFeedback == text { scanFeedback = nil } }
        }
    }

    // MARK: - Finish shop → fridge

    /// Moves the checked ("got it") items into the fridge and clears them from
    /// the shopping list, then closes the basket.
    private func finishShop() {
        for item in gotItems {
            frydgeManager.addAutoClassifiedProduct(
                name: item.name,
                quantity: item.quantity.isEmpty ? "1" : item.quantity,
                unit: item.unit,
                dietaryTags: item.dietaryTags
            )
            shoppingListManager.removeFromShoppingList(id: item.id)
        }
        // The shop is over: forget which store we were in so nothing stays
        // greyed out, and take the Live Activity down with it.
        InStoreSession.shared.end()
        ActivityManager.endActivity()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}

// MARK: - Basket Item Row

private struct BasketItemRow: View {
    let item: ShoppingListItem
    let offer: RetailOffer?
    let isChecked: Bool
    /// Chain name when the store we're in doesn't sell this item; the row
    /// fades and says so. nil = available or not in a store.
    var unavailableAt: String? = nil

    /// Product image already on disk (from the shopping list's store lookups),
    /// read synchronously from the local cache only — never a network fetch,
    /// so the basket renders in one pass.
    private var cachedThumbnail: UIImage? {
        let key = ProductImageCacheManager.shared.imageCacheKey(name: item.name, quantity: "", unit: "")
        return ProductImageCacheManager.shared.uiImage(forKey: key)
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.systemGray6))
                    .frame(width: 50, height: 50)
                if let image = cachedThumbnail {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Text(FoodEmoji.emoji(for: item.name))
                        .font(.system(size: 30))
                }
            }
            .opacity(isChecked ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(ProductShorthand.short(for: item.name))
                    .font(.body)
                    .strikethrough(isChecked, color: .secondary)
                    .foregroundStyle(isChecked ? .secondary : .primary)
                    .lineLimit(1)

                let qty = [item.quantity, item.unit].filter { !$0.isEmpty }.joined(separator: " ")
                if !qty.isEmpty {
                    Text(qty)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let unavailableAt {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 9))
                        Text("Not at \(unavailableAt)")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                } else if let offer {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        if let price = offer.priceText, !price.isEmpty {
                            Text(price)
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        Text("·").font(.caption).foregroundStyle(.secondary)
                        Text(offer.storeName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let product = offer.productTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !product.isEmpty, product.localizedCaseInsensitiveCompare(offer.storeName) != .orderedSame {
                        Text(product)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Image(systemName: isChecked ? "checkmark.circle.fill" : "chevron.right")
                .foregroundStyle(isChecked ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                .font(isChecked ? .body : .caption)
        }
        .padding(.vertical, 4)
        // Same fade as the main list for items this store doesn't sell.
        .inStoreGreyed(unavailableAt != nil)
    }
}
