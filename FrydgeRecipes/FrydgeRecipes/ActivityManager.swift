//
//  ActivityManager.swift
//  FrydgeRecipes
//

import Foundation
import ActivityKit
import UIKit

class ActivityManager {
    static var currentActivity: Activity<ShoppingListActivityAttributes>?

    // ActivityKit only allows *starting* a Live Activity while the app is in the
    // foreground. Region monitoring fires in the background, so we stash the store
    // name and start the activity the moment the app next becomes active — e.g. when
    // the user taps the store-arrival notification. (Updates/ends are background-legal.)
    private static let pendingStoreKey = "pendingLiveActivityStore"
    private static let pendingStoreDateKey = "pendingLiveActivityStoreDate"
    private static let pendingStoreMaxAge: TimeInterval = 60 * 60 // 1 hour
    private static var appGroupDefaults: UserDefaults? {
        UserDefaults(suiteName: "group.Clark-Online.FrydgeRecipeAPN")
    }

    /// Whether the app is foreground-active.
    ///
    /// Was `DispatchQueue.main.sync { … }` when called off the main thread, which
    /// deadlocks if the main thread is itself waiting on the calling thread — and
    /// touched `UIApplication.shared` from a background thread, which is not
    /// allowed at all. Callers now hop to the main actor instead of blocking.
    @MainActor
    private static var isAppActive: Bool {
        UIApplication.shared.applicationState == .active
    }

    /// Backgrounded: ActivityKit won't let us call `Activity.request`, so do both
    /// of the things that can work.
    ///
    ///   1. Ask APNs to push-to-start the activity. This is the automatic path,
    ///      but it needs signal and a few seconds of background time.
    ///   2. Stash the store so `flushPendingStart()` still raises the activity
    ///      when the user next opens the app.
    ///
    /// Both are kept deliberately. If the push lands, `startActivityNow` finds
    /// the existing activity and updates it rather than creating a duplicate.
    /// Last push-to-start request, to collapse duplicates. Every arrival fires
    /// twice (didEnterRegion + didDetermineState) seconds apart, and iOS
    /// silently rate-limits apps that spam start pushes — one is enough.
    private static var lastPushRequest: (store: String, at: Date)?
    private static let pushRequestDedupeWindow: TimeInterval = 120

    @MainActor
    private static func deferStart(for storeName: String) {
        if let last = lastPushRequest,
           last.store == storeName,
           Date().timeIntervalSince(last.at) < pushRequestDedupeWindow {
            print("[LIVE] Push-to-start for \(storeName) already requested \(Int(Date().timeIntervalSince(last.at)))s ago — skipping duplicate")
            return
        }
        lastPushRequest = (storeName, Date())

        print("[LIVE] App not active — requesting push-to-start for \(storeName)")

        LiveActivityPushManager.shared.requestStart(
            storeName: storeName,
            items: loadMergedShoppingList(for: storeName).items
        )

        appGroupDefaults?.set(storeName, forKey: pendingStoreKey)
        appGroupDefaults?.set(Date(), forKey: pendingStoreDateKey)
    }

    /// True when a shopping Live Activity is already on screen.
    private static var hasActiveActivity: Bool {
        Activity<ShoppingListActivityAttributes>.activities.contains {
            $0.activityState == .active || $0.activityState == .stale
        }
    }

    static func startActivity(for storeName: String) {
        // Only REQUESTING a new activity needs the app in the foreground.
        // UPDATING an existing one works from the background, so when the
        // toggle is already on, retarget it in place rather than deferring —
        // deferral goes via push-to-start, which would spawn a second activity
        // instead of moving the existing one to the new store.
        @MainActor func run() {
            if isAppActive || hasActiveActivity {
                startActivityNow(for: storeName)
            } else {
                deferStart(for: storeName)
            }
        }

        // CLLocationManager delegate callbacks arrive on the main thread, so this
        // usually runs inline without a hop.
        if Thread.isMainThread {
            MainActor.assumeIsolated { run() }
        } else {
            Task { @MainActor in run() }
        }
    }

