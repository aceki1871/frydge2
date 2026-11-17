//
//  FrydgeManager.swift
//  FrydgeRecipes
//  Josh Clark
//

import Foundation
import CloudKit
import Combine
import CoreData
import UserNotifications
import UIKit

// MARK: - Models

struct StoredIngredient: Identifiable, Hashable, Codable {

    /// Shopping lifecycle is handled by ShoppingListManager and only sends purchased items into Frydge.
    /// - `fridge`: a normal food item / ingredient.
    /// - `leftover`: cooked-meal portions stored after cooking a recipe. These live in the
    ///   same synced store so they appear in the fridge and roam across devices, but they are
    ///   excluded from recipe ingredient matching (a cooked dish isn't a raw ingredient).
    enum ItemLifecycle: String, Codable, CaseIterable {
        case fridge
        case leftover
    }

    var id: UUID
    var name: String
    var quantity: String
    var unit: String
    var expirationDate: Date
    var location: String
    var dietaryTags: Set<String>
    var lifecycle: ItemLifecycle

    /// Percentage of item used (0-100). Used for tracking consumption in recipes.
    var quantityUsed: Double

    /// User-uploaded photos stored as JPEG data, newest first.
    var userPhotoData: [Data]

    // Centralised expiry logic so all views (mine + shared) can use the same flag
    var isExpired: Bool {
        expirationDate < Calendar.current.startOfDay(for: Date())
    }

    // Returns a realistic shelf-life estimate based on the food name.
    // The full shelf-life table now lives in FoodStorageClassifier so the same
    // logic can be shared with the location-aware best-before calculation.
    static func defaultExpiry(for name: String) -> Date {
        FoodStorageClassifier.bestBefore(for: name, location: FoodStorageClassifier.fridge)
    }

    init(
        id: UUID = UUID(),
        name: String,
        quantity: String,
        unit: String,
        expirationDate: Date,
        location: String,
        dietaryTags: Set<String> = [],
        lifecycle: ItemLifecycle = .fridge,
        quantityUsed: Double = 0.0,
        userPhotoData: [Data] = []
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.expirationDate = expirationDate
        self.location = location
        self.dietaryTags = dietaryTags
        self.lifecycle = lifecycle
        self.quantityUsed = max(0, min(100, quantityUsed))
        self.userPhotoData = userPhotoData
    }

    enum CodingKeys: String, CodingKey {
        case id, name, quantity, unit, expirationDate, location, dietaryTags, lifecycle, quantityUsed, userPhotoData
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        quantity = try c.decode(String.self, forKey: .quantity)
        unit = try c.decode(String.self, forKey: .unit)
        expirationDate = try c.decode(Date.self, forKey: .expirationDate)
        location = try c.decode(String.self, forKey: .location)
        // Fields below were added after the 4.6 App Store builds: JSON persisted
        // by older versions doesn't contain them, so they must default rather
        // than fail the decode (a failed decode silently drops the whole backup).
        dietaryTags = try c.decodeIfPresent(Set<String>.self, forKey: .dietaryTags) ?? []
        lifecycle = try c.decodeIfPresent(ItemLifecycle.self, forKey: .lifecycle) ?? .fridge
        quantityUsed = try c.decodeIfPresent(Double.self, forKey: .quantityUsed) ?? 0.0
        userPhotoData = (try? c.decode([Data].self, forKey: .userPhotoData)) ?? []
    }

    /// Photo bytes are excluded from encoding on purpose: the JSON file is only
    /// a rollback backup, and embedding JPEGs (as base64) made every backup write
    /// re-serialize megabytes on the main thread. Photos live in Core Data
    /// (`CDItemPhoto`) and sync via CloudKit; the decoder above still reads
    /// photos from old backups for the one-time upgrade migration.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(quantity, forKey: .quantity)
        try c.encode(unit, forKey: .unit)
        try c.encode(expirationDate, forKey: .expirationDate)
        try c.encode(location, forKey: .location)
        try c.encode(dietaryTags, forKey: .dietaryTags)
        try c.encode(lifecycle, forKey: .lifecycle)
        try c.encode(quantityUsed, forKey: .quantityUsed)
    }
}

struct IngredientEntry: Codable {
    let name: String
    let expirationDate: Date
}

@MainActor
final class FrydgeManager: ObservableObject {
    static let shared = FrydgeManager()

    // MARK: - Published

    // Old string lists (kept for compatibility with existing views)
    @Published var ingredients: [String] = []
    @Published var pans: [String] = []
    @Published var householdItems: [String] = []

    // New structured inventory (fridge-only)
    @Published var storedIngredients: [StoredIngredient] = []

    /// Fridge index for recipe matching, rebuilt only when the matchable item
    /// names change. Owned here, used by the RecipeMatch extension.
    var matchIndexCache: (names: [String], index: IngredientMatcher.Index)?

    @Published var isSyncingPaused = false

    // MARK: - CloudKit
    //
    // `cloudContainer` is retained only to resolve the iCloud user record ID for
    // per-user local file scoping. All record-level CloudKit work is now handled
    // by NSPersistentCloudKitContainer via PersistenceController.

    let cloudContainer = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")

    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Per-user scoping (Mine inventory local caches)

    private let appGroupName = "group.Clark-Online.FrydgeRecipeAPN"

    /// Stable install-scoped ID used until the iCloud user record resolves.
    ///
    /// Previously this fell back to the literal string "local", which meant every
    /// iCloud account on a shared device read and wrote the SAME
    /// `storedIngredients_local.json` — one user's fridge was visible to the next.
    /// Mirrors the approach already used in ShoppingListManager.
    private var installScopedID: String {
        let key = "installScopedFrydgeID"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty { return existing }
        let created = "install_" + UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        UserDefaults(suiteName: appGroupName)?.set(created, forKey: key)
        return created
    }

