//
//  FrydgeRecipesApp.swift
//  FrydgeRecipes
//
//  Created by Josh on 07/10/2024.
//

import SwiftUI
import CloudKit
import UIKit
import Combine

extension Notification.Name {
    static let openScanner = Notification.Name("openScanner")
    static let showInAppBanner = Notification.Name("showInAppBanner")
}

@main
struct FrydgeRecipesApp: App {
    @StateObject var appState = AppState()
    // Must be the singleton. LeftoverManager and RecipeShareIcon already reach for
    // FrydgeManager.shared, so constructing a second instance here gave the app two
    // live fridges — separate storedIngredients arrays and separate pendingSyncIDs,
    // both writing the same JSON file and the same CloudKit records, clobbering
    // each other on whichever saved last.
    @StateObject var frydgeManager = FrydgeManager.shared
    @StateObject var shoppingListManager = ShoppingListManager()
    @StateObject var invites = PendingInvites.shared
    @StateObject private var sharedShoppingListManager = SharedShoppingListManager()
    @StateObject private var sharedFridgeManager = SharedFridgeManager(containerID: "iCloud.com.Clark-Online.Recipe")
    @StateObject private var invitePresenter = InvitePresenter()
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @Environment(\.scenePhase) private var scenePhase

    // Ensures we only attempt subscription setup once per app launch/session.
    @State private var didConfigureCloudSubscriptions = false

    init() {
        // Registers the Siri phrases ("Add to Frydge", …) with the system so
        // voice add works from install, with no user setup.
        FrydgeAppShortcuts.updateAppShortcutParameters()

        // Mirror the editable profile fields to/from iCloud key-value store so
        // the user's profile follows them across devices.
        ProfileCloudSync.shared.start()

        // Point the Stripe SDK at the publishable key up front so Apple Pay and
        // card checkout work with no manual setup.
        StripeConfig.applyToStripeSDK()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(frydgeManager)
                .environmentObject(shoppingListManager)
                .environmentObject(invites)
                .environmentObject(sharedShoppingListManager)
                .environmentObject(sharedFridgeManager)
            // Household meal plan rides on the shared frydge anchors; give the
            // store the live manager so it never has to re-discover them.
                .task { SharedMealPlanStore.shared.attach(sharedFridgeManager) }
            
            // ✅ Unified URL ingestion:
            // - CloudKit share URLs (https://icloud.com/share/...)
            // - App deep links (e.g. frydgerecipes://import from Share Extension)
                .onOpenURL { url in
                    handleIncomingURL(url, source: "SwiftUI.onOpenURL")
                }
            
            // ✅ CloudKit share user-activity path stays intact
                .onContinueUserActivity("com.apple.cloudkit.share") { activity in
                    if let url = activity.webpageURL {
                        handleCloudKitShareURL(url, source: "SwiftUI.onContinueUserActivity.webpageURL")
                    } else if let url = activity.userInfo?["url"] as? URL {
                        handleCloudKitShareURL(url, source: "SwiftUI.onContinueUserActivity.userInfo.URL")
                    } else if let urlString = activity.userInfo?["url"] as? String, let url = URL(string: urlString) {
                        handleCloudKitShareURL(url, source: "SwiftUI.onContinueUserActivity.userInfo.String")
                    } else {
                        print("[INVITES] ContinueUserActivity had no URL payload")
                    }
                }

            // ✅ Universal links from frydge2.com, including shared recipe cards.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    handleIncomingURL(url, source: "SwiftUI.onContinueUserActivity.browsingWeb")
                }
            
            // ✅ Root-level invite sheet: shows regardless of where user is in the app (login/tab/any view)
                .sheet(isPresented: $invitePresenter.isShowingInvites) {
                    InvitationsView(onAccepted: {
                        Task {
                            // ✅ Refresh both managers when an invite is accepted
                            await sharedShoppingListManager.refreshSharedLists()
                            await sharedFridgeManager.reloadFridges()
                            invitePresenter.dismissIfEmpty()
                        }
                    })
                    .environmentObject(invites)
                }
            
            // ✅ Root-level import sheet (Share Extension -> App Group inbox -> deep link)
                .sheet(isPresented: $appState.showImportSheet) {
                    RecipeImportView(incomingURL: appState.pendingImportURL)
                        .environmentObject(appState)
                        .onDisappear {
                            // Clear once dismissed so it doesn't re-open
                            appState.pendingImportURL = nil
                        }
                }