    /// Starts any Live Activity that was deferred while the app was in the background.
    /// Call this when the app becomes active.
    static func flushPendingStart() {
        guard let ud = appGroupDefaults,
              let storeName = ud.string(forKey: pendingStoreKey) else { return }

        let recordedAt = ud.object(forKey: pendingStoreDateKey) as? Date
        ud.removeObject(forKey: pendingStoreKey)
        ud.removeObject(forKey: pendingStoreDateKey)

        if let recordedAt, Date().timeIntervalSince(recordedAt) > pendingStoreMaxAge {
            print("[LIVE] Pending start for \(storeName) expired — skipping")
            return
        }

        print("[LIVE] Flushing deferred Live Activity start for \(storeName)")
        startActivityNow(for: storeName)
    }

    /// Publishes the store the shopper is at so the extension's Control Centre
    /// start can brand its banner (it reads `FrydgeAppGroup.storeNameKeys`).
    static func publishCurrentStore(_ storeName: String) {
        let trimmed = storeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appGroupDefaults?.set(trimmed, forKey: "currentStoreName")
    }

    private static func startActivityNow(for storeName: String) {
        publishCurrentStore(storeName)
        let authInfo = ActivityAuthorizationInfo()
        print("[LIVE] areActivitiesEnabled=\(authInfo.areActivitiesEnabled) store=\(storeName)")
        guard authInfo.areActivitiesEnabled else {
            print("[ERROR] Live Activities are not enabled — check Settings → \(storeName.components(separatedBy: " ").first ?? "App") → Live Activities and Settings → Face ID & Passcode → Live Activities.")
            return
        }

        // Resolve any existing activity, but only if it's still active.
        // A stale/ended activity in .activities will be in .dismissed or .ended state.
        let liveActivities = Activity<ShoppingListActivityAttributes>.activities
        print("[LIVE] existing activities count=\(liveActivities.count) states=\(liveActivities.map { "\($0.activityState)" })")

        let activeActivity = liveActivities.first {
            $0.activityState == .active || $0.activityState == .stale
        }

        // Clear stale reference if it's no longer active
        if let current = currentActivity,
           current.activityState != .active && current.activityState != .stale {
            print("[LIVE] Clearing stale currentActivity (state=\(current.activityState))")
            currentActivity = nil
        }

        let resolvedActivity = currentActivity ?? activeActivity
        let merged = loadMergedShoppingList(for: storeName)
        let items = merged.items
        print("[LIVE] startActivity store=\(storeName) items count=\(items.count)")

        if let activity = resolvedActivity {
            currentActivity = activity

            // Retarget the existing activity — the "toggle" stays on and follows
            // the shopper from store to store. storeName in the state is what
            // lets the banner switch name/logo/prices without a restart
            // (attributes are frozen by ActivityKit).
            let previousStore = activity.content.state.storeName ?? activity.attributes.storeName
            let updatedState = ShoppingListActivityAttributes.ContentState(
                shoppingListItems: items,
                checkedItems: activity.content.state.checkedItems.filter { items.contains($0) },
                storeName: storeName,
                itemEmojis: merged.emojis,
                unavailableItems: merged.unavailable,
                // Arriving at a store mid-recipe must not knock the banner out
                // of cook mode — the "still to grab" strip just gets fresh prices.
                cooking: activity.content.state.cooking
            )

            let updatedContent = ActivityContent(state: updatedState, staleDate: nil)

            Task {
                await activity.update(updatedContent)
                if previousStore != storeName {
                    print("[INFO] Live Activity retargeted \(previousStore) → \(storeName) with \(items.count) items")
                } else {
                    print("[INFO] Live Activity updated for \(storeName) with \(items.count) items")
                }
            }
            return
        }

        let contentState = ShoppingListActivityAttributes.ContentState(
            shoppingListItems: items,
            checkedItems: [],
            storeName: storeName,
            itemEmojis: merged.emojis,
            unavailableItems: merged.unavailable
        )

        let attributes = ShoppingListActivityAttributes(storeName: storeName)
        let content = ActivityContent(state: contentState, staleDate: nil)

        do {
            // pushType: .token — was nil, which meant the activity had no update
            // token and could never be refreshed remotely. Required if the list
            // is to be updated by push while the app is backgrounded.
            currentActivity = try Activity<ShoppingListActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: .token
            )
            print("[INFO] Live Activity started for \(storeName) with \(items.count) items, id=\(currentActivity?.id ?? "nil")")
        } catch {
            print("[ERROR] Failed to start Live Activity: \(error) — full: \(String(describing: error))")
        }
    }

    static func updateActivity(checkedItem: String? = nil, storeName: String? = nil) {
        // Only an activity that is still on screen can take an update. The old
        // `currentActivity ?? .activities.first` fallback could pick an ended
        // or dismissed one (they linger in `.activities`), so the live banner
        // silently stopped refreshing.
        guard let activity = liveActivity() else { return }
        currentActivity = activity

        // Prefer the state's store (which follows the shopper between stores)
        // over the attributes' store (frozen at whichever store started the activity).
        let effectiveStoreName = storeName
            ?? activity.content.state.storeName
            ?? activity.attributes.storeName
        let merged = loadMergedShoppingList(for: effectiveStoreName)
        let latestItems = merged.items
        print("[LIVE] updateActivity store=\(effectiveStoreName) items=\(latestItems)")
        let previous = activity.content.state

        var updatedCheckedItems = previous.checkedItems.filter { latestItems.contains($0) }

        if let checkedItem, latestItems.contains(checkedItem), !updatedCheckedItems.contains(checkedItem) {
            updatedCheckedItems.append(checkedItem)
        }

        let updatedState = ShoppingListActivityAttributes.ContentState(
            shoppingListItems: latestItems,
            checkedItems: updatedCheckedItems,
            storeName: effectiveStoreName,
            itemEmojis: merged.emojis,
            unavailableItems: merged.unavailable,
            // List edits while cooking refresh the "still to grab" strip only.
            cooking: previous.cooking
        )

        let updatedContent = ActivityContent(state: updatedState, staleDate: nil)

        Task {
            await activity.update(updatedContent)
            print("[INFO] Live Activity refreshed for \(effectiveStoreName) with \(latestItems.count) items")
        }
    }

    static func endActivity() {
        Task {
            // End every activity that is still showing, not just the first one
            // in `.activities`. A push-to-start that landed alongside a local
            // request leaves two on the Lock Screen, and the old `.first`
            // fallback could even pick an already-ended one and leave the
            // visible banner up for good.
            let live = Activity<ShoppingListActivityAttributes>.activities.filter {
                $0.activityState == .active || $0.activityState == .stale
            }
            guard !live.isEmpty else {
                currentActivity = nil
                return
            }

            for activity in live {
                await activity.end(activity.content, dismissalPolicy: .immediate)
            }
            currentActivity = nil
            // The shop is over, so cook mode no longer owns a banner either.
            appGroupDefaults?.removeObject(forKey: cookingOwnsActivityKey)
            print("[INFO] Live Activity ended (\(live.count)).")
        }
    }

    // MARK: - Cooking takeover
    //
    // Starting a recipe in cook mode flips the Live Activity into its cooking
    // face (step, live timer, "still to grab" strip). It reuses the shopping
    // activity when one is up — so arriving at a store mid-recipe just refreshes
    // the strip — and raises one itself otherwise. Cook mode runs in the
    // foreground, which is the only place ActivityKit lets us *create* one.

    /// Set when cook mode had to create the activity itself. Ending the cook
    /// then takes the activity down too; otherwise it just hands the banner
    /// back to the shopping layout.
    private static let cookingOwnsActivityKey = "liveActivityStartedByCooking"

    /// Serialises cook-mode changes so a step update can't overtake the
    /// request that creates the activity.
    private static var cookingQueue: Task<Void, Never>?

    private static func enqueueCooking(_ work: @escaping @MainActor () async -> Void) {
        let previous = cookingQueue
        cookingQueue = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// The activity that is on screen right now, if any.
    private static func liveActivity() -> Activity<ShoppingListActivityAttributes>? {
        if let current = currentActivity,
           current.activityState == .active || current.activityState == .stale {
            return current
        }
        return Activity<ShoppingListActivityAttributes>.activities.first {
            $0.activityState == .active || $0.activityState == .stale
        }
    }

    private static func applyTimer(_ cooking: inout ShoppingListActivityAttributes.CookingState, seconds: Int?) {
        if let seconds, seconds > 0 {
            let now = Date()
            cooking.timerStartedAt = now
            cooking.timerEndsAt = now.addingTimeInterval(TimeInterval(seconds))
        } else {
            cooking.timerStartedAt = nil
            cooking.timerEndsAt = nil
        }
    }

    /// Puts the Live Activity into cook mode for a freshly started recipe.
    /// `relevanceScore` is raised so, with other activities around, this one is
    /// the one the Dynamic Island and Lock Screen put in front.
    static func beginCooking(recipeName: String, stepIndex: Int, stepCount: Int, stepText: String, timerSeconds: Int?) {
        enqueueCooking {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                print("[LIVE] Cook mode: Live Activities are disabled — nothing to show on the Lock Screen")
                return
            }

            var cooking = ShoppingListActivityAttributes.CookingState(
                recipeName: recipeName,
                recipeEmoji: FoodEmoji.emoji(for: recipeName),
                stepIndex: stepIndex,
                stepCount: stepCount,
                stepText: stepText,
                startedAt: Date()
            )
            applyTimer(&cooking, seconds: timerSeconds)

            if let activity = liveActivity() {
                currentActivity = activity
                var state = activity.content.state
                state.cooking = cooking
                await activity.update(ActivityContent(state: state, staleDate: nil, relevanceScore: 100))
                appGroupDefaults?.set(false, forKey: cookingOwnsActivityKey)
                print("[LIVE] Cook mode took over the shopping activity for \(recipeName)")
                return
            }

            // Nothing on screen yet — raise one, carrying the shopping list so
            // the "still to grab" strip can show what's missing.
            let storeName = WidgetSnapshot.read().nearestStoreName ?? ""
            let merged = loadMergedShoppingList(for: storeName)
            let state = ShoppingListActivityAttributes.ContentState(
                shoppingListItems: merged.items,
                checkedItems: [],
                storeName: storeName,
                itemEmojis: merged.emojis,
                cooking: cooking
            )

            do {
                currentActivity = try Activity<ShoppingListActivityAttributes>.request(
                    attributes: ShoppingListActivityAttributes(storeName: storeName),
                    content: ActivityContent(state: state, staleDate: nil, relevanceScore: 100),
                    pushType: .token
                )
                appGroupDefaults?.set(true, forKey: cookingOwnsActivityKey)
                print("[LIVE] Cook mode started a Live Activity for \(recipeName), id=\(currentActivity?.id ?? "nil")")
            } catch {
                print("[ERROR] Cook mode failed to start a Live Activity: \(error)")
            }
        }
    }

    /// Moves the banner to another step and starts (or clears) its timer.
    static func updateCooking(stepIndex: Int, stepText: String, timerSeconds: Int?) {
        enqueueCooking {
            guard let activity = liveActivity(), var cooking = activity.content.state.cooking else { return }
            cooking.stepIndex = stepIndex
            cooking.stepText = stepText
            applyTimer(&cooking, seconds: timerSeconds)

            var state = activity.content.state
            state.cooking = cooking
            await activity.update(ActivityContent(state: state, staleDate: nil, relevanceScore: 100))
        }
    }

    /// The step timer finished — swap the countdown back to elapsed cook time.
    static func clearCookingTimer() {
        enqueueCooking {
            guard let activity = liveActivity(), var cooking = activity.content.state.cooking,
                  cooking.timerEndsAt != nil else { return }
            applyTimer(&cooking, seconds: nil)

            var state = activity.content.state
            state.cooking = cooking
            await activity.update(ActivityContent(state: state, staleDate: nil, relevanceScore: 100))
        }
    }

    /// Cook mode finished or was abandoned: hand the banner back to the shopping
    /// list, or take it down entirely if cooking was the only reason it was up.
    static func endCooking() {
        enqueueCooking {
            guard let activity = liveActivity(), activity.content.state.cooking != nil else { return }
            var state = activity.content.state
            state.cooking = nil

            let ownsActivity = appGroupDefaults?.bool(forKey: cookingOwnsActivityKey) ?? false
            appGroupDefaults?.removeObject(forKey: cookingOwnsActivityKey)

            if ownsActivity {
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
                if currentActivity?.id == activity.id { currentActivity = nil }
                print("[LIVE] Cook mode ended — Live Activity dismissed")
            } else {
                await activity.update(ActivityContent(state: state, staleDate: nil))
                print("[LIVE] Cook mode ended — Live Activity back to shopping")
            }
        }
    }

    // MARK: - Shopping list merge

    /// The strings shown in the Live Activity plus a food emoji for each, so
    /// its rows can match the widget's.
    struct MergedShoppingList {
        var items: [String]
        var emojis: [String: String]
        /// Subset of `items` the current store doesn't sell, per the shopping
        /// list's in-store availability snapshot. Empty when unknown.
        var unavailable: [String] = []
    }

    private static func loadMergedShoppingList(for storeName: String) -> MergedShoppingList {
        guard let ud = UserDefaults(suiteName: "group.Clark-Online.FrydgeRecipeAPN") else {
            print("[LIVE] app group unavailable")
            return MergedShoppingList(items: [], emojis: [:])
        }

        func decodeStructured(_ key: String) -> [WidgetItem] {
            if let json = ud.string(forKey: key),
               let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([WidgetItem].self, from: data) {
                return decoded
            }

            if let data = ud.data(forKey: key),
               let decoded = try? JSONDecoder().decode([WidgetItem].self, from: data) {
                return decoded
            }

            return []
        }

        func decodeLegacy(_ key: String) -> [WidgetItem] {
            let legacyKey = key == "shoppingListItemsJSON" ? "shoppingList" : "sharedShoppingList"
            if let legacy = ud.array(forKey: legacyKey) as? [String] {
                return legacy.map {
                    WidgetItem(id: UUID().uuidString, name: $0, quantity: "", unit: "")
                }
            }
            return []
        }

        let mineStructured = decodeStructured("shoppingListItemsJSON")
        let sharedStructured = decodeStructured("sharedShoppingListItemsJSON")
        let mine = mineStructured.isEmpty ? decodeLegacy("shoppingListItemsJSON") : mineStructured
        let shared = sharedStructured.isEmpty ? decodeLegacy("sharedShoppingListItemsJSON") : sharedStructured
        let pricedNames = loadCachedStorePrices(for: storeName, userDefaults: ud)

        print("[LIVE] local count=\(mine.count) shared count=\(shared.count) priced count=\(pricedNames.count)")

        var seen: Set<String> = []
        var merged: [String] = []
        var emojis: [String: String] = [:]
        merged.reserveCapacity(mine.count + shared.count)

        // Sticky prices: once an item has shown a price, keep showing it until
        // a fresh fetch supplies a different one. Without this, any merge that
        // runs while the price source is momentarily empty (fetcher hasn't run,
        // store switch mid-trip) strips prices and the total flickers.
        var sticky = loadStickyPrices(ud)
        var stickyChanged = false

        // Items the shopping list worked out this chain doesn't sell. Only
        // trusted when the snapshot is for the store we're rendering; a
        // snapshot for another chain (or none) greys nothing.
        let unavailableKeys: Set<String> = {
            guard let snap = InStoreAvailabilitySnapshot.read(),
                  snap.chainKey == StoreChain.key(for: storeName) else { return [] }
            return Set(snap.unavailableNames)
        }()
        var unavailable: [String] = []

        for item in mine + shared {
            let base = item.displayString
            let normalized = base
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)

            let nameKey = normalizeItemName(item.name)
            let isUnavailableHere = unavailableKeys.contains(StoreAvailabilityResolver.normalizedItemKey(item.name))
            let line: String

            if let price = matchedPrice(for: item, pricedNames: pricedNames) {
                line = "\(base) \(price)"

                let existing = sticky[nameKey]
                if existing?.priceText != price
                    || (existing.map { Date().timeIntervalSince($0.updatedAt) > 24 * 3600 } ?? true) {
                    sticky[nameKey] = StickyPrice(priceText: price, storeName: storeName, updatedAt: Date())
                    stickyChanged = true
                }
            } else if let known = sticky[nameKey],
                      Date().timeIntervalSince(known.updatedAt) < stickyPriceMaxAge {
                line = "\(base) \(known.priceText)"
            } else {
                line = base
            }

            merged.append(line)
            emojis[line] = FoodEmoji.emoji(for: item.name)
            if isUnavailableHere { unavailable.append(line) }
        }

        if stickyChanged {
            saveStickyPrices(sticky, to: ud)
        }

        if merged.isEmpty {
            print("[LIVE] merged list empty for store=\(storeName)")
        }
        if !unavailable.isEmpty {
            print("[LIVE] \(unavailable.count) item(s) not sold at \(storeName)")
        }

        // Same food-type order as the fridge and shopping list screens, so the
        // Lock Screen reads the way the app does: meat first, seasoning last.
        return MergedShoppingList(
            items: merged.sorted(by: ShopAisle.precedes),
            emojis: emojis,
            unavailable: unavailable
        )
    }

    // MARK: - Sticky last-known prices

    private static let stickyPricesKey = "liveActivityLastKnownPrices"

    /// A remembered price stops being trustworthy eventually; a month is well
    /// past any realistic gap between price fetches.
    private static let stickyPriceMaxAge: TimeInterval = 30 * 24 * 3600

    private struct StickyPrice: Codable {
        let priceText: String
        let storeName: String
        let updatedAt: Date
    }

    private static func loadStickyPrices(_ ud: UserDefaults) -> [String: StickyPrice] {
        guard let data = ud.data(forKey: stickyPricesKey),
              let decoded = try? JSONDecoder().decode([String: StickyPrice].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func saveStickyPrices(_ prices: [String: StickyPrice], to ud: UserDefaults) {
        // Drop expired entries on the way out so the blob can't grow forever.
        let live = prices.filter { Date().timeIntervalSince($0.value.updatedAt) < stickyPriceMaxAge }
        guard let data = try? JSONEncoder().encode(live) else { return }
        ud.set(data, forKey: stickyPricesKey)
    }

    private static func loadCachedStorePrices(for storeName: String, userDefaults: UserDefaults) -> [CachedStorePrice] {
        let candidateKeys = [
            "stockAvailabilityCache",
            "stockAvailabilityOffersCache",
            "cachedStoreOffers",
            "shoppingListStoreOffers",
            "storeOfferCache"
        ]

        let targetNames = storeMatchCandidates(for: storeName)
        guard !targetNames.isEmpty else { return [] }

        // PRIMARY SOURCE: the widget snapshot, which WidgetPriceFetcher keeps
        // current. The legacy keys below stopped being written when the old
        // stock services were deleted in the pre-launch cleanup — they only
        // hold data on installs that predate it, which is why prices appeared
        // intermittently (stale leftovers on some installs, nothing on fresh ones).
        let snapshotPrices: [CachedStorePrice] = WidgetSnapshot.read().items.compactMap { item in
            guard let priceText = item.priceText, !priceText.isEmpty else { return nil }
            return CachedStorePrice(
                storeName: item.priceStoreName ?? "",
                name: item.name,
                price: nil,
                priceText: priceText
            )
        }

        if !snapshotPrices.isEmpty {
            let filtered = snapshotPrices.filter { matchesStoreName($0.storeName, candidates: targetNames) }
            if !filtered.isEmpty {
                print("[LIVE] matched \(filtered.count) prices from widget snapshot for store=\(storeName)")
                return filtered
            }
        }

        // Prices from a different store are indicative rather than exact, but a
        // rough running total is far more useful in-store than no total at all.
        var anyStoreFallback: [CachedStorePrice] = snapshotPrices

        for key in candidateKeys {
            var decoded: [CachedStorePrice] = []

            if let json = userDefaults.string(forKey: key),
               let data = json.data(using: .utf8),
               let fromString = try? JSONDecoder().decode([CachedStorePrice].self, from: data) {
                decoded = fromString
            } else if let data = userDefaults.data(forKey: key),
                      let fromData = try? JSONDecoder().decode([CachedStorePrice].self, from: data) {
                decoded = fromData
            }

            guard !decoded.isEmpty else { continue }

            let filtered = decoded.filter { matchesStoreName($0.storeName, candidates: targetNames) }
            if !filtered.isEmpty {
                print("[LIVE] matched priced cache key=\(key) stores=\(Set(filtered.map { $0.storeName }))")
                return filtered
            }

            if anyStoreFallback.isEmpty {
                anyStoreFallback = decoded
            }
        }

        if !anyStoreFallback.isEmpty {
            print("[LIVE] no priced cache match for store=\(storeName) — falling back to \(anyStoreFallback.count) prices from other stores")
            return anyStoreFallback
        }

        print("[LIVE] no priced cache at all for store=\(storeName) candidates=\(targetNames)")
        return []
    }

    private static func storeMatchCandidates(for storeName: String) -> [String] {
        let normalized = normalizeStoreName(storeName)
        guard !normalized.isEmpty else { return [] }

        var candidates: [String] = [normalized]

        var locationOnly = normalized
        locationOnly = locationOnly.replacingOccurrences(of: "woolworths", with: "")
        locationOnly = locationOnly.replacingOccurrences(of: "woolworth", with: "")
        locationOnly = locationOnly.replacingOccurrences(of: "countdown", with: "")
        locationOnly = locationOnly.replacingOccurrences(of: "woolies", with: "")
        locationOnly = locationOnly.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        locationOnly = locationOnly.trimmingCharacters(in: .whitespacesAndNewlines)

        let hasWoolworths = normalized.contains("woolworth") || normalized.contains("woolies")
        let hasCountdown = normalized.contains("countdown")

        if hasCountdown {
            candidates.append(normalized.replacingOccurrences(of: "countdown", with: "woolworths"))
            candidates.append(normalized.replacingOccurrences(of: "countdown", with: "woolworth"))
            candidates.append(normalized.replacingOccurrences(of: "countdown", with: "woolies"))
        }

        if hasWoolworths {
            candidates.append(normalized.replacingOccurrences(of: "woolworths", with: "countdown"))
            candidates.append(normalized.replacingOccurrences(of: "woolworth", with: "countdown"))
            candidates.append(normalized.replacingOccurrences(of: "woolies", with: "countdown"))
        }

        if !locationOnly.isEmpty {
            candidates.append(locationOnly)
            candidates.append("countdown \(locationOnly)")
            candidates.append("woolworths \(locationOnly)")
            candidates.append("woolworth \(locationOnly)")
            candidates.append("woolies \(locationOnly)")
        }

        var seen: Set<String> = []
        return candidates
            .map {
                $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .filter {
                guard !seen.contains($0) else { return false }
                seen.insert($0)
                return true
            }
    }

    private static func matchesStoreName(_ cachedStoreName: String, candidates: [String]) -> Bool {
        let cached = normalizeStoreName(cachedStoreName)
        guard !cached.isEmpty else { return false }

        for candidate in candidates {
            if cached == candidate { return true }
            if cached.contains(candidate) || candidate.contains(cached) { return true }
        }

        return false
    }

    private static func matchedPrice(for item: WidgetItem, pricedNames: [CachedStorePrice]) -> String? {
        let itemName = normalizeItemName(item.name)
        guard !itemName.isEmpty else { return nil }

        if let exact = pricedNames.first(where: { normalizeItemName($0.name) == itemName }) {
            return exact.normalizedPrice
        }

        // Same food-aware matcher as recipes, so "Ice" never picks up the
        // price of rice and a brand word never counts as a match.
        if let matched = pricedNames.first(where: { IngredientMatcher.matches(item.name, $0.name) }) {
            return matched.normalizedPrice
        }

        return nil
    }

    private static func normalizeStoreName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func normalizeItemName(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct WidgetItem: Codable {
        let id: String
        let name: String
        let quantity: String
        let unit: String

        var displayString: String {
            let name = self.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let qty  = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
            let unit = self.unit.trimmingCharacters(in: .whitespacesAndNewlines)

            // Format "ea" units as "x1", "x2", etc. instead of "1 ea"
            if unit.lowercased() == "ea", !qty.isEmpty {
                return name.isEmpty ? "x\(qty)" : "\(name) x\(qty)"
            }

            var parts = [name]
            if !qty.isEmpty { parts.append(qty) }
            if !unit.isEmpty { parts.append(unit) }
            return parts.filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    private struct CachedStorePrice: Codable {
        let storeName: String
        let name: String
        let price: String?
        let priceText: String?

        var normalizedPrice: String? {
            let source = (priceText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? priceText
                : price
            let raw = source?.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let raw, !raw.isEmpty else { return nil }
            if raw.hasPrefix("$") { return raw }
            return "$\(raw)"
        }
    }
}