    /// Resolve once and store for stable per-user local file names.
    private var userID: String {
        if let v = UserDefaults.standard.string(forKey: "appleUserID"), !v.isEmpty { return v }
        if let v = UserDefaults(suiteName: appGroupName)?.string(forKey: "appleUserID"), !v.isEmpty { return v }
        return installScopedID
    }

    private func resolveAndPersistAppleUserIDIfNeeded() async {
        if let existing = UserDefaults.standard.string(forKey: "appleUserID"),
           !existing.isEmpty,
           existing != "local" {
            return
        }

        // Capture the pre-resolution filenames BEFORE appleUserID is written,
        // so we can migrate anything written while install-scoped.
        let previousStoredIngredientsFile = storedIngredientsFileName
        let previousIngredientsFile = ingredientsFileNameScoped
        let previousTombstonesKey = "frydge_deletedTombstones_\(userID)"

        do {
            let rid = try await cloudContainer.userRecordID()
            UserDefaults.standard.set(rid.recordName, forKey: "appleUserID")
            UserDefaults(suiteName: appGroupName)?.set(rid.recordName, forKey: "appleUserID")
            print("[INFO] FrydgeManager resolved appleUserID: \(rid.recordName)")

            // Carry install-scoped (and legacy "local") caches over to the
            // now-known per-user filenames. Without this the items written
            // during the pre-resolution window are orphaned on disk.
            migrateScopedCaches(
                fromStoredIngredientsFile: previousStoredIngredientsFile,
                fromIngredientsFile: previousIngredientsFile,
                fromTombstonesKey: previousTombstonesKey
            )

            // Reload per-user local caches now that the userID is known.
            loadFridgeData()
            loadStoredIngredientsFromFile()
            refreshExpiryNotifications()
        } catch {
            print("[WARN] FrydgeManager could not resolve appleUserID yet: \(error.localizedDescription)")
        }
    }

    /// Moves pre-resolution caches to the resolved per-user filenames.
    /// Also sweeps up the historical `_local` bucket from builds that used it.
    private func migrateScopedCaches(
        fromStoredIngredientsFile oldStoredFile: String,
        fromIngredientsFile oldIngredientsFile: String,
        fromTombstonesKey oldTombstonesKey: String
    ) {
        let fm = FileManager.default
        let dir = getDocumentsDirectory()

        func migrateFile(from old: String, to new: String) {
            guard old != new else { return }
            let oldURL = dir.appendingPathComponent(old)
            let newURL = dir.appendingPathComponent(new)
            guard fm.fileExists(atPath: oldURL.path) else { return }
            guard !fm.fileExists(atPath: newURL.path) else { return } // never clobber
            do {
                try fm.moveItem(at: oldURL, to: newURL)
                print("[MIGRATE] \(old) -> \(new)")
            } catch {
                print("[MIGRATE ERROR] \(old) -> \(new): \(error.localizedDescription)")
            }
        }

        // Install-scoped bucket, then the historical "local" bucket.
        migrateFile(from: oldStoredFile, to: storedIngredientsFileName)
        migrateFile(from: "storedIngredients_local.json", to: storedIngredientsFileName)
        migrateFile(from: oldIngredientsFile, to: ingredientsFileNameScoped)
        migrateFile(from: "ingredients_local.json", to: ingredientsFileNameScoped)

        // Tombstone migration removed: deletion is now a synced Core Data fact
        // (CDFridgeItem.deletedAt), not a per-device UserDefaults dictionary.
        UserDefaults.standard.removeObject(forKey: oldTombstonesKey)
        UserDefaults.standard.removeObject(forKey: "frydge_deletedTombstones_local")
    }

    // MARK: - Local File Names (scoped)

    // Legacy file names (previous single-user cache). Kept for backward migration.
    private let legacyIngredientsFileName = "ingredients.json"

    /// Per-user local cache file for structured inventory.
    private var storedIngredientsFileName: String { "storedIngredients_\(userID).json" }

    /// Per-user local cache files for legacy lists (kept for compatibility with existing views).
    private var ingredientsFileNameScoped: String { "ingredients_\(userID).json" }

    // MARK: - Deletion
    //
    // The UserDefaults tombstone dictionary that used to live here is gone.
    // Deletion is now a synced fact (`CDFridgeItem.deletedAt`), so it reaches
    // every device instead of expiring locally after 7 days.

    // MARK: - Derived