            // ✅ Root-level payment collection (frydge://collect deep link)
                .fullScreenCover(item: $appState.pendingPayment) { payment in
                    DeepLinkPaymentRoot(payment: payment) { _ in
                        appState.pendingPayment = nil
                    }
                }

                .overlay(alignment: .top) {
                    if let banner = appState.banner {
                        AppBannerView(banner: banner) {
                            appState.dismissBanner()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(10)
                    }
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.88), value: appState.banner)

            // ✅ Root-level recipe creation sheet (frydge://create or in-app + button)
                .sheet(isPresented: $appState.showCreateRecipe) {
                    RecipeCreationFlowView(
                        onCancel: { appState.showCreateRecipe = false },
                        onComplete: { draft in
                            RecipeAuthor.saveDraftAsRecipe(draft)
                            appState.showCreateRecipe = false
                        }
                    )
                }
            
            // ✅ IMPORTANT: Create/repair CloudKit push subscriptions at launch
            // so users receive shared updates even if they never open the shared views.
                .task {
                    guard !didConfigureCloudSubscriptions else { return }
                    didConfigureCloudSubscriptions = true

                    await sharedShoppingListManager.configureSharedShoppingListNotificationsIfNeeded()
                    await sharedFridgeManager.configureSharedFrydgeNotificationsIfNeeded()

                    #if DEBUG
                    // Debug builds use CloudKit Development: make sure the
                    // household plan record types exist there with every field,
                    // so the schema can be deployed to Production.
                    await SharedMealPlanStore.shared.seedDevelopmentSchemaIfNeeded()
                    #endif
                }

            // Background image prefetch — user items first, then up to 100 common foods.
            // CommonFoodPreloader.preloadList puts items already in their fridge/list
            // at the front so the cache stays relevant, then fills remaining slots
            // from a curated base list. prefetchIfNeeded is a no-op for cached items.
                .task(priority: .background) {
                    while !Task.isCancelled {
                        let userNames = frydgeManager.storedIngredients.map(\.name)
                            + shoppingListManager.shoppingListItems.map(\.name)
                        let preloadList = CommonFoodPreloader.preloadList(merging: userNames)
                        await withTaskGroup(of: Void.self) { group in
                            var inFlight = 0
                            for name in preloadList {
                                guard !Task.isCancelled else { break }
                                if inFlight >= 8 {
                                    await group.next()
                                    inFlight -= 1
                                }
                                group.addTask(priority: .background) {
                                    await ProductImageCacheManager.shared.prefetchIfNeeded(for: name)
                                }
                                inFlight += 1
                            }
                        }
                        if CommonFoodPreloader.needsInitialPreload {
                            CommonFoodPreloader.markInitialPreloadDone()
                        }
                        try? await Task.sleep(for: .seconds(60))
                    }
                }
            
            // ✅ After a share is accepted, re-run subscription setup.
            // Acceptance can change the shared zones available on device.
                .onReceive(NotificationCenter.default.publisher(for: .cloudShareAccepted)) { notification in
                    Task { @MainActor in
                        print("[APP] 📢 Received cloudShareAccepted notification")
                        if let userInfo = notification.userInfo {
                            print("[APP] 📋 Share info: \(userInfo)")
                        }
                        
                        // Give CloudKit time to fully propagate the accepted share
                        print("[APP] ⏸️ Waiting for CloudKit propagation...")
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                        
                        print("[APP] 🔄 Refreshing managers and configuring notifications...")
                        
                        // Reload shared data first
                        async let fridgeReload: () = sharedFridgeManager.reloadFridges()
                        async let listReload: () = sharedShoppingListManager.refreshSharedLists()
                        _ = await (fridgeReload, listReload)
                        
                        // Then configure notifications for the new zones
                        async let fridgeNotif: () = sharedFridgeManager.configureSharedFrydgeNotificationsIfNeeded()
                        async let listNotif: () = sharedShoppingListManager.configureSharedShoppingListNotificationsIfNeeded()
                        _ = await (fridgeNotif, listNotif)
                        
                        print("[APP] ✅ Post-acceptance refresh complete")
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .cloudShareAcceptedMetadata)) { notification in
                    Task { @MainActor in
                        print("[APP] 📢 Received cloudShareAcceptedMetadata notification")
                        if let meta = notification.object as? CKShare.Metadata {
                            print("[APP] 📋 Accepted share: \(meta.share.recordID.recordName)")
                            print("[APP] 📋 Container: \(meta.containerIdentifier)")
                        }
                        
                        // Give CloudKit time to fully propagate the accepted share
                        print("[APP] ⏸️ Waiting for CloudKit propagation...")
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                        
                        print("[APP] 🔄 Refreshing managers and configuring notifications...")
                        
                        // Reload shared data first
                        async let fridgeReload: () = sharedFridgeManager.reloadFridges()
                        async let listReload: () = sharedShoppingListManager.refreshSharedLists()
                        _ = await (fridgeReload, listReload)
                        
                        // Then configure notifications for the new zones
                        async let fridgeNotif: () = sharedFridgeManager.configureSharedFrydgeNotificationsIfNeeded()
                        async let listNotif: () = sharedShoppingListManager.configureSharedShoppingListNotificationsIfNeeded()
                        _ = await (fridgeNotif, listNotif)
                        
                        print("[APP] ✅ Post-acceptance refresh complete")
                    }
                }
            
