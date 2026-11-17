//
//  AppDelegateWrapper.swift
//  FrydgeRecipes
//

import SwiftUI
import UserNotifications
import CoreLocation
import BackgroundTasks
import ActivityKit
import CloudKit
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, CLLocationManagerDelegate {

    private let locationManager = CLLocationManager()
    private var didPrimeRegionMonitoringWithRealLocation = false
    private var lastRegionPrimeLocation: CLLocation?
    private let regionRePrimeThresholdMeters: CLLocationDistance = 3000
    private let appGroupName = "group.Clark-Online.FrydgeRecipeAPN"

    // MARK: - Shared list push routing

    private let sharedShoppingListUpdatedCategory = "SHARED_SHOPPING_LIST_UPDATED"
    private let sharedShoppingListSubscriptionPrefix = "SharedShoppingList_"

    // ✅ Shared frydge push routing
    private let sharedFrydgeUpdatedCategory = "SHARED_FRYDGE_UPDATED"
    private let sharedFrydgeSubscriptionPrefix = "SharedFrydge_"

    // MARK: - App group user id helpers

    private func currentAppleUserID() -> String? {
        // Prefer app-group stored id (shared with extensions), fall back to standard defaults.
        if let ud = UserDefaults(suiteName: appGroupName),
           let v = ud.string(forKey: "appleUserID"),
           !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return v
        }
        if let v = UserDefaults.standard.string(forKey: "appleUserID"),
           !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return v
        }
        return nil
    }

    private func shoppingListAppGroupKey() -> String {
        if let uid = currentAppleUserID() {
            return "shoppingList_\(uid)"
        }
        // If we can’t resolve yet, use legacy key so we still show something.
        return "shoppingList"
    }

    // MARK: - CloudKit subscription priming (shared pushes)

    /// Ensures CloudKit subscriptions exist even if user never opens the shared views.
    /// Call at launch, when app becomes active, and after accepting a share.
    private func primeSharedCloudKitSubscriptions(source: String) {
        print("[PUSH] primeSharedCloudKitSubscriptions source=\(source)")

        Task { @MainActor in
            let ck = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")

            // Shared shopping list subscriptions (per-list)
            let shopping = SharedShoppingListManager(container: ck)
            await shopping.configureSharedShoppingListNotificationsIfNeeded()

            // Shared frydge subscriptions (your SharedFridgeManager should implement this)
            // If your method/class name differs, update this call to match your actual manager.
            let sharedFrydge = SharedFridgeManager(containerID: "iCloud.com.Clark-Online.Recipe")
            await sharedFrydge.configureSharedFrydgeNotificationsIfNeeded()
        }
    }

    /// A frydge push may carry household meal-plan changes. Give the plan store
    /// a bounded window to fetch them (and post the resulting notifications)
    /// before telling iOS the background fetch is finished; otherwise the app is
    /// suspended before the network round-trip completes.
    private func finishAfterMealPlanSync(_ completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await SharedMealPlanStore.shared.handleRemotePush() }
                group.addTask { try? await Task.sleep(for: .seconds(20)) }
                _ = await group.next()
                group.cancelAll()
            }
            completionHandler(.newData)
        }
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {

        // CRITICAL: Set the location manager delegate immediately, before anything else.
        // When iOS relaunches the app in the background for a geofence event, only
        // didFinishLaunchingWithOptions is called (not applicationDidBecomeActive).
        // If the delegate isn't set here, didEnterRegion fires with no listener and
        // the Live Activity never starts.
        locationManager.delegate = self

        // Set the UNUserNotificationCenter delegate
        UNUserNotificationCenter.current().delegate = self

        // Register notification categories
        registerNotificationCategories()

        // Request notification permissions
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error = error {
                print("[ERROR] Failed to request notification authorization: \(error.localizedDescription)")
            }
            print("[INFO] Notification permission granted? \(granted)")
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                print("[INFO] Notification settings: authorization=\(settings.authorizationStatus.rawValue) alert=\(settings.alertSetting.rawValue) lockscreen=\(settings.lockScreenSetting.rawValue) banner=\(settings.alertStyle.rawValue)")
            }
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }

        // Ask for When-In-Use location alongside the other launch permissions,
        // rather than surprising the user the first time a store-aware screen
        // (shopping list, marketplace) happens to appear. iOS queues this behind
        // the notification prompt. "Always" is still only requested when the
        // user opts into store-arrival reminders in Profile.
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }

        // Register background tasks
        registerBackgroundTasks()

        // React to the Profile "Store arrival reminders" toggle.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeArrivalRemindersDidChange),
            name: StoreArrivalReminders.didChange,
            object: nil
        )

        // Subscribe to push-to-start tokens. Must happen at launch — including a
        // background launch for a geofence — because the token is what lets the
        // Worker raise a Live Activity we aren't allowed to start ourselves.
        Task { @MainActor in
            LiveActivityPushManager.shared.start()
        }

        // Diagnostic print for BGTaskSchedulerPermittedIdentifiers
        if let ids = Bundle.main.infoDictionary?["BGTaskSchedulerPermittedIdentifiers"] as? [String] {
            print("[DEBUG] Permitted BG IDs from Info.plist: \(ids)")
        } else {
            print("[DEBUG] No BGTaskSchedulerPermittedIdentifiers found in Info.plist")
        }

        // Initialize the network monitor and give it its reachability callback.
        // NetworkMonitor used to call Networking.shared directly from its own
        // background queue, which forced that singleton to initialise off-main.
        NetworkMonitor.shared.setReachabilityHandler {
            RecipeUploadQueue.shared.drainInBackground()
        }

        let adaptiveBg = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.18, alpha: 1)
                : UIColor(white: 0.95, alpha: 1)
        }
        UITableView.appearance().backgroundColor = adaptiveBg
        UICollectionView.appearance().backgroundColor = adaptiveBg

        // Configure Stripe — publishable key is safe in the app; secret key lives in the Cloudflare Worker
        StripeConfig.configure(
            publishableKey: "pk_test_51TSViXCVYZKUKvUzJnn2qkhypIB7txxKzub2bZylpgmKyLJ6WCckN7iyITlSRoLW4uAcrWadY7TzFbzCZxs6c2ye00PHo3E4tG",
            backendURL: StripeConfig.defaultBackendBaseURL
        )

        URLCache.shared = URLCache(
            memoryCapacity: 50 * 1024 * 1024,   // 50 MB memory
            diskCapacity: 500 * 1024 * 1024,     // 500 MB disk
            directory: nil
        )

        print("[INFO] Application setup complete.")
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Register notification categories again when app becomes active
        registerNotificationCategories()

        // ✅ Re-prime subscriptions (idempotent; helps after reinstall/new device/sign-in timing)
        primeSharedCloudKitSubscriptions(source: "applicationDidBecomeActive")

        // Start any Live Activity that was deferred while the app was in the background
        // (region monitoring can't start one from the background — only update/end).
        ActivityManager.flushPendingStart()

        // Location is used opportunistically on startup. The UI-specific
        // LocationManager owns first-time permission prompts.
        startLocationServicesIfAuthorized()
        scheduleAppRefresh()
        scheduleProcessing()

        // Sync offline recipes when the app becomes active
        RecipeUploadQueue.shared.drainInBackground()

        // Apply any items ticked off inside the store-arrival notification.
        processNotificationTicks()

        // Sync Live Activity checked items into FridgeManager
        Task {
            let activities = Activity<ShoppingListActivityAttributes>.activities
            if let activity = activities.first {
                let checkedItems = activity.content.state.checkedItems
                // Was `FrydgeManager()` — a throwaway third instance whose writes
                // raced the one the UI is bound to. Use the singleton.
                let fridgeManager = FrydgeManager.shared
                for item in checkedItems {
                    fridgeManager.addToInventory(item)
                }
                print("[INFO] Synced \(checkedItems.count) items from Live Activity to Fridge.")
            }
        }
    }

    private func handleAppRefresh(task: BGAppRefreshTask) {
        // Always schedule the next refresh first.
        scheduleAppRefresh()

        // If iOS is about to kill the task, stop work and mark incomplete.
        task.expirationHandler = {
            print("[BG] App refresh expired before completion.")
            task.setTaskCompleted(success: false)
        }

        // Run refresh work off the main thread.
        Task.detached(priority: .background) {
            // Upload any recipes saved while offline. Idempotent; each entry is
            // removed only after CloudKit confirms it. Awaited so the task is
            // not marked complete while uploads are still in flight.
            await RecipeUploadQueue.shared.drain()

            // Mark completed (must be called exactly once)
            task.setTaskCompleted(success: true)
            print("[BG] App refresh completed successfully.")
        }
    }

    private func registerNotificationCategories() {
        // Opens the app on the shopping list (ticking happens inline in the
        // expanded notification via the content extension).
        let confirmAction = UNNotificationAction(
            identifier: "CONFIRM_ACTION",
            title: "Open Shopping List",
            options: [.foreground]
        )

        let shoppingListCategory = UNNotificationCategory(
            identifier: "SHOPPING_LIST_CATEGORY",
            actions: [confirmAction],
            intentIdentifiers: [],
            options: []
        )

        // New actions for expiry reminders
        let markUsed = UNNotificationAction(
            identifier: "MARK_USED",
            title: "Mark Used",
            options: [.authenticationRequired]
        )

        // Re-buy straight from the reminder — handy when it's already gone off.
        let addToList = UNNotificationAction(
            identifier: "ADD_TO_LIST",
            title: "Add to Shopping List",
            options: []
        )

        let snooze = UNNotificationAction(
            identifier: "SNOOZE_1H",
            title: "Snooze 1 hr",
            options: []
        )

        let expiryCategory = UNNotificationCategory(
            identifier: "EXPIRY_REMINDER",
            actions: [markUsed, addToList, snooze],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        // Shared shopping list CloudKit push category (no actions; just opens the app)
        let sharedShoppingListUpdated = UNNotificationCategory(
            identifier: sharedShoppingListUpdatedCategory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        // ✅ Shared frydge CloudKit push category (no actions; just opens the app)
        let sharedFrydgeUpdated = UNNotificationCategory(
            identifier: sharedFrydgeUpdatedCategory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([
            shoppingListCategory,
            expiryCategory,
            sharedShoppingListUpdated,
            sharedFrydgeUpdated,
            LeftoverNotification.category
        ])

        print("[INFO] Notification categories registered: SHOPPING_LIST_CATEGORY, EXPIRY_REMINDER, \(sharedShoppingListUpdatedCategory), \(sharedFrydgeUpdatedCategory), \(LeftoverNotification.categoryID)")
    }

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.Clark-Online.Recipes.refresh", using: nil) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }

        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.Clark-Online.Recipes.processing", using: nil) { task in
            self.handleProcessingTask(task: task as! BGProcessingTask)
        }
    }

    private func handleProcessingTask(task: BGProcessingTask) {
        // Process your background task logic here
        task.setTaskCompleted(success: true)
    }

    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.Clark-Online.Recipes.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // Schedule 15 minutes later

        // submitTaskRequest(_:completionHandler:) replaces the deprecated submit(_:)
        // and surfaces submission errors that the old API could miss.
        BGTaskScheduler.shared.submitTaskRequest(request) { error in
            if let error {
                print("Could not schedule app refresh: \(error.localizedDescription)")
            } else {
                print("App refresh task scheduled.")
            }
        }
    }

    func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: "com.Clark-Online.Recipes.processing")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60) // Schedule ~1 hour later
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = true
        BGTaskScheduler.shared.submitTaskRequest(request) { error in
            if let error {
                print("Could not schedule processing task: \(error.localizedDescription)")
            } else {
                print("Processing task scheduled.")
            }
        }
    }

    /// Schedules a local notification to warn that an ingredient/item is expiring.
    /// `userInfo` carries over the original reminder's payload (recipe
    /// suggestions, emoji, item id) so a snoozed notification keeps them.
    func scheduleExpiryNotification(
        name: String,
        expiryDate: Date,
        leadTime: TimeInterval = 0,
        identifier: String,
        userInfo: [AnyHashable: Any] = [:]
    ) {
        let fireDate = expiryDate.addingTimeInterval(-leadTime)
        let interval = max(fireDate.timeIntervalSinceNow, 60) // ensure at least 60s in future to avoid being dropped
        guard interval.isFinite else { return }

        let suggestions = userInfo[FrydgeManager.ExpiryNotificationKeys.suggestedRecipes] as? [[String: String]] ?? []
        let emoji = (userInfo[FrydgeManager.ExpiryNotificationKeys.itemEmoji] as? String) ?? "⏰"

        let content = UNMutableNotificationContent()
        content.title = "\(emoji) \(name) is expiring"
        let timing = leadTime > 0 ? "Expires in \(Int(leadTime/3600))h." : "This item has reached its expiry."
        if let useItUp = FrydgeManager.useItUpLine(from: suggestions) {
            content.subtitle = "\(suggestions.count) recipe\(suggestions.count == 1 ? "" : "s") use it"
            content.body = "\(timing) \(useItUp)"
        } else {
            content.body = "\(timing) Tap to review or mark used."
        }
        content.sound = .default
        content.badge = NSNumber(value: 1)
        content.categoryIdentifier = "EXPIRY_REMINDER"
        var info = userInfo
        info["name"] = name
        info["expiry"] = expiryDate.timeIntervalSince1970
        content.userInfo = info

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[ERROR] scheduleExpiryNotification failed: \(error.localizedDescription)")
            } else {
                print("[INFO] Scheduled expiry notification (id=\(identifier)) for \(fireDate))")
            }
        }
    }

    // MARK: - CloudKit Share Intake (shared helper)

    private func handleShareURL(_ url: URL, containerID: String, source: String) {
        print("[INVITES] handleShareURL source=\(source) url=\(url.absoluteString)")

        let op = CKFetchShareMetadataOperation(shareURLs: [url])

        op.fetchShareMetadataResultBlock = { result in
            switch result {
            case .success:
                print("[INVITES] CKFetchShareMetadataOperation completed (source=\(source))")
            case .failure(let error):
                print("[INVITES] CKFetchShareMetadataOperation failed (source=\(source)): \(error)")
            }
        }

        op.perShareMetadataResultBlock = { _, result in
            switch result {
            case .success(let metadata):
                print("[INVITES] metadata fetched (source=\(source))")
                Task { @MainActor in
                    PendingInvites.shared.add(meta: metadata)
                }
            case .failure(let error):
                print("[INVITES] perShareMetadataResultBlock failed (source=\(source)): \(error)")
            }
        }

        CKContainer(identifier: containerID).add(op)
    }

    private func handleAcceptedShareMetadata(_ metadata: CKShare.Metadata, source: String) {
        print("[INVITES] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("[INVITES] 🎉 SHARE ACCEPTED via \(source)")
        print("[INVITES] 📋 Share Record ID: \(metadata.share.recordID.recordName)")
        print("[INVITES] 📦 Container ID: \(metadata.containerIdentifier)")
        print("[INVITES] 👤 Owner: \(metadata.ownerIdentity.nameComponents?.formatted() ?? "Unknown")")
        
        if let rootRef = metadata.rootRecord {
            print("[INVITES] 🌳 Root Record ID: \(rootRef.recordID.recordName)")
            print("[INVITES] 🗂️  Root Zone: \(rootRef.recordID.zoneID.zoneName)")
        }
        
        print("[INVITES] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        // ✅ Prime subscriptions again after share acceptance (new shared zone likely appeared)
        print("[INVITES] 🔔 Scheduling subscription configuration...")
        primeSharedCloudKitSubscriptions(source: "acceptedShareMetadata:\(source)")

        Task { @MainActor in
            print("[INVITES] 📢 Broadcasting acceptance notifications...")
            NotificationCenter.default.post(name: .cloudShareAccepted, object: nil)
            NotificationCenter.default.post(name: .cloudShareAcceptedMetadata, object: metadata)

            // Existing: refresh shared shopping list after accepting a share
            print("[INVITES] 📢 Broadcasting SharedShoppingListChanged")
            NotificationCenter.default.post(name: Notification.Name("SharedShoppingListChanged"), object: nil)

            // ✅ Also refresh shared frydges after accepting a share
            print("[INVITES] 📢 Broadcasting SharedFrydgeChanged")
            NotificationCenter.default.post(name: Notification.Name("SharedFrydgeChanged"), object: nil)
            
            print("[INVITES] ✅ All acceptance notifications sent")
        }
    }

    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        let isCloudKitShare = (userActivity.activityType == "com.apple.cloudkit.share")
        let isBrowsingWeb = (userActivity.activityType == NSUserActivityTypeBrowsingWeb)

        guard isCloudKitShare || isBrowsingWeb else {
            return false
        }

        guard let url = userActivity.webpageURL else {
            print("[INVITES] continueUserActivity fired but webpageURL was nil (type=\(userActivity.activityType))")
            return false
        }

        // ✅ Only treat iCloud share links as CloudKit shares. Ignore normal web pages.
        if let host = url.host?.lowercased(), host.contains("icloud.com") {
            print("[INVITES] continueUserActivity (icloud) (type=\(userActivity.activityType)) : \(url.absoluteString)")
            handleShareURL(url, containerID: "iCloud.com.Clark-Online.Recipe", source: "UIApplicationDelegate.continueUserActivity")
            return true
        } else {
            print("[INVITES] continueUserActivity ignored non-icloud URL (type=\(userActivity.activityType)) : \(url.absoluteString)")
            return false
        }
    }

    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        handleAcceptedShareMetadata(cloudKitShareMetadata, source: "UIApplicationDelegate.userDidAcceptCloudKitShareWith")
    }

    /// Cancel a previously scheduled expiry notification
    func cancelExpiryNotification(identifier: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// Convenience to re-schedule with a new date/lead time using the same id
    func rescheduleExpiryNotification(name: String, newExpiry: Date, leadTime: TimeInterval = 0, identifier: String) {
        cancelExpiryNotification(identifier: identifier)
        scheduleExpiryNotification(name: name, expiryDate: newExpiry, leadTime: leadTime, identifier: identifier)
    }

    private func startLocationServicesIfAuthorized() {
        locationManager.delegate = self

        // Store-arrival reminders are opt-in. Until the user turns them on in
        // Profile we never escalate to Always, never enable background updates
        // and never register a geofence. (The map uses its own When-In-Use
        // manager in LocationManager.)
        guard StoreArrivalReminders.isEnabled else { return }

        switch locationManager.authorizationStatus {
        case .authorizedAlways:
            break
        case .authorizedWhenInUse, .notDetermined:
            // The user has just opted in, so this is the moment to ask.
            locationManager.requestAlwaysAuthorization()
            return
        default:
            return
        }

        locationManager.startUpdatingLocation()
        
        // ✅ CRITICAL: Check if system treats this as an extension
        // The error "Plist keys indicate the current process is an extension" means
        // your Info.plist may have extension keys (NSExtension, etc.) that shouldn't be there
        
        let bundlePath = Bundle.main.bundleURL.path
        let executablePath = Bundle.main.executablePath ?? ""
        let isExtension = Bundle.main.bundleURL.pathExtension == "appex" || 
                         bundlePath.contains(".appex/") ||
                         executablePath.contains(".appex/")
        
        // Also check if Info.plist has NSExtension key (which would make iOS treat this as extension)
        let hasExtensionKey = Bundle.main.object(forInfoDictionaryKey: "NSExtension") != nil
        
        if !isExtension && !hasExtensionKey {
            locationManager.allowsBackgroundLocationUpdates = true
            print("[LocationManager] Background location updates enabled")
        } else {
            print("[LocationManager] ⚠️ Skipping background location updates")
            print("[LocationManager]    isExtension=\(isExtension), hasExtensionKey=\(hasExtensionKey)")
            print("[LocationManager]    bundlePath=\(bundlePath)")
            print("[LocationManager]    If this is your main app, check Info.plist for NSExtension keys!")
        }
        
        locationManager.pausesLocationUpdatesAutomatically = false
        setupRegionMonitoringForStores()
    }
    private func setupRegionMonitoringForStores() {
        guard StoreArrivalReminders.isEnabled else { return }
        RegionMonitoring.startMonitoring(locationManager: locationManager)
    }

    /// Tears down everything the store-arrival opt-in switched on.
    private func stopStoreArrivalMonitoring() {
        for region in locationManager.monitoredRegions {
            locationManager.stopMonitoring(for: region)
        }
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.stopUpdatingLocation()
        didPrimeRegionMonitoringWithRealLocation = false
        lastRegionPrimeLocation = nil
        print("[RegionMonitoring] Store arrival reminders off — stopped all geofences")
    }

    /// Profile toggle changed: start or stop store-arrival monitoring.
    @objc private func storeArrivalRemindersDidChange() {
        if StoreArrivalReminders.isEnabled {
            startLocationServicesIfAuthorized()
        } else {
            stopStoreArrivalMonitoring()
        }
    }

    // CLLocationManagerDelegate method
    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let circular = region as? CLCircularRegion else { return }
        print("Entered region: \(circular.identifier)")

        // Record which shop we're in before anything reads it: the Live
        // Activity and the shopping list both grey out items this chain
        // doesn't sell based on this session.
        let storeName = circular.identifier
        Task { @MainActor in
            InStoreSession.shared.begin(storeName: storeName, source: .geofence)
        }

        ActivityManager.startActivity(for: circular.identifier)
        triggerLocalNotification(for: circular.identifier)

        // Basket mode: if the app is open when the user walks in, switch to
        // the in-store basket straight away (FrydgeRecipesApp listens).
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .storeArrived,
                object: nil,
                userInfo: [
                    StoreArrivalKeys.storeName: circular.identifier,
                    StoreArrivalKeys.fromNotification: false
                ]
            )
        }
    }

    // Confirms a region is genuinely being monitored. Only now is it safe to ask
    // for its state — calling requestState immediately after startMonitoring (as
    // RegionMonitoring used to) returns .unknown because tracking hasn't begun.
    func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        print("[RegionMonitoring] Monitoring confirmed for \(region.identifier) — requesting state")
        manager.requestState(for: region)
    }

    // Surfaces the failures that were previously invisible: too many regions,
    // Always authorization missing, or a malformed region.
    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        print("[RegionMonitoring] ⚠️ Monitoring FAILED for \(region?.identifier ?? "nil"): \(error.localizedDescription)")
        print("[RegionMonitoring]    monitored region count = \(manager.monitoredRegions.count) (iOS cap is 20)")
    }

    // Handles the response to `requestState(for:)`. iOS won't re-send didEnterRegion
    // for a region the device is already inside, so we use the determined state to
    // (re)start the Live Activity when the user is at a store but the activity was
    // dismissed in an earlier session. No notification here — that's only for the
    // arrival transition; the start path quietly updates/recreates the activity.
    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard let circular = region as? CLCircularRegion else { return }
        let storeName = circular.identifier
        switch state {
        case .inside:
            print("[RegionMonitoring] Already inside region: \(storeName) — (re)starting Live Activity")
            Task { @MainActor in
                InStoreSession.shared.begin(storeName: storeName, source: .geofence)
            }
            ActivityManager.startActivity(for: storeName)
        case .outside:
            // Left while the app wasn't running: tidy up the session now.
            Task { @MainActor in
                InStoreSession.shared.endIfOutside(regionIdentifier: storeName)
            }
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    // Walking out of the store ends the in-store session, so the shopping
    // list stops greying items for that chain without a tap.
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard let circular = region as? CLCircularRegion else { return }
        print("Exited region: \(circular.identifier)")
        let storeName = circular.identifier
        Task { @MainActor in
            InStoreSession.shared.endIfOutside(regionIdentifier: storeName)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        guard latest.horizontalAccuracy >= 0 && latest.horizontalAccuracy <= 2000 else { return }

        // A fix well clear of the current store ends the session even when
        // the exit geofence didn't fire (When-In-Use only, or app was closed).
        Task { @MainActor in
            InStoreSession.shared.endIfLeft(location: latest)
        }

        if !didPrimeRegionMonitoringWithRealLocation {
            didPrimeRegionMonitoringWithRealLocation = true
            lastRegionPrimeLocation = latest
            print("[RegionMonitoring] Initial location acquired (accuracy=\(latest.horizontalAccuracy)m). Selecting nearest stores.")
            publishNearestStore(for: latest)
            setupRegionMonitoringForStores()
            return
        }

        if let prev = lastRegionPrimeLocation {
            let moved = latest.distance(from: prev)
            if moved >= regionRePrimeThresholdMeters {
                lastRegionPrimeLocation = latest
                print("[RegionMonitoring] User moved \(Int(moved))m since last prime. Re-selecting nearest stores.")
                publishNearestStore(for: latest)
                setupRegionMonitoringForStores()
            }
        } else {
            lastRegionPrimeLocation = latest
            publishNearestStore(for: latest)
        }
    }

    private func publishNearestStore(for location: CLLocation) {
        guard let nearest = RegionMonitoring.allStores
            .map({ store -> (store: Store, distance: CLLocationDistance) in
                let storeLocation = CLLocation(latitude: store.latitude, longitude: store.longitude)
                return (store, location.distance(from: storeLocation))
            })
            .min(by: { $0.distance < $1.distance }) else {
            return
        }

        WidgetSnapshot.mutate { snapshot in
            snapshot.nearestStoreName = nearest.store.name
            snapshot.nearestStoreDistanceText = Self.formatDistance(nearest.distance)
        }
        ActivityManager.publishCurrentStore(nearest.store.name)
    }

    private static func formatDistance(_ distance: CLLocationDistance) -> String {
        if distance < 1000 {
            return "\(Int(distance.rounded())) m"
        }

        return String(format: "%.1f km", distance / 1000)
    }

    /// Lightweight mirror of the widget snapshot entries ShoppingListManager
    /// writes to the app group (`shoppingListItemsJSON`).
    private struct StoreNotifItem: Decodable {
        let id: String
        let name: String
        let quantity: String
        let unit: String
    }

    private func triggerLocalNotification(for identifier: String) {
        // Per-store cooldown: skip if we notified for this store within the last 2 hours
        let cooldownKey = "storeNotifLastFired_\(identifier)"
        let cooldownInterval: TimeInterval = 2 * 60 * 60
        if let lastFired = UserDefaults.standard.object(forKey: cooldownKey) as? Date,
           Date().timeIntervalSince(lastFired) < cooldownInterval {
            print("[INFO] Skipping notification for '\(identifier)' — cooldown active")
            return
        }

        let ud = UserDefaults(suiteName: appGroupName)

        // Prefer the structured snapshot (ids + clean names) so ticks in the
        // notification can be matched back to real list items. Fall back to the
        // legacy display strings, which may have prices baked in.
        var items: [(id: String, name: String, quantity: String, unit: String)] = []
        if let json = ud?.string(forKey: "shoppingListItemsJSON"),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([StoreNotifItem].self, from: data) {
            items = decoded.map { ($0.id, $0.name, $0.quantity, $0.unit) }
        } else {
            let scopedKey = shoppingListAppGroupKey()
            let legacy = (ud?.array(forKey: scopedKey) as? [String])
                ?? (ud?.array(forKey: "shoppingList") as? [String])
                ?? []
            items = legacy.map { ("", Self.strippedOfPrices($0), "", "") }
        }

        // Don't notify when the shopping list is empty
        guard !items.isEmpty else {
            print("[INFO] Skipping notification for '\(identifier)' — shopping list is empty")
            return
        }

        // Per-item prices come from the widget snapshot (filled in by WidgetPriceFetcher).
        let priceByID: [String: String] = Dictionary(
            WidgetSnapshot.read().items.compactMap { item in
                item.priceText.map { (item.id, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        // IngredientProductCache is an actor, so the photo lookups hop off
        // the delegate queue; the notification itself is scheduled after.
        Task {
            var payload: [[String: String]] = []
            for item in items {
                let cached = await IngredientProductCache.shared.preferred(for: item.name)
                payload.append([
                    "id": item.id,
                    "name": ProductShorthand.short(for: item.name),
                    "fullName": item.name.localizedCapitalized,
                    "emoji": FoodEmoji.emoji(for: item.name),
                    // Quantity column in the expanded notification ("12 | Eggs").
                    "quantity": item.quantity,
                    "unit": item.unit,
                    "price": priceByID[item.id] ?? "",
                    "imageURL": cached?.imageURL ?? ""
                ])
            }
            self.scheduleStoreNotification(store: identifier, payload: payload, cooldownKey: cooldownKey)
        }
    }

    private func scheduleStoreNotification(store: String, payload: [[String: String]], cooldownKey: String) {
        let content = UNMutableNotificationContent()
        content.title = "🛒 You're at \(store)"
        content.categoryIdentifier = "SHOPPING_LIST_CATEGORY"
        content.sound = .default

        let itemCount = payload.count
        let total = payload.reduce(0.0) { sum, item in
            let digits = (item["price"] ?? "").filter { "0123456789.".contains($0) }
            return sum + (Double(digits) ?? 0)
        }
        let countText = "\(itemCount) item\(itemCount == 1 ? "" : "s")"
        content.subtitle = total > 0 ? "\(countText) · " + String(format: "$%.2f", total) : countText

        // Short, capitalised names ("Corn Chips", not the full shelf label).
        let names = payload.compactMap { $0["name"] }.filter { !$0.isEmpty }
        let preview = names.prefix(3).joined(separator: ", ")
        let extra = names.count - 3
        content.body = extra > 0
            ? "\(preview) and \(extra) more — hold to tick items off"
            : "\(preview) — hold to tick items off"

        // Store identity for the expanded view's header: logo, brand, branch
        // and street address. The address comes from the store directory the
        // geofence was built from.
        let directoryEntry = RegionMonitoring.allStores.first { $0.name == store }
        content.userInfo = [
            "navigate": "shopping",
            "store": store,
            ShoppingNotificationKeys.storeName: store,
            ShoppingNotificationKeys.storeLocation: directoryEntry?.vicinity ?? "",
            ShoppingNotificationKeys.shoppingItems: payload
        ]

        let notifID = "SHOPPING_LIST_NOTIFICATION_\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: notifID, content: content, trigger: nil)

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[ERROR] Failed to schedule store notification: \(error.localizedDescription)")
            } else {
                UserDefaults.standard.set(Date(), forKey: cooldownKey)
                print("[INFO] Store notification scheduled for '\(store)' (id=\(notifID))")
            }
        }
    }

    /// A "use it up" recipe tapped in the expanded expiry notification lands in
    /// the app group (the content extension can't navigate the app itself).
    /// Hand it to the SwiftUI side; the UserDefaults copy covers a cold launch
    /// where the subscriber may not exist yet when this posts.
    private func openRecipeTappedInNotificationIfAny() {
        let key = FrydgeManager.ExpiryNotificationKeys.tappedRecipeID
        guard let ud = UserDefaults(suiteName: appGroupName),
              let recipeID = ud.string(forKey: key), !recipeID.isEmpty else { return }
        ud.removeObject(forKey: key)

        UserDefaults.standard.set(recipeID, forKey: FrydgeManager.ExpiryNotificationKeys.pendingOpenRecipeID)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .openRecipe, object: nil, userInfo: ["recipeID": recipeID])
        }
    }

    /// An item name tapped in the expanded store-arrival notification lands in
    /// the app group; hand it to the SwiftUI side so the shopping list opens
    /// that item's detail sheet. Same cold-launch safety net as recipes.
    private func openShoppingItemTappedInNotificationIfAny() {
        guard let ud = UserDefaults(suiteName: appGroupName),
              let entry = ud.dictionary(forKey: ShoppingNotificationKeys.tappedItem) as? [String: String],
              !(entry["name"] ?? "").isEmpty || !(entry["id"] ?? "").isEmpty else { return }
        ud.removeObject(forKey: ShoppingNotificationKeys.tappedItem)

        UserDefaults.standard.set(entry, forKey: ShoppingNotificationKeys.pendingOpenItem)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .openShoppingItem, object: nil, userInfo: entry)
        }
    }

    /// Items ticked in the notification content extension land in the app group;
    /// move them into the fridge exactly like ticking a row inside the app.
    private func processNotificationTicks() {
        guard let ud = UserDefaults(suiteName: appGroupName),
              let entries = ud.array(forKey: "notificationTickedItems_v1") as? [[String: String]],
              !entries.isEmpty else { return }
        ud.removeObject(forKey: "notificationTickedItems_v1")

        Task { @MainActor in
            let manager = ShoppingListManager.current ?? ShoppingListManager()
            let frydge = FrydgeManager.shared

            for entry in entries {
                if let idString = entry["id"],
                   let id = UUID(uuidString: idString),
                   manager.shoppingListItems.contains(where: { $0.id == id }) {
                    await manager.purchaseItem(id, into: frydge)
                    continue
                }

                // Legacy payloads carry no ids — match by normalized name.
                let name = entry["fullName"] ?? entry["name"] ?? ""
                let key = name
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if !key.isEmpty,
                   let item = manager.shoppingListItems.first(where: { $0.normalizedKey == key }) {
                    await manager.purchaseItem(item.id, into: frydge)
                }
            }
            print("[INFO] Applied \(entries.count) notification tick(s) to the shopping list.")
        }
    }

    /// "Milk $4.50" -> "Milk" for legacy list strings with embedded prices.
    private static func strippedOfPrices(_ line: String) -> String {
        line.replacingOccurrences(
                of: #"(NZ)?\$\s?\d+(?:\.\d{1,2})?"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location Manager failed with error: \(error.localizedDescription)")
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways:
            print("Location permission granted (Always).")
            guard StoreArrivalReminders.isEnabled else { return }
            manager.allowsBackgroundLocationUpdates = true
            manager.pausesLocationUpdatesAutomatically = false
            manager.startUpdatingLocation()
            setupRegionMonitoringForStores()
        case .denied, .restricted:
            print("Location permission denied.")
        case .notDetermined:
            print("Location permission not determined.")
        default:
            break
        }
    }

    // APNs registration callbacks
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("[PUSH] ✅✅✅ Registered for remote notifications. deviceToken=\(token)")
        
        // Store for diagnostic purposes
        UserDefaults.standard.set(token, forKey: "APNsDeviceToken")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[PUSH] ❌❌❌ Failed to register for remote notifications: \(error.localizedDescription)")
        print("[PUSH] ❌ Error details: \(error)")
    }

    // Remote push handling (CloudKit query subscriptions, etc)
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable : Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        print("[PUSH] 🔔🔔🔔 didReceiveRemoteNotification FIRED 🔔🔔🔔")
        print("[PUSH] UserInfo: \(userInfo)")
        print("[PUSH] Application state: \(application.applicationState.rawValue) (0=active, 1=inactive, 2=background)")

        if let ck = CKNotification(fromRemoteNotificationDictionary: userInfo) {
            print("[PUSH] ✅ CKNotification parsed, type=\(ck.notificationType.rawValue)")
            
            switch ck.notificationType {
            case .query:
                if let q = ck as? CKQueryNotification,
                   let subID = q.subscriptionID {

                    print("[PUSH] 📋 Query notification, subscriptionID=\(subID)")

                    // ✅ Shopping list pushes
                    if subID.contains(sharedShoppingListSubscriptionPrefix) {
                        print("[PUSH] 🛒🛒🛒 Shared shopping list CloudKit query notification received (subscriptionID=\(subID))")
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: Notification.Name("SharedShoppingListChanged"), object: nil, userInfo: userInfo)
                            NotificationCenter.default.post(name: Notification.Name("CloudKitQueryNotificationReceived"), object: nil, userInfo: userInfo)
                        }
                        completionHandler(.newData)
                        return
                    }

                    // ✅ Shared frydge pushes
                    if subID.contains(sharedFrydgeSubscriptionPrefix) {
                        print("[PUSH] 🧊🧊🧊 Shared frydge CloudKit query notification received (subscriptionID=\(subID))")
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: Notification.Name("SharedFrydgeChanged"), object: nil, userInfo: userInfo)
                            NotificationCenter.default.post(name: Notification.Name("CloudKitQueryNotificationReceived"), object: nil, userInfo: userInfo)
                        }
                        finishAfterMealPlanSync(completionHandler)
                        return
                    }
                }

                print("[PUSH] 📋 CloudKit query notification received (generic)")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Notification.Name("CloudKitQueryNotificationReceived"), object: nil, userInfo: userInfo)
                }
                completionHandler(.newData)
                return
            
            // ✅ CRITICAL: Handle recordZone notifications (for zone subscriptions)
            case .recordZone:
                if let zoneNotif = ck as? CKRecordZoneNotification {
                    print("[PUSH] 📦 Zone notification received")
                    print("[PUSH] 📦 Zone ID: \(zoneNotif.recordZoneID?.zoneName ?? "unknown")")
                    
                    // Check if this is a shopping list or frydge zone
                    if let zoneName = zoneNotif.recordZoneID?.zoneName {
                        print("[PUSH] 📦 Zone name: \(zoneName)")
                        
                        // Shopping list zones (private zone is "ShoppingListZone", shared zones vary)
                        if zoneName.contains("ShoppingList") || zoneName == "ShoppingListZone" {
                            print("[PUSH] 🛒🛒🛒 Shopping list zone changed - triggering refresh")
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(name: Notification.Name("SharedShoppingListChanged"), object: nil, userInfo: userInfo)
                            }
                            completionHandler(.newData)
                            return
                        }
                        
                        // Frydge zones (private zone is "FrydgeFridgeZone", shared zones vary)
                        if zoneName.contains("Frydge") || zoneName.contains("Fridge") || zoneName == "FrydgeFridgeZone" {
                            print("[PUSH] 🧊🧊🧊 Frydge zone changed - triggering refresh")
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(name: Notification.Name("SharedFrydgeChanged"), object: nil, userInfo: userInfo)
                            }
                            finishAfterMealPlanSync(completionHandler)
                            return
                        }
                    }
                    
                    // Generic zone change - refresh both to be safe
                    print("[PUSH] 📦 Generic zone change - refreshing both lists and frydges")
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: Notification.Name("SharedShoppingListChanged"), object: nil, userInfo: userInfo)
                        NotificationCenter.default.post(name: Notification.Name("SharedFrydgeChanged"), object: nil, userInfo: userInfo)
                    }
                    completionHandler(.newData)
                    return
                }

            default:
                print("[PUSH] ⚠️ Unhandled CKNotification type: \(ck.notificationType.rawValue)")
                break
            }
        } else {
            print("[PUSH] ⚠️ Could not parse as CKNotification")
        }

        completionHandler(.noData)
    }

    // UNUserNotificationCenterDelegate methods

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        print("Will present notification: \(content.title)")

        NotificationCenter.default.post(
            name: .showInAppBanner,
            object: nil,
            userInfo: [
                "title": content.title.isEmpty ? "Notification" : content.title,
                "body": content.body,
                "systemImage": "bell",
                "style": "info"
            ]
        )

        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {

        let cat = response.notification.request.content.categoryIdentifier

        if cat == "SHOPPING_LIST_CATEGORY" {
            let store = (response.notification.request.content.userInfo[ShoppingNotificationKeys.storeName] as? String)
                ?? (response.notification.request.content.userInfo["store"] as? String)
                ?? ""
            // Parked for a cold launch, where the SwiftUI subscriber may not
            // exist yet when this posts; cleared once the basket opens.
            UserDefaults.standard.set(store, forKey: StoreArrivalKeys.pendingOpenBasket)
            if !store.isEmpty {
                Task { @MainActor in
                    InStoreSession.shared.begin(storeName: store, source: .notification)
                }
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .navigateToShoppingList, object: nil)
                // Tapping "You're at <store>" means basket mode, not just the list.
                NotificationCenter.default.post(
                    name: .storeArrived,
                    object: nil,
                    userInfo: [
                        StoreArrivalKeys.storeName: store,
                        StoreArrivalKeys.fromNotification: true
                    ]
                )
            }
            // Tapping an item's name in the expanded view parks it in the app
            // group before firing this default action.
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                openShoppingItemTappedInNotificationIfAny()
            }

        } else if cat == sharedShoppingListUpdatedCategory {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Notification.Name("SharedShoppingListChanged"), object: nil)
                NotificationCenter.default.post(name: Notification.Name("NavigateToShoppingList"), object: nil)
            }

        } else if cat == sharedFrydgeUpdatedCategory {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Notification.Name("SharedFrydgeChanged"), object: nil)
            }

        } else if cat == "EXPIRY_REMINDER" {
            switch response.actionIdentifier {
            case "MARK_USED":
                NotificationCenter.default.post(
                    name: Notification.Name("IngredientMarkedUsed"),
                    object: nil,
                    userInfo: [
                        "identifier": response.notification.request.identifier,
                        "userInfo": response.notification.request.content.userInfo
                    ]
                )
                // Used up: take it out of the frydge, which also cancels the
                // item's remaining staged reminders.
                if let idString = response.notification.request.content.userInfo[FrydgeManager.ExpiryNotificationKeys.itemID] as? String,
                   let itemID = UUID(uuidString: idString) {
                    Task { @MainActor in
                        let frydge = FrydgeManager.shared
                        if let item = frydge.storedIngredients.first(where: { $0.id == itemID }) {
                            await frydge.deleteItem(item)
                        }
                    }
                }
            case "ADD_TO_LIST":
                if let name = response.notification.request.content.userInfo["name"] as? String, !name.isEmpty {
                    Task { @MainActor in
                        let manager = ShoppingListManager.current ?? ShoppingListManager()
                        manager.addToShoppingList(name)
                    }
                }
            case "SNOOZE_1H":
                let original = response.notification.request.content.userInfo
                if let name = original["name"] as? String {
                    let newDate = Date().addingTimeInterval(3600)
                    self.scheduleExpiryNotification(
                        name: name,
                        expiryDate: newDate,
                        leadTime: 0,
                        identifier: response.notification.request.identifier,
                        userInfo: original
                    )
                }
            case UNNotificationDefaultActionIdentifier:
                openRecipeTappedInNotificationIfAny()
            case UNNotificationDismissActionIdentifier:
                break
            default:
                break
            }
        } else if cat == LeftoverNotification.categoryID {
            let userInfo = response.notification.request.content.userInfo
            let recipeName = userInfo[LeftoverNotification.recipeNameKey] as? String ?? ""

            switch response.actionIdentifier {
            case LeftoverNotification.actionStore, UNNotificationDefaultActionIdentifier:
                // Open the app and show the leftover configuration sheet.
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .showLeftoverSheet,
                        object: nil,
                        userInfo: [LeftoverNotification.recipeNameKey: recipeName]
                    )
                }
            case LeftoverNotification.actionEaten:
                // User said all eaten — nothing to store.
                print("[Leftovers] User marked '\(recipeName)' as all eaten.")
            default:
                break
            }

        } else {
            print("Unhandled category: \(cat)")
        }

        completionHandler()
    }

    // MARK: - Scene configuration (CarPlay)

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role.rawValue == "CPTemplateApplicationSceneSessionRoleApplication" {
            let config = UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

// MARK: - Scene Delegate bridge (needed for CloudKit share accept + external events in scene-based apps)
final class SceneDelegate: NSObject, UIWindowSceneDelegate {

    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        print("[INVITES] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("[INVITES] 🎉 SceneDelegate.userDidAcceptCloudKitShareWith FIRED")
        print("[INVITES] 📋 Share Record ID: \(cloudKitShareMetadata.share.recordID.recordName)")
        print("[INVITES] 📦 Container ID: \(cloudKitShareMetadata.containerIdentifier)")
        print("[INVITES] 👤 Owner: \(cloudKitShareMetadata.ownerIdentity.nameComponents?.formatted() ?? "Unknown")")
        
        if let rootRef = cloudKitShareMetadata.rootRecord {
            print("[INVITES] 🌳 Root Record ID: \(rootRef.recordID.recordName)")
            print("[INVITES] 🗂️  Root Zone: \(rootRef.recordID.zoneID.zoneName)")
        }
        
        print("[INVITES] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        Task { @MainActor in
            // ✅ IMPORTANT: Add to PendingInvites so the user can see the invite UI
            print("[INVITES] 📝 Adding metadata to PendingInvites...")
            PendingInvites.shared.add(meta: cloudKitShareMetadata)
            
            print("[INVITES] 📢 Broadcasting acceptance notifications...")
            NotificationCenter.default.post(name: .cloudShareAccepted, object: nil)
            NotificationCenter.default.post(name: .cloudShareAcceptedMetadata, object: cloudKitShareMetadata)

            print("[INVITES] 📢 Broadcasting SharedShoppingListChanged")
            NotificationCenter.default.post(name: Notification.Name("SharedShoppingListChanged"), object: nil)
            
            print("[INVITES] 📢 Broadcasting SharedFrydgeChanged")
            NotificationCenter.default.post(name: Notification.Name("SharedFrydgeChanged"), object: nil)
            
            print("[INVITES] ✅ All SceneDelegate acceptance notifications sent")
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        let isCloudKitShare = (userActivity.activityType == "com.apple.cloudkit.share")
        let isBrowsingWeb = (userActivity.activityType == NSUserActivityTypeBrowsingWeb)

        guard isCloudKitShare || isBrowsingWeb else { return }
        guard let url = userActivity.webpageURL else {
            print("[INVITES] SceneDelegate continue userActivity but webpageURL was nil (type=\(userActivity.activityType))")
            return
        }

        // ✅ Only treat iCloud share links as CloudKit shares. Ignore normal web pages.
        guard let host = url.host?.lowercased(), host.contains("icloud.com") else {
            print("[INVITES] SceneDelegate continue userActivity ignored non-icloud URL (type=\(userActivity.activityType)) : \(url.absoluteString)")
            return
        }

        print("[INVITES] SceneDelegate continue userActivity (icloud) (type=\(userActivity.activityType)) : \(url.absoluteString)")

        let op = CKFetchShareMetadataOperation(shareURLs: [url])
        op.perShareMetadataResultBlock = { _, result in
            switch result {
            case .success(let metadata):
                print("[INVITES] SceneDelegate fetched metadata via userActivity")
                Task { @MainActor in
                    PendingInvites.shared.add(meta: metadata)
                }
            case .failure(let error):
                print("[INVITES] SceneDelegate failed to fetch metadata via userActivity: \(error)")
            }
        }
        CKContainer(identifier: "iCloud.com.Clark-Online.Recipe").add(op)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }

        // ✅ Let SwiftUI .onOpenURL handle our app deep links
        let scheme = url.scheme?.lowercased()
        if scheme == "frydgerecipes" || scheme == "frydge" {
            print("[URL] SceneDelegate openURLContexts forwarding \(scheme ?? "?") deep link to SwiftUI: \(url.absoluteString)")
            return
        }

        // ✅ Only treat iCloud share links as CloudKit shares
        guard let host = url.host?.lowercased(), host.contains("icloud.com") else {
            print("[INVITES] SceneDelegate openURLContexts ignored non-icloud URL: \(url.absoluteString)")
            return
        }

        print("[INVITES] SceneDelegate openURLContexts (icloud): \(url.absoluteString)")

        let op = CKFetchShareMetadataOperation(shareURLs: [url])
        op.perShareMetadataResultBlock = { _, result in
            switch result {
            case .success(let metadata):
                print("[INVITES] SceneDelegate fetched metadata via openURLContexts")
                Task { @MainActor in
                    PendingInvites.shared.add(meta: metadata)
                }
            case .failure(let error):
                print("[INVITES] SceneDelegate failed to fetch metadata via openURLContexts: \(error)")
            }
        }
        CKContainer(identifier: "iCloud.com.Clark-Online.Recipe").add(op)
    }
}