    var inventoryList: [String] {
        storedIngredients
            .filter { $0.lifecycle == .fridge }
            .map { $0.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: - Init

    init() {
        loadFridgeData()
        loadStoredIngredientsFromFile()
        refreshExpiryNotifications()
        startObservingRemoteChanges()
        Task { await resolveAndPersistAppleUserIDIfNeeded() }
    }

    /// iCloud account switched while installed. `AccountChangeMonitor` has
    /// already replaced the stored `appleUserID`; drop the previous user's
    /// in-memory inventory and re-read the caches scoped to the new identity.
    /// `lastPersistedIDs` is reset so the next write-through cannot interpret
    /// the old account's rows as deletions.
    @MainActor
    func handleAccountChange() {
        storedIngredients = []
        lastPersistedIDs = []
        ingredients = []
        loadFridgeData()
        loadStoredIngredientsFromFile()
        refreshExpiryNotifications()
    }

    // MARK: - Add / Upsert Structured Product (LOCAL-FIRST)

    @MainActor
    func addProduct(
        name: String,
        quantity: String,
        unit: String,
        expirationDate: Date,
        location: String,
        dietaryTags: Set<String> = [],
        lifecycle: StoredIngredient.ItemLifecycle = .fridge
    ) {
        var newItem = StoredIngredient(
            name: name,
            quantity: quantity,
            unit: unit,
            expirationDate: expirationDate,
            location: location,
            dietaryTags: dietaryTags,
            lifecycle: lifecycle
        )

        // Double-up duplicates: same item + a compatible unit → sum the amounts
        // (e.g. two 500 g steaks become one 1 kg entry) rather than a second row.
        if let idx = storedIngredients.firstIndex(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame &&
            $0.lifecycle == lifecycle &&
            FridgeUnits.canCombine(unitA: $0.unit, unitB: unit)
        }) {
            var merged = storedIngredients[idx]
            if let combined = FridgeUnits.combine(
                quantityA: merged.quantity, unitA: merged.unit,
                quantityB: quantity, unitB: unit
            ) {
                merged.quantity = combined.quantity
                merged.unit = combined.unit
            } else {
                // Couldn't sum numerically — keep the newest amount.
                merged.quantity = quantity
                merged.unit = unit
            }
            merged.dietaryTags = merged.dietaryTags.union(dietaryTags)
            merged.expirationDate = min(merged.expirationDate, expirationDate)
            storedIngredients[idx] = merged
            newItem = merged
        } else {
            storedIngredients.append(newItem)
        }

        saveStoredIngredientsToFile()
        enqueueCloudSync(for: newItem)
        scheduleExpiryNotification(for: newItem)

        // Every fridge entry path lands here (manual, barcode, receipt / list /
        // fridge scans, cook-mode leftovers), so this is the one place to warn
        // about something the user said they can't or won't eat.
        if lifecycle == .fridge {
            DietaryRestrictionStore.shared.notifyIfFlagged(name: name, addedTo: .fridge)
        }
    }

    /// Restores items from a Your Data backup file. Items whose id is already
    /// in the fridge are skipped; everything else is added exactly as saved
    /// (same id, usage, expiry) and queued for the normal cloud sync.
    /// Returns how many were added.
    @MainActor
    @discardableResult
    func restoreFromBackup(_ items: [StoredIngredient]) -> Int {
        let existingIDs = Set(storedIngredients.map(\.id))
        var added = 0
        for item in items where !existingIDs.contains(item.id) {
            guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            storedIngredients.append(item)
            enqueueCloudSync(for: item)
            scheduleExpiryNotification(for: item)
            added += 1
        }
        if added > 0 { saveStoredIngredientsToFile() }
        return added
    }

    /// Adds a product using FoodStorageClassifier's best-guess location and
    /// expiry. If the name doesn't match any of the classifier's keyword
    /// lists, asks the on-device model to refine the guess afterwards. The
    /// refinement only overwrites the item if it still has the original
    /// auto-assigned location and expiry — anything the user (or a sync)
    /// changed in the meantime is left alone.
    func addAutoClassifiedProduct(
        name: String,
        quantity: String,
        unit: String,
        dietaryTags: Set<String> = [],
        lifecycle: StoredIngredient.ItemLifecycle = .fridge
    ) {
        let location = FoodStorageClassifier.suggestedLocation(for: name)
        let expiry = FoodStorageClassifier.bestBefore(for: name, location: location)
        addProduct(
            name: name,
            quantity: quantity,
            unit: unit,
            expirationDate: expiry,
            location: location,
            dietaryTags: dietaryTags,
            lifecycle: lifecycle
        )

        guard lifecycle == .fridge, !FoodStorageClassifier.hasKeywordMatch(for: name) else { return }
        Task { [weak self] in
            guard let self, let guess = await FoodStorageAI.refine(name: name) else { return }
            guard let idx = self.storedIngredients.firstIndex(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame &&
                $0.lifecycle == .fridge &&
                $0.location == location &&
                $0.expirationDate == expiry
            }) else { return }
            self.storedIngredients[idx].location = guess.location
            self.storedIngredients[idx].expirationDate = guess.expiryDate
            self.saveStoredIngredientsToFile()
        }
    }

    /// One-off pass that fuses existing fridge duplicates (same name + a
    /// compatible unit) into a single summed entry — e.g. two 500 g steaks
    /// already in the fridge become one 1 kg entry. Safe on the synced store:
    /// `saveStoredIngredientsToFile()` reconciles by absence, so absorbed rows
    /// are soft-deleted and that deletion replicates to every device.
    func consolidateDuplicates() {
        var result: [StoredIngredient] = []
        var keyToIndex: [String: Int] = [:]
        var didMerge = false

        for item in storedIngredients {
            guard item.lifecycle == .fridge else {
                result.append(item)
                continue
            }
            let key = item.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                + "|" + FridgeUnits.groupKey(unit: item.unit)

            if let idx = keyToIndex[key] {
                var survivor = result[idx]
                if let combined = FridgeUnits.combine(
                    quantityA: survivor.quantity, unitA: survivor.unit,
                    quantityB: item.quantity, unitB: item.unit
                ) {
                    survivor.quantity = combined.quantity
                    survivor.unit = combined.unit
                }
                survivor.dietaryTags = survivor.dietaryTags.union(item.dietaryTags)
                survivor.expirationDate = min(survivor.expirationDate, item.expirationDate)
                result[idx] = survivor
                didMerge = true
            } else {
                keyToIndex[key] = result.count
                result.append(item)
            }
        }

        guard didMerge else { return }
        storedIngredients = result
        saveStoredIngredientsToFile()
    }

    // MARK: - Item Mutations

    func setExpirationDate(for id: UUID, to newDate: Date) {
        guard let index = storedIngredients.firstIndex(where: { $0.id == id }) else { return }
        var item = storedIngredients[index]
        item.expirationDate = newDate
        storedIngredients[index] = item

        saveStoredIngredientsToFile()
        enqueueCloudSync(for: item)
        scheduleExpiryNotification(for: item)
    }