            // ✅ If metadata arrives via ANY path (AppDelegate/SceneDelegate/SwiftUI),
            // present the sheet immediately.
                .onReceive(invites.$metas) { metas in
                    if !metas.isEmpty {
                        invitePresenter.present()
                    } else {
                        invitePresenter.dismissIfEmpty()
                    }
                }
            
            // ✅ CRITICAL: Actually fetch data when CloudKit push notifications arrive
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SharedShoppingListChanged"))) { notification in
                    Task { @MainActor in
                        print("[APP] 🔔 SharedShoppingListChanged notification received - refreshing data...")
                        appState.showBanner(
                            title: "Shopping list updated",
                            message: "Shared changes are being refreshed.",
                            systemImage: "cart",
                            style: .info
                        )
                        await sharedShoppingListManager.refreshSharedLists()
                        print("[APP] ✅ Shopping list refresh complete")
                    }
                }
            
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SharedFrydgeChanged"))) { notification in
                    Task { @MainActor in
                        print("[APP] 🔔 SharedFrydgeChanged notification received - refreshing data...")
                        appState.showBanner(
                            title: "Frydge updated",
                            message: "Shared changes are being refreshed.",
                            systemImage: "refrigerator",
                            style: .info
                        )
                        await sharedFridgeManager.reloadFridges()
                        print("[APP] ✅ Frydge refresh complete")
                    }
                }

                .onReceive(NotificationCenter.default.publisher(for: .showInAppBanner)) { notification in
                    let info = notification.userInfo ?? [:]
                    let title = info["title"] as? String ?? "Notification"
                    let message = info["body"] as? String
                    let systemImage = info["systemImage"] as? String ?? "bell"
                    let styleName = info["style"] as? String ?? "info"
                    let style: AppBanner.Style

                    switch styleName {
                    case "success":
                        style = .success
                    case "warning":
                        style = .warning
                    case "error":
                        style = .error
                    default:
                        style = .info
                    }

                    appState.showBanner(
                        title: title,
                        message: message,
                        systemImage: systemImage,
                        style: style
                    )
                }

            // ✅ "Use it up" recipe tapped in an expiry notification. The id is
            // also parked in UserDefaults so a cold launch (where this
            // subscriber may not exist yet when the delegate posts) still opens it.
                .onReceive(NotificationCenter.default.publisher(for: .openRecipe)) { notification in
                    openPendingRecipeIfNeeded(explicitID: notification.userInfo?["recipeID"] as? String)
                }
                // Item name tapped in the store-arrival notification: jump to
                // the shopping list and open that item's detail sheet.
                .onReceive(NotificationCenter.default.publisher(for: .openShoppingItem)) { notification in
                    openPendingShoppingItemIfNeeded(explicit: notification.userInfo as? [String: String])
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    openPendingRecipeIfNeeded(explicitID: nil)
                    openPendingShoppingItemIfNeeded(explicit: nil)
                    openPendingBasketIfNeeded()
                }
                // A notification asked for the shopping list tab (the delegate
                // used to post this with nobody listening).
                .onReceive(NotificationCenter.default.publisher(for: .navigateToShoppingList)) { _ in
                    appState.selectedTab = .shoppingList
                }
                // Basket mode: arriving at a supermarket (geofence) or tapping
                // the arrival notification opens the in-store basket with the list.
                .onReceive(NotificationCenter.default.publisher(for: .storeArrived)) { notification in
                    let store = notification.userInfo?[StoreArrivalKeys.storeName] as? String ?? ""
                    let fromNotification = notification.userInfo?[StoreArrivalKeys.fromNotification] as? Bool ?? false
                    activateBasketMode(store: store, fromNotification: fromNotification)
                }

                .onAppear {
                    appDelegate.scheduleAppRefresh()

                    // Reset per-user caches if the iCloud account changed while
                    // the app was installed (repair plan D1).
                    AccountChangeMonitor.shared.start()

                    // Marketplace launch gate: pull the remote flag so a
                    // flip on the worker shows up without an app update.
                    MarketplaceAvailability.shared.refresh()

                    // First launch copies the bundled OFF product database into
                    // Application Support — keep that disk I/O off the main
                    // thread; barcode lookups lazily open the DB anyway.
                    Task.detached(priority: .utility) {
                        _ = OFFLocalDB.shared.prepareBundledDatabase()
                    }


                    // If we already have pending invites at launch, present immediately.
                    if !invites.metas.isEmpty {
                        invitePresenter.present()
                    }

                    // Apply any widget tick-offs queued while the app was background.
                    shoppingListManager.drainWidgetTicks()

                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        shoppingListManager.drainWidgetTicks()
                        MarketplaceAvailability.shared.refresh()

                        // Flush a disk write that failed earlier (device was
                        // locked, disk was full). saveToFile() no longer retries
                        // inline — it used to recurse into itself and overflow
                        // the stack — so the retry happens here instead.
                        shoppingListManager.retryPendingDiskSaveIfNeeded()

                        // Pull remote changes on foreground. Previously the only
                        // sync triggers were FridgeView/ShoppingListView onAppear,
                        // so edits made on another device stayed invisible until
                        // you happened to open that exact screen.
                        // Re-read the store on foreground. Both managers also observe
                        // NSPersistentStoreRemoteChange, so this is belt-and-braces
                        // for the case where a merge landed while suspended.
                        Task {
                            await frydgeManager.syncFromCloud()
                            await shoppingListManager.syncFromCloud()

                            // Hard-delete tombstones past the retention window.
                            await CoreDataHousekeeping.shared.purgeOldTombstones()
                        }
                    }
                }
        }
    }

    // MARK: - Core Data seed (Phase 2)

    /// Seeds Core Data from the JSON-backed managers. Safe to call repeatedly —
    /// every write upserts by UUID and the import flag stops it after one success.
    // MARK: - Unified URL Router

    private func handleIncomingURL(_ url: URL, source: String) {
        // 1) Our app deep links (Share Extension -> openURL)
        if handleRecipeImportDeepLink(url, source: source) {
            return
        }

        // 2) Frydge business deep links (frydge://collect, frydge://recipe/<id>, frydge://create)
        if handleFrydgeAppDeepLink(url, source: source) {
            return
        }

        // 3) Frydge universal links (https://frydge2.com/recipe/<id>)
        if handleFrydgeUniversalLink(url, source: source) {
            return
        }

        // 4) Only treat iCloud share links as CloudKit shares
        if let host = url.host?.lowercased(), host.contains("icloud.com") {
            handleCloudKitShareURL(url, source: source)
            return
        }

        print("[URL] Ignored non-import, non-iCloud URL (source=\(source)) url=\(url.absoluteString)")
    }

    // MARK: - Frydge App Deep Links (frydge://…)

    @discardableResult
    private func handleFrydgeAppDeepLink(_ url: URL, source: String) -> Bool {
        guard url.scheme?.lowercased() == "frydge" else { return false }
        let host = url.host?.lowercased() ?? ""

        switch host {
        case "collect":
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let items = comps?.queryItems ?? []
            let orderId = items.first { $0.name == "orderId" }?.value ?? ""
            let orgId = items.first { $0.name == "orgId" }?.value
                ?? items.first { $0.name == "venueId" }?.value
                ?? items.first { $0.name == "storeId" }?.value
            let amountStr = items.first { $0.name == "amount" }?.value ?? "0"
            let clientSecret = items.first { $0.name == "cs" }?.value ?? ""
            let customer = items.first { $0.name == "name" }?.value

            guard !orderId.isEmpty, !clientSecret.isEmpty, let amount = Double(amountStr) else {
                print("[PAY] Ignored malformed collect URL (source=\(source)) url=\(url.absoluteString)")
                return true
            }

            let payment = PendingPayment(
                orderId: orderId,
                orgId: orgId,
                amount: amount,
                clientSecret: clientSecret,
                customerName: customer
            )

            Task { @MainActor in
                appState.showImportSheet = false
                appState.showCreateRecipe = false
                appState.pendingPayment = nil
                DispatchQueue.main.async {
                    appState.pendingPayment = payment
                    print("[PAY] Presenting collect screen orderId=\(orderId)")
                }
                print("[PAY] Deep link collect (source=\(source)) orderId=\(orderId) orgId=\(orgId ?? "<nil>") amount=\(amount)")
            }
            return true

        case "recipe":
            // frydge://recipe/<id>
            let id = url.pathComponents.dropFirst().joined(separator: "/")
            guard !id.isEmpty else {
                print("[RECIPE] Deep link missing id (source=\(source)) url=\(url.absoluteString)")
                return true
            }
            Task { @MainActor in
                appState.selectedTab = .recipes
                appState.lastViewedRecipeID = id
                print("[RECIPE] Deep link recipe id=\(id) (source=\(source))")
            }
            return true

        case "create":
            Task { @MainActor in
                appState.showCreateRecipe = true
                print("[RECIPE] Deep link create (source=\(source))")
            }
            return true

        default:
            print("[URL] Unknown frydge:// host '\(host)' (source=\(source)) url=\(url.absoluteString)")
            return true
        }
    }

    /// Opens a recipe requested from a notification (see
    /// AppDelegate.openRecipeTappedInNotificationIfAny), then clears the
    /// request so it doesn't re-open on the next activation. Same route as
    /// the frydge://recipe/<id> deep link.
    private func openPendingRecipeIfNeeded(explicitID: String?) {
        let key = FrydgeManager.ExpiryNotificationKeys.pendingOpenRecipeID
        let pending = explicitID ?? UserDefaults.standard.string(forKey: key)
        guard let id = pending?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: key)

        Task { @MainActor in
            appState.selectedTab = .recipes
            appState.lastViewedRecipeID = id
            print("[RECIPE] Opening recipe id=\(id) from expiry notification")
        }
    }

    /// Opens a shopping item requested from the store-arrival notification
    /// (see AppDelegate.openShoppingItemTappedInNotificationIfAny), then
    /// clears the request so it doesn't re-open on the next activation.
    private func openPendingShoppingItemIfNeeded(explicit: [String: String]?) {
        let key = ShoppingNotificationKeys.pendingOpenItem
        let pending = explicit ?? (UserDefaults.standard.dictionary(forKey: key) as? [String: String])
        guard let entry = pending else { return }
        let id = (entry["id"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (entry["fullName"] ?? entry["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty || !name.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: key)

        let store = (entry["store"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            appState.selectedTab = .shoppingList
            appState.pendingShoppingItemDetail = ShoppingItemDetailRequest(
                itemID: id,
                name: name,
                storeName: store.isEmpty ? nil : store
            )
            print("[SHOPPING] Opening item '\(name)' (id=\(id)) from store notification")
        }
    }

    // MARK: - Basket mode on store arrival

    /// Switches the app into basket mode: jumps to the shopping list tab and
    /// opens the in-store basket with the current list.
    ///
    /// - A tap on the arrival notification always opens it.
    /// - A live geofence entry only opens it while the app is actually on
    ///   screen, at most once per store every two hours (same cooldown as
    ///   the notification), and never for an empty list.
    private func activateBasketMode(store: String, fromNotification: Bool) {
        UserDefaults.standard.removeObject(forKey: StoreArrivalKeys.pendingOpenBasket)

        // The in-store session is set before any guard below: even if the
        // list is empty or the auto-open is on cooldown, the app should know
        // which shop it's in so anything added now greys out correctly.
        if !store.isEmpty {
            Task { @MainActor in
                InStoreSession.shared.begin(
                    storeName: store,
                    source: fromNotification ? .notification : .geofence
                )
            }
        }

        guard !shoppingListManager.shoppingListItems.isEmpty else {
            print("[BASKET] Store arrival at '\(store)' ignored — shopping list is empty")
            return
        }

        if !fromNotification {
            guard scenePhase == .active else { return }
            let cooldownKey = "basketAutoOpen_\(store)"
            if let last = UserDefaults.standard.object(forKey: cooldownKey) as? Date,
               Date().timeIntervalSince(last) < 2 * 60 * 60 {
                return
            }
            UserDefaults.standard.set(Date(), forKey: cooldownKey)
        }

        Task { @MainActor in
            appState.openShoppingBasket()
            let title = store.isEmpty ? "Basket mode" : "You're at \(store)"
            let count = shoppingListManager.shoppingListItems.count
            appState.showBanner(
                title: title,
                message: "Basket mode on — \(count) item\(count == 1 ? "" : "s") to get.",
                systemImage: "basket.fill",
                style: .info
            )
            print("[BASKET] Basket mode activated for '\(store)' (fromNotification=\(fromNotification))")
        }
    }

    /// Cold launch from the arrival notification: the delegate parked the
    /// store name before the SwiftUI subscriber existed.
    private func openPendingBasketIfNeeded() {
        guard let store = UserDefaults.standard.string(forKey: StoreArrivalKeys.pendingOpenBasket) else { return }
        activateBasketMode(store: store, fromNotification: true)
    }

    // MARK: - Frydge Universal Links (https://frydge2.com/…)

    @discardableResult
    private func handleFrydgeUniversalLink(_ url: URL, source: String) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "frydge2.com" else {
            return false
        }

        let components = url.pathComponents
        guard components.count >= 3, components[1].lowercased() == "recipe" else {
            print("[URL] Ignored frydge2.com non-recipe URL (source=\(source)) url=\(url.absoluteString)")
            return true
        }

        let id = components.dropFirst(2).joined(separator: "/")
        guard !id.isEmpty else {
            print("[RECIPE] Universal link missing id (source=\(source)) url=\(url.absoluteString)")
            return true
        }

        Task { @MainActor in
            appState.selectedTab = .recipes
            appState.lastViewedRecipeID = id
            print("[RECIPE] Universal link recipe id=\(id) (source=\(source))")
        }
        return true
    }

    // MARK: - Recipe Import Deep Link Handling

    private func handleRecipeImportDeepLink(_ url: URL, source: String) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        guard scheme == "frydgerecipes" else { return false }

        let host = url.host?.lowercased() ?? ""

        if host == "import" {
            Task { @MainActor in
                if let sharedURL = RecipeImportManager.readInboxURLAndClear() {
                    print("[IMPORT] Deep link received (source=\(source)) -> \(sharedURL.absoluteString)")
                    let host = sharedURL.host ?? "shared link"
                    appState.showBanner(
                        title: "Recipe link received",
                        message: "Downloading from \(host).",
                        systemImage: "arrow.down.doc",
                        style: .info,
                        duration: 3
                    )

                    // Force a clean present even if something was mid-transition
                    appState.pendingImportURL = sharedURL
                    appState.showImportSheet = false
                    DispatchQueue.main.async {
                        appState.showImportSheet = true
                    }
                } else {
                    print("[IMPORT] Deep link received but inbox empty (source=\(source))")
                    appState.showBanner(
                        title: "Import not found",
                        message: "Open Frydge and try sharing the recipe again.",
                        systemImage: "exclamationmark.triangle",
                        style: .warning
                    )
                }
            }

            return true
        }

        if host == "import-video" {
            Task { @MainActor in
                print("[IMPORT] Video deep link received (source=\(source))")
                appState.pendingImportURL = nil
                appState.showImportSheet = false
                DispatchQueue.main.async {
                    appState.showImportSheet = true
                }
            }
            return true
        }

        if host == "shopping-list" {
            Task { @MainActor in
                print("[PRODUCT] Shopping list deep link received source=\(source)")
                appState.showImportSheet = false
                appState.showCreateRecipe = false
                appState.pendingPayment = nil
                appState.showProductDetailsFromWidget = false
                appState.productDetailsFromWidgetAutoStartScanner = false
                appState.selectedTab = .shoppingList
            }
            return true
        }

        // frydgerecipes://basket — widget / Control Center shortcut to the
        // in-store basket with the running total.
        if host == "basket" {
            Task { @MainActor in
                print("[PRODUCT] Basket deep link received source=\(source)")
                appState.showImportSheet = false
                appState.showCreateRecipe = false
                appState.pendingPayment = nil
                appState.showProductDetailsFromWidget = false
                appState.productDetailsFromWidgetAutoStartScanner = false
                appState.openShoppingBasket()
            }
            return true
        }

        // frydgerecipes://item/<id>?name=…&store=… — a shopping row tapped in
        // the widget. Reuses the store-notification detail route, which falls
        // back to a name match if the id has already left the list.
        if host == "item" {
            let id = url.pathComponents.dropFirst().first ?? ""
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let name = query.first { $0.name == "name" }?.value ?? ""
            let store = query.first { $0.name == "store" }?.value
            guard !id.isEmpty || !name.isEmpty else { return true }
            Task { @MainActor in
                print("[SHOPPING] Widget item deep link id=\(id) name=\(name) source=\(source)")
                appState.showImportSheet = false
                appState.showCreateRecipe = false
                appState.pendingPayment = nil
                appState.showProductDetailsFromWidget = false
                appState.productDetailsFromWidgetAutoStartScanner = false
                appState.selectedTab = .shoppingList
                appState.pendingShoppingItemDetail = ShoppingItemDetailRequest(
                    itemID: id,
                    name: name,
                    storeName: (store?.isEmpty == false) ? store : nil
                )
            }
            return true
        }

        if host == "scan" || host == "add-product" {
            Task { @MainActor in
                let shouldScan = host == "scan"
                print("[PRODUCT] Deep link received host=\(host) source=\(source)")
                appState.showImportSheet = false
                appState.showCreateRecipe = false
                appState.pendingPayment = nil
                appState.selectedTab = .shoppingList
                appState.showProductDetailsFromWidget = false
                appState.productDetailsFromWidgetAutoStartScanner = shouldScan
                DispatchQueue.main.async {
                    appState.showProductDetailsFromWidget = true
                }
            }
            return true
        }

        print("[IMPORT] Ignored deep link (source=\(source)) url=\(url.absoluteString)")
        return true
    }

    // MARK: - CloudKit Share URL Handling (Metadata Fetch)

    private func handleCloudKitShareURL(_ url: URL, source: String) {
        // CloudKit invitation links require metadata fetch.
        let containerID = "iCloud.com.Clark-Online.Recipe"
        let op = CKFetchShareMetadataOperation(shareURLs: [url])

        print("[INVITES] handleCloudKitShareURL source=\(source) url=\(url.absoluteString)")

        op.fetchShareMetadataResultBlock = { result in
            if case .failure(let error) = result {
                print("[INVITES] Fetch share metadata failed (source=\(source)): \(error)")
            } else {
                print("[INVITES] Fetch share metadata completed (source=\(source))")
            }
        }

        op.perShareMetadataResultBlock = { _, result in
            switch result {
            case .success(let metadata):
                Task { @MainActor in
                    PendingInvites.shared.add(meta: metadata)
                    // Present immediately (root sheet)
                    invitePresenter.present()
                    print("[INVITES] Added via SwiftUI external event (source=\(source))")
                }
            case .failure(let error):
                print("[INVITES] Failed to fetch metadata (source=\(source)): \(error)")
            }
        }

        CKContainer(identifier: containerID).add(op)
    }
}

private struct AppBannerView: View {
    let banner: AppBanner
    let dismiss: () -> Void

    private var tint: Color {
        switch banner.style {
        case .info:
            return .blue
        case .success:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: banner.systemImage)
                .font(.headline)
                .foregroundColor(tint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .lineLimit(2)

                if let message = banner.message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notification")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 16, x: 0, y: 8)
    }
}

// MARK: - Root Invite Presentation Coordinator

@MainActor
final class InvitePresenter: ObservableObject {
    @Published var isShowingInvites: Bool = false

    func present() {
        // Avoid repeated toggles; still allow re-open if dismissed while metas exist.
        if !isShowingInvites {
            isShowingInvites = true
        }
    }

    func dismissIfEmpty() {
        // Only dismiss if there are no pending invites.
        if PendingInvites.shared.metas.isEmpty {
            isShowingInvites = false
        }
    }
}