    func setLocation(for id: UUID, to newLocation: String) {
        guard let index = storedIngredients.firstIndex(where: { $0.id == id }) else { return }

        var item = storedIngredients[index]
        let trimmed = newLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        item.location = trimmed.isEmpty ? item.location : trimmed

        item.expirationDate = FoodStorageClassifier.adjustedExpiryDate(
            currentExpiry: item.expirationDate,
            name: item.name,
            forLocation: item.location
        )

        storedIngredients[index] = item

        saveStoredIngredientsToFile()
        enqueueCloudSync(for: item)
        scheduleExpiryNotification(for: item)
    }

    func updateUserPhotos(for id: UUID, photos: [Data]) {
        guard let index = storedIngredients.firstIndex(where: { $0.id == id }) else { return }
        storedIngredients[index].userPhotoData = photos
        saveStoredIngredientsToFile()

        // Photos are written here rather than in the general write-through: with
        // external binary storage, comparing blobs faults every one of them into
        // memory, and this is the only place photos actually change.
        writePhotosThroughToStore(id: id, photos: photos)
    }

    func setDietaryTags(for id: UUID, to newTags: Set<String>) {
        guard let index = storedIngredients.firstIndex(where: { $0.id == id }) else { return }
        var item = storedIngredients[index]
        item.dietaryTags = newTags
        storedIngredients[index] = item

        saveStoredIngredientsToFile()
        enqueueCloudSync(for: item)
    }
    
    /// Update quantity used percentage (0-100)
    func setQuantityUsed(for id: UUID, to percentage: Double) {
        guard let index = storedIngredients.firstIndex(where: { $0.id == id }) else { return }
        var item = storedIngredients[index]
        item.quantityUsed = max(0, min(100, percentage))
        storedIngredients[index] = item

        saveStoredIngredientsToFile()
        enqueueCloudSync(for: item)
        
        // If fully used, optionally auto-delete
        if item.quantityUsed >= 100 {
            Task {
                await deleteItem(item)
            }
        }
    }
    
    /// Increment quantity used by a given percentage
    func incrementQuantityUsed(for id: UUID, by percentage: Double) {
        guard let index = storedIngredients.firstIndex(where: { $0.id == id }) else { return }
        let current = storedIngredients[index].quantityUsed
        setQuantityUsed(for: id, to: current + percentage)
    }
    
    /// Mark ingredients as used when cooking a recipe. Recipe lines are matched
    /// to fridge items with the shared matcher, so "rice" never deducts "Ice"
    /// and a brand word never counts. Each item is deducted at most once per
    /// cook even if two lines resolve to it.
    func markIngredientsUsed(_ ingredientNames: [String], percentage: Double = 100.0) {
        // Snapshot items and index together so positions stay aligned while
        // deductions mutate `storedIngredients`.
        let items = matchableFridgeItems
        let index = fridgeMatchIndex
        var deducted: Set<UUID> = []
        for name in ingredientNames {
            let tokens = IngredientMatcher.recipeLineTokens(name)
            guard !tokens.isEmpty else { continue }
            for position in index.allMatches(tokens) where position < items.count {
                let id = items[position].id
                guard deducted.insert(id).inserted else { continue }
                incrementQuantityUsed(for: id, by: percentage)
            }
        }
    }

    // MARK: - Leftovers (cooked-meal portions stored as fridge items)

    /// Leftover portions currently stored, soonest expiry first.
    var leftovers: [StoredIngredient] {
        storedIngredients
            .filter { $0.lifecycle == .leftover }
            .sorted { $0.expirationDate < $1.expirationDate }
    }

    /// Store leftovers from a cooked recipe as a synced fridge item.
    /// Portions are held in `quantity` (unit "portion"); `location` is the destination label.
    @discardableResult
    func addLeftover(
        id: UUID = UUID(),
        recipeName: String,
        portions: Int,
        expiryDate: Date,
        location: String
    ) -> StoredIngredient {
        let item = StoredIngredient(
            id: id,
            name: recipeName,
            quantity: String(max(1, portions)),
            unit: "portion",
            expirationDate: expiryDate,
            location: location,
            dietaryTags: [],
            lifecycle: .leftover
        )
        storedIngredients.append(item)
        saveStoredIngredientsToFile()
        enqueueCloudSync(for: item)
        return item
    }

    /// Update remaining leftover portions; deletes the item when it reaches zero.
    func setLeftoverPortions(id: UUID, portions: Int) {
        guard let idx = storedIngredients.firstIndex(where: { $0.id == id }) else { return }
        if portions <= 0 {
            let item = storedIngredients[idx]
            Task { await deleteItem(item) }
            return
        }
        storedIngredients[idx].quantity = String(portions)
        saveStoredIngredientsToFile()
        enqueueCloudSync(for: storedIngredients[idx])
    }

    /// Delete any stored item by id (used by the leftovers UI).
    func deleteItem(byID id: UUID) {
        guard let item = storedIngredients.first(where: { $0.id == id }) else { return }
        Task { await deleteItem(item) }
    }

    /// Remove all expired leftovers.
    func purgeExpiredLeftovers() {
        let expired = storedIngredients.filter { $0.lifecycle == .leftover && $0.isExpired }
        guard !expired.isEmpty else { return }
        Task { await deleteSelected(items: Set(expired.map { $0.id })) }
    }

    /// Recomputes an item's best-before when it moves storage location.
    /// Uses the name-aware FoodStorageClassifier, but never surprises the user by
    /// shortening a freezer date they may have already extended.
    @MainActor
    func setLifecycle(for id: UUID, to lifecycle: StoredIngredient.ItemLifecycle) {
        guard let idx = storedIngredients.firstIndex(where: { $0.id == id }) else { return }
        storedIngredients[idx].lifecycle = lifecycle

        saveStoredIngredientsToFile()
        enqueueCloudSync(for: storedIngredients[idx])
        scheduleExpiryNotification(for: storedIngredients[idx])
    }

    // MARK: - Persistence & Sync (Core Data + CloudKit mirroring)
    //
    // PHASE 3 CUTOVER.
    //
    // Deleted from here: CKRecord push/pull, the per-device UserDefaults tombstone
    // dictionary, the dirty-ID set, the debounce, the retry scheduler, and a
    // full-table CKQuery whose cursor was discarded. Between them those carried
    // four silent data-loss paths (see CODE_REVIEW_2026-08.md P0-3/4/5, P1-2/3/4).
    //
    // NSPersistentCloudKitContainer now provides change tokens, property-level
    // conflict resolution, a durable offline queue, synced deletes and push-driven
    // updates as built-in behaviour.
    //
    // SOURCE OF TRUTH IS CORE DATA. The JSON file is still written as a rollback
    // backup, but it is only READ when Core Data has nothing to offer — i.e. the
    // first launch after upgrading.

    private var storeContext: NSManagedObjectContext {
        PersistenceController.shared.container.viewContext
    }

    private var coreDataAvailable: Bool {
        !PersistenceController.shared.isDegraded
    }

    /// Observes CloudKit-driven merges so a change made on another device appears
    /// without any manual pull. Previously the only refresh triggers were
    /// FridgeView.onAppear and pull-to-refresh.
    private func startObservingRemoteChanges() {
        guard coreDataAvailable else { return }

        NotificationCenter.default
            .publisher(for: .NSPersistentStoreRemoteChange)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.reloadFromStore() }
            }
            .store(in: &cancellables)
    }

    /// Rebuilds the published array from Core Data.
    ///
    /// This is the ONLY path that refreshes `storedIngredients` from persistence.
    /// It deliberately does not call `saveStoredIngredientsToFile()`, which would
    /// write straight back into the store and create a feedback loop.
    func reloadFromStore() {
        guard coreDataAvailable else { return }
        do {
            let rows = try storeContext.fetch(CDFridgeItem.fetchRequestForActiveItems())
            let loaded = rows.map { $0.toStoredIngredient() }
            lastPersistedIDs = Set(loaded.map(\.id))
            seedCompleted = true
            // Remote-change notifications also fire for writes that never touched
            // the fridge (e.g. the shopping list in the same store). Republishing
            // an identical array re-rendered every screen watching the fridge and
            // rescheduled every expiry notification, so skip when nothing changed.
            guard loaded != storedIngredients else { return }
            storedIngredients = loaded
            writeBackupJSON()
            refreshExpiryNotifications()
        } catch {
            print("[STORE ERROR] reload failed: \(error.localizedDescription)")
        }
    }

    /// IDs that were in the array the last time it was loaded from, or
    /// persisted to, the store. Deletions are derived from this snapshot, not
    /// from the store's current contents: a row that arrived from another
    /// device but has not reached the array yet was never removed by the user.
    private var lastPersistedIDs: Set<UUID> = []

    /// Set once the Core Data store has been confirmed as the source of truth
    /// for this user. After that an empty fetch means "the fridge is empty" and
    /// the JSON backup is never used to reseed it.
    private var seedCompletedKey: String { "coreDataSeedCompleted.fridge.\(userID)" }

    private var seedCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: seedCompletedKey) }
        set { UserDefaults.standard.set(newValue, forKey: seedCompletedKey) }
    }

    /// Pushes the in-memory array into Core Data.
    ///
    /// Upserts every present item and soft-deletes only IDs that were in the last
    /// persisted snapshot and are now absent. A soft delete is a synced fact, so
    /// it reaches every device. A row another device already soft-deleted stays
    /// deleted when the local array still holds it from before the deletion
    /// synced; an ID new to this device is an explicit re-add and is restored.
    ///
    /// Returns `false` when the store refused the save.
    @discardableResult
    private func writeThroughToStore() -> Bool {
        guard coreDataAvailable else { return false }
        let ctx = storeContext
        do {
            let present = Set(storedIngredients.map(\.id))
            var survivors = present

            for item in storedIngredients {
                let row = try ctx.upsertFridgeItem(id: item.id)
                if row.deletedAt != nil {
                    if lastPersistedIDs.contains(item.id) {
                        survivors.remove(item.id)  // synced deletion wins
                        continue
                    }
                    row.deletedAt = nil  // explicit re-add / restore
                }
                row.apply(item, includingPhotos: false, in: ctx)
            }

            let removed = lastPersistedIDs.subtracting(present)
            if !removed.isEmpty {
                for row in try ctx.fetch(CDFridgeItem.fetchRequestForActiveItems()) {
                    guard let id = row.id, removed.contains(id) else { continue }
                    row.softDelete()
                }
            }

            guard PersistenceController.shared.saveIfNeeded(ctx) else { return false }
            lastPersistedIDs = survivors
            return true
        } catch {
            print("[STORE ERROR] write-through failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Writes an item's photos into Core Data as separate rows with external
    /// binary storage, so editing a name never re-uploads photo bytes.
    private func writePhotosThroughToStore(id: UUID, photos: [Data]) {
        guard coreDataAvailable else { return }
        let ctx = storeContext
        do {
            let row = try ctx.upsertFridgeItem(id: id)
            row.replacePhotos(with: photos, in: ctx)
            if row.hasPersistentChangedValues || ctx.hasChanges { row.updatedAt = Date() }
            PersistenceController.shared.saveIfNeeded(ctx)
        } catch {
            print("[STORE ERROR] photo write-through failed: \(error.localizedDescription)")
        }
    }

    /// Bounded, on-demand read of the photos CloudKit synced for one item
    /// (`CDItemPhoto` rows). The list mapping deliberately leaves
    /// `userPhotoData` empty so a 200-item fridge never loads 200 blobs; the
    /// detail sheet calls this for the single item being shown, and
    /// `UserPhotoLibrary` seeds its device-local cache from the result so a
    /// photo taken on another device becomes visible here.
    func syncedPhotos(forItemID id: UUID) -> [Data] {
        guard coreDataAvailable else { return [] }
        do {
            guard let row = try storeContext.fetch(CDFridgeItem.fetchRequest(forID: id)).first else { return [] }
            return CDItemPhoto.blobs(row.photos)
        } catch {
            print("[STORE ERROR] photo read failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Compatibility shims
    //
    // Kept so existing call sites in FridgeView / ShoppingListView keep compiling.
    // Syncing is no longer something this class does by hand.

    /// Was: full CKQuery pull. Now just re-reads the store, which CloudKit keeps current.
    func syncFromCloud() async {
        reloadFromStore()
    }

    /// Was: push every item as an individual CKModifyRecordsOperation.
    func syncStoredIngredientsToCloud() async {
        writeThroughToStore()
    }

    /// Was: push the dirty set. Core Data tracks dirt itself.
    func syncDirtyToCloud(pushAll: Bool = false) async {
        writeThroughToStore()
    }

    /// Was: mark the item dirty and arm a debounce. No-op — the write-through in
    /// `saveStoredIngredientsToFile()` has already persisted it.
    func enqueueCloudSync(for item: StoredIngredient) {}


    // MARK: - Local Data Management (Legacy Lists)

    func loadFridgeData() {
        ingredients = loadItems(from: ingredientsFileNameScoped) ?? []
        pans = []
        householdItems = []

        if ingredients.isEmpty, let legacy = loadItems(from: legacyIngredientsFileName), !legacy.isEmpty {
            ingredients = legacy
            saveItems(ingredients, to: ingredientsFileNameScoped)
        }

        print("[LOG] Loaded data: Ingredients: \(ingredients.count)")
    }

    func saveFridgeData() {
        saveItems(ingredients, to: ingredientsFileNameScoped)
        print("[LOG] Fridge data saved.")
    }

    /// Rollback backup only. Nothing reads this except `seedFromBackupJSON()` on
    /// the first launch after upgrading.
    private func writeBackupJSON() {
        do {
            let data = try JSONEncoder().encode(storedIngredients)
            let url = getDocumentsDirectory().appendingPathComponent(storedIngredientsFileName)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("[ERROR] Saving storedIngredients backup: \(error.localizedDescription)")
        }
    }

    /// Name retained — ~20 call sites depend on it. Now persists to Core Data
    /// (the source of truth) and writes the JSON rollback backup.
    private func saveStoredIngredientsToFile() {
        writeThroughToStore()
        writeBackupJSON()
    }

    /// Core Data wins. The JSON file is consulted only when the store is empty,
    /// which is the first launch after upgrading.
    func loadStoredIngredientsFromFile() {
        if coreDataAvailable {
            do {
                let rows = try storeContext.fetch(CDFridgeItem.fetchRequestForActiveItems())
                if !rows.isEmpty {
                    storedIngredients = rows.map { $0.toStoredIngredient() }
                    lastPersistedIDs = Set(storedIngredients.map(\.id))
                    seedCompleted = true
                    return
                }
                if seedCompleted {
                    // Genuinely empty (cleared, or deletions synced in). Do not
                    // resurrect the backup.
                    storedIngredients = []
                    lastPersistedIDs = []
                    return
                }
            } catch {
                // Degraded read: keep the in-memory state, do not seed into a
                // store we cannot read.
                print("[STORE ERROR] initial fetch failed: \(error.localizedDescription)")
                return
            }
        }
        seedFromBackupJSON()
    }

    /// One-way upgrade path: read the legacy JSON and push it into Core Data.
    /// The seed is marked complete only after the store accepted the rows, so an
    /// interrupted import is retried next launch and the backup is never the
    /// only copy that gets consumed.
    private func seedFromBackupJSON() {
        let url = getDocumentsDirectory().appendingPathComponent(storedIngredientsFileName)
        var loaded: [StoredIngredient] = []

        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([StoredIngredient].self, from: data) {
            loaded = decoded
        } else {
            let legacyURL = getDocumentsDirectory().appendingPathComponent("storedIngredients.json")
            if let legacyData = try? Data(contentsOf: legacyURL),
               let legacyItems = try? JSONDecoder().decode([StoredIngredient].self, from: legacyData) {
                loaded = legacyItems
                print("[MIGRATE] Seeded from legacy storedIngredients.json")
            }
        }

        guard !loaded.isEmpty else {
            // Nothing to migrate: the store is legitimately empty for this user.
            if coreDataAvailable { seedCompleted = true }
            return
        }
        storedIngredients = loaded
        lastPersistedIDs = []
        guard writeThroughToStore() else { return }
        // Legacy backups embedded photo bytes in the JSON; the write-through
        // skips photos by design, so persist them into CDItemPhoto once here.
        for item in loaded where !item.userPhotoData.isEmpty {
            writePhotosThroughToStore(id: item.id, photos: item.userPhotoData)
        }
        seedCompleted = true
        print("[MIGRATE] Seeded \(loaded.count) fridge items into Core Data.")
    }


    // MARK: - Legacy string lists (unchanged behavior)

    @MainActor
    func addToInventory(_ item: String) {
        let cleaned = item
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        if !ingredients.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            ingredients.append(cleaned)
            saveFridgeData()
        }

        addAutoClassifiedProduct(name: cleaned, quantity: "1", unit: "")
    }

    func removeFromInventory(_ item: String) {
        ingredients.removeAll { $0 == item }
        saveFridgeData()
    }

    func addPan(_ pan: String) {
        guard !pans.contains(pan) else { return }
        pans.append(pan)
        saveFridgeData()
    }

    func removePan(_ pan: String) {
        pans.removeAll { $0 == pan }
        saveFridgeData()
    }

    func addHouseholdItem(_ item: String) {
        guard !householdItems.contains(item) else { return }
        householdItems.append(item)
        saveFridgeData()
    }

    func removeHouseholdItem(_ item: String) {
        householdItems.removeAll { $0 == item }
        saveFridgeData()
    }

    func addItem(_ item: String, toCategory category: String) {
        switch category {
        case "Ingredients": addToInventory(item)
        case "Pans": addPan(item)
        case "Household": addHouseholdItem(item)
        default: print("[ERROR] Unknown category: \(category)")
        }
    }

    func removeItem(_ item: String, fromCategory category: String) {
        switch category {
        case "Ingredients": removeFromInventory(item)
        case "Pans": removePan(item)
        case "Household": removeHouseholdItem(item)
        default: print("[ERROR] Unknown category: \(category)")
        }
    }

    // MARK: - Match %

    /// Kept for source compatibility. Now answers from `storedIngredients`
    /// through the shared matcher (see RecipeMatch.swift) instead of the
    /// legacy `ingredients` string list, so every screen agrees.
    func calculateMatchPercentage(for recipeIngredients: [String]) -> Double {
        matchPercentage(for: recipeIngredients)
    }

    // MARK: - Expiration Notifications (FRIDGE ONLY)
    //
    // Three reminders per item, each at 9am so they land at a useful hour
    // rather than at midnight when the date rolls over:
    //   • the day before it expires ("expires tomorrow"),
    //   • the day it expires ("expires today"),
    //   • the day after ("expired yesterday — check it before you cook").
    // Each carries the item's emoji (and photo, when it has one), its amount
    // and up to three recipes that use it, so the expanded notification is a
    // card that answers "what do I do with this?" rather than just "it's
    // going off".

    enum ExpiryStage: String, CaseIterable {
        case soon
        case today
        case expired

        /// Days relative to the expiry date the reminder fires on.
        var dayOffset: Int {
            switch self {
            case .soon:    return -1
            case .today:   return 0
            case .expired: return 1
            }
        }
    }

    private nonisolated static let expiryReminderHour = 9

    private nonisolated static func notificationIdentifier(for item: StoredIngredient, stage: ExpiryStage) -> String {
        "EXPIRY_\(item.id.uuidString)_\(stage.rawValue)"
    }

    private nonisolated static func expiryNotificationIdentifiers(for item: StoredIngredient) -> [String] {
        // The bare identifier is the pre-staged form; clear it too in case
        // one is still pending from an older build.
        ExpiryStage.allCases.map { notificationIdentifier(for: item, stage: $0) } + ["EXPIRY_\(item.id.uuidString)"]
    }

    private nonisolated static func cancelExpiryNotification(for item: StoredIngredient) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: expiryNotificationIdentifiers(for: item))
    }

    /// Reschedules one item's reminders after an add or edit. Snapshots the
    /// fridge on the main actor, then does the recipe matching and the
    /// notification-centre calls on a background task.
    private func scheduleExpiryNotification(for item: StoredIngredient) {
        let fridgeIndex = fridgeMatchIndex
        let fridgeItems = matchableFridgeItems
        Task.detached(priority: .utility) {
            let recipes = Self.cachedRecipesForSuggestions()
            let suggestions = Self.expirySuggestions(
                for: item,
                from: recipes,
                fridgeIndex: fridgeIndex,
                fridgeItems: fridgeItems
            )
            Self.scheduleExpiryNotification(for: item, suggestions: suggestions)
        }
    }

    /// Schedules the three staged reminders for `item` with precomputed
    /// recipe suggestions. Reminders whose time has already passed are
    /// skipped. Safe to call from any thread: UNUserNotificationCenter is
    /// thread-safe and nothing here touches actor state.
    private nonisolated static func scheduleExpiryNotification(for item: StoredIngredient, suggestions: [[String: String]]) {
        cancelExpiryNotification(for: item)
        guard item.lifecycle == .fridge else { return }

        let calendar = Calendar.current
        let now = Date()
        let expiryText = DateFormatter.localizedString(from: item.expirationDate, dateStyle: .medium, timeStyle: .none)
        let emoji = FoodEmoji.emoji(for: item.name)
        let quantityText = [item.quantity, item.unit]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let photoURL = notificationPhotoURL(for: item)
        defer {
            if let photoURL { try? FileManager.default.removeItem(at: photoURL) }
        }

        let useItUp = useItUpLine(from: suggestions)
        let name = item.name.localizedCapitalized

        for stage in ExpiryStage.allCases {
            guard let day = calendar.date(byAdding: .day, value: stage.dayOffset, to: calendar.startOfDay(for: item.expirationDate)),
                  let fireDate = calendar.date(bySettingHour: expiryReminderHour, minute: 0, second: 0, of: day),
                  fireDate > now.addingTimeInterval(60) else { continue }

            let content = UNMutableNotificationContent()
            let lead: String
            switch stage {
            case .soon:
                content.title = "\(emoji) \(name) expires tomorrow"
                lead = "Use it in the next day or two."
            case .today:
                content.title = "\(emoji) \(name) expires today"
                lead = "Last day — cook it tonight or freeze it."
            case .expired:
                content.title = "\(emoji) \(name) expired yesterday"
                lead = "Give it a look and a sniff before you cook with it."
            }
            if let useItUp {
                content.subtitle = "\(suggestions.count) recipe\(suggestions.count == 1 ? "" : "s") use it"
                content.body = "\(lead) \(useItUp)"
            } else {
                content.body = lead
            }
            content.sound = .default
            content.categoryIdentifier = "EXPIRY_REMINDER"
            content.threadIdentifier = "expiry"
            content.userInfo = [
                "name": item.name,
                "expiry": item.expirationDate.timeIntervalSince1970,
                ExpiryNotificationKeys.itemID: item.id.uuidString,
                ExpiryNotificationKeys.itemEmoji: emoji,
                ExpiryNotificationKeys.expiryText: expiryText,
                ExpiryNotificationKeys.expiringItems: [item.name],
                ExpiryNotificationKeys.suggestedRecipes: suggestions,
                ExpiryNotificationKeys.quantityText: quantityText,
                ExpiryNotificationKeys.stage: stage.rawValue
            ]
            // "Tomorrow" can wait for the next unlock; today/expired should break through.
            content.interruptionLevel = stage == .soon ? .active : .timeSensitive
            content.relevanceScore = stage == .expired ? 1.0 : 0.9

            // The item's own photo on the banner and the expanded card. Adding
            // a request moves the attachment file, so each stage gets a copy.
            if let photoURL,
               let copy = duplicateTemporaryFile(photoURL),
               let attachment = try? UNNotificationAttachment(identifier: "itemPhoto", url: copy, options: nil) {
                content.attachments = [attachment]
            }

            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let id = notificationIdentifier(for: item, stage: stage)
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger)) { error in
                if let error {
                    print("[NOTIFY ERROR] \(item.name) (\(stage.rawValue)): \(error.localizedDescription)")
                } else {
                    print("[NOTIFY] Scheduled \(id) for \(fireDate)")
                }
            }
        }
    }

    /// The item's first user photo as a small JPEG in the temp directory, for
    /// the notification thumbnail. Content extensions run under a tight
    /// memory cap, so it's kept to ~300 px.
    private nonisolated static func notificationPhotoURL(for item: StoredIngredient) -> URL? {
        guard let data = item.userPhotoData.first,
              let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height, 1)
        let scale = min(1, 300 / longest)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let thumbnail = image.preparingThumbnail(of: size) ?? image
        guard let jpeg = thumbnail.jpegData(compressionQuality: 0.8) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("expiry-\(item.id.uuidString).jpg")
        do {
            try jpeg.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private nonisolated static func duplicateTemporaryFile(_ url: URL) -> URL? {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            return nil
        }
    }

    /// The in-flight full rebuild. A newer request cancels it, so a burst of
    /// store merges during a CloudKit import collapses into a single pass.
    private var expiryRefreshTask: Task<Void, Never>?

    /// Rebuilds every expiry reminder from the current fridge.
    ///
    /// This used to match every fridge item against the whole recipe library
    /// and make four notification-centre calls per item, all on the main
    /// actor, and it ran on every remote store merge. With a few dozen items
    /// that was seconds of blocked UI on each sync and tab switch. It now
    /// snapshots the fridge, waits briefly so bursts coalesce, and does all
    /// of the work on a background task.
    func refreshExpiryNotifications() {
        expiryRefreshTask?.cancel()

        let items = storedIngredients
        let fridgeIndex = fridgeMatchIndex
        let fridgeItems = matchableFridgeItems

        expiryRefreshTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }

            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            guard !Task.isCancelled else { return }
            let ourIDs = pending.map(\.identifier).filter { $0.hasPrefix("EXPIRY_") }
            center.removePendingNotificationRequests(withIdentifiers: ourIDs)

            let recipes = Self.cachedRecipesForSuggestions()
            for item in items {
                guard !Task.isCancelled else { return }
                let suggestions = Self.expirySuggestions(
                    for: item,
                    from: recipes,
                    fridgeIndex: fridgeIndex,
                    fridgeItems: fridgeItems
                )
                Self.scheduleExpiryNotification(for: item, suggestions: suggestions)
            }
        }
    }

    // MARK: - File IO Helpers

    private func saveItems(_ items: [String], to fileName: String) {
        let encoder = JSONEncoder()
        do {
            let data = try encoder.encode(items)
            let fileURL = getDocumentsDirectory().appendingPathComponent(fileName)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            print("[ERROR] Failed to save \(fileName): \(error.localizedDescription)")
        }
    }

    private func loadItems(from fileName: String) -> [String]? {
        let fileURL = getDocumentsDirectory().appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            print("[ERROR] Failed to load \(fileName): \(error.localizedDescription)")
            return nil
        }
    }

    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // MARK: - Deletion helpers for "Mine" fridge (used by FrydgeView)
    //
    // All three simply remove from the array and persist. `writeThroughToStore()`
    // reconciles by absence and soft-deletes the row, which replicates to every
    // device. No tombstones, no CKRecord deletes, no network dependency —
    // deleting while offline now works and stays deleted.

    func deleteItem(_ item: StoredIngredient) async {
        Self.cancelExpiryNotification(for: item)
        storedIngredients.removeAll { $0.id == item.id }
        saveStoredIngredientsToFile()
        refreshExpiryNotifications()
    }

    func deleteSelected(items: Set<UUID>) async {
        guard !items.isEmpty else { return }

        for item in storedIngredients where items.contains(item.id) {
            Self.cancelExpiryNotification(for: item)
        }

        storedIngredients.removeAll { items.contains($0.id) }
        saveStoredIngredientsToFile()
        refreshExpiryNotifications()
    }

    func clearAll() async {
        guard !storedIngredients.isEmpty else { return }

        storedIngredients.forEach { Self.cancelExpiryNotification(for: $0) }
        storedIngredients.removeAll()
        saveStoredIngredientsToFile()
        refreshExpiryNotifications()
    }

    // MARK: - Usage tracking

    func updateIngredientUsage(_ id: UUID, quantityUsed: Double) async {
        guard let index = storedIngredients.firstIndex(where: { $0.id == id }) else { return }
        storedIngredients[index].quantityUsed = max(0, min(100, quantityUsed))
        saveStoredIngredientsToFile()
    }
}
