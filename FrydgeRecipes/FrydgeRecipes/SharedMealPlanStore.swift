//
//  SharedMealPlanStore.swift
//  FrydgeRecipes
//
//  A household meal plan that lives inside a shared frydge's CloudKit zone, so
//  everyone who shares the frydge sees the same week and gets told when it
//  changes.
//
//  Record types (all parented to the frydge's ShareAnchor so they ride along
//  with the existing CKShare and zone subscriptions):
//    - "PlannedMeal"      one recipe (or a leftover from the frydge) on one
//                         day of the week
//    - "HouseholdStaple"  a recurring restock item (bin liners, dish soap…)
//                         the whole household shares; record name is the
//                         staple's UUID so edits are idempotent
//    - "MealPlanNotice"   a human-readable message posted when someone updates
//                         the plan; other members turn it into a local
//                         notification the next time their app wakes up.
//
//  Participants' devices are already woken by the per-zone subscriptions
//  SharedFridgeManager installs. The owner's device gets extra silent query
//  subscriptions (see configureSharedFrydgeNotificationsIfNeeded) because the
//  owner's existing subscriptions only watch ShareAnchor and StoredIngredient.
//

import Foundation
import CloudKit
import Combine
import UserNotifications
import UIKit

// MARK: - Model

struct SharedPlannedMeal: Identifiable, Hashable {
    let recordID: CKRecord.ID
    let fridgeID: CKRecord.ID
    var dayIndex: Int
    var recipeID: String
    var recipeName: String
    var ingredients: [String]
    var dietaryTags: [String]
    var serves: String
    var addedBy: String
    var createdAt: Date

    var id: String { recordID.recordName }

    var dayName: String {
        guard (0..<PlannedRecipe.dayNames.count).contains(dayIndex) else { return "" }
        return PlannedRecipe.dayNames[dayIndex]
    }

    /// Leftovers planned straight from the shared frydge (no ingredients).
    var isLeftover: Bool { PlannedLeftover.isLeftover(recipeID: recipeID) }

    /// The shared frydge StoredIngredient record name a planned leftover points at.
    var leftoverItemID: String? { PlannedLeftover.itemID(from: recipeID) }

    init?(record: CKRecord) {
        guard record.recordType == SharedMealPlanStore.mealRecordType,
              let fridgeRef = record[SharedMealPlanStore.fridgeRefKey] as? CKRecord.Reference,
              let name = record["recipeName"] as? String else { return nil }
        self.recordID = record.recordID
        self.fridgeID = fridgeRef.recordID
        self.dayIndex = (record["dayIndex"] as? Int) ?? 0
        self.recipeID = (record["recipeID"] as? String) ?? ""
        self.recipeName = name
        self.ingredients = (record["ingredients"] as? [String]) ?? []
        self.dietaryTags = (record["dietaryTags"] as? [String]) ?? []
        self.serves = (record["serves"] as? String) ?? ""
        self.addedBy = (record["addedBy"] as? String) ?? ""
        self.createdAt = (record["createdAt"] as? Date) ?? record.creationDate ?? Date()
    }
}

// MARK: - Store

@MainActor
final class SharedMealPlanStore: ObservableObject {

    static let shared = SharedMealPlanStore()

    // Plain string constants: nonisolated so record-parsing code that runs off
    // the main actor (e.g. SharedPlannedMeal.init(record:)) can read them
    // without an actor hop. This becomes a hard error in Swift 6 mode.
    nonisolated static let mealRecordType = "PlannedMeal"
    nonisolated static let stapleRecordType = "HouseholdStaple"
    nonisolated static let noticeRecordType = "MealPlanNotice"
    /// Same linkage field StoredIngredient uses, so queries look alike.
    nonisolated static let fridgeRefKey = "fridge"
    nonisolated static let localNotificationPrefix = "frydge.mealplan."

    typealias Scope = SharedFridgeManager.ShareScope

    @Published private(set) var mealsByFridge: [CKRecord.ID: [SharedPlannedMeal]] = [:]
    @Published private(set) var staplesByFridge: [CKRecord.ID: [RecurringHouseholdItem]] = [:]
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
    private weak var fridgeManager: SharedFridgeManager?
    private var cancellables: Set<AnyCancellable> = []
    private var syncTask: Task<Void, Never>?

    private let defaults = UserDefaults.standard
    private let seenNoticesKey = "mealPlan.seenNoticeRecordNames"
    private let myNoticesKey = "mealPlan.myNoticeRecordNames"
    private let myUserRecordNameKey = "mealPlan.myUserRecordName"
    private let didInitialSyncKey = "mealPlan.didInitialNoticeSync"

    private init() {
        // Any shared frydge change (push or share acceptance) may carry plan
        // changes; re-sync and surface new notices.
        NotificationCenter.default.publisher(for: Notification.Name("SharedFrydgeChanged"))
            .sink { [weak self] _ in self?.scheduleSync() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.scheduleSync() }
            .store(in: &cancellables)
    }

    /// Lets the store reuse the app's live anchor list instead of re-querying.
    func attach(_ manager: SharedFridgeManager) {
        fridgeManager = manager
        scheduleSync()
    }

    // MARK: - Reading

    func meals(for fridgeID: CKRecord.ID) -> [SharedPlannedMeal] {
        mealsByFridge[fridgeID] ?? []
    }

    func meals(for fridgeID: CKRecord.ID, dayIndex: Int) -> [SharedPlannedMeal] {
        meals(for: fridgeID).filter { $0.dayIndex == dayIndex }
    }

    /// Shared frydge item record names of every leftover already on the plan.
    func plannedLeftoverItemIDs(for fridgeID: CKRecord.ID) -> Set<String> {
        Set(meals(for: fridgeID).compactMap(\.leftoverItemID))
    }

    func loadMeals(for anchor: CKRecord, scope: Scope) async {
        let db = database(for: scope)
        let ref = CKRecord.Reference(recordID: anchor.recordID, action: .none)
        let query = CKQuery(
            recordType: Self.mealRecordType,
            predicate: NSPredicate(format: "%K == %@", Self.fridgeRefKey, ref)
        )
        do {
            let (matches, _) = try await db.records(matching: query, inZoneWith: anchor.recordID.zoneID)
            let meals = matches
                .compactMap { try? $0.1.get() }
                .compactMap(SharedPlannedMeal.init(record:))
                .sorted { ($0.dayIndex, $0.createdAt) < ($1.dayIndex, $1.createdAt) }
            mealsByFridge[anchor.recordID] = meals
        } catch {
            // "Unknown record type" simply means nobody has planned anything yet.
            if !isUnknownTypeError(error) {
                errorMessage = "Couldn't load the shared meal plan: \(error.localizedDescription)"
            }
            if mealsByFridge[anchor.recordID] == nil { mealsByFridge[anchor.recordID] = [] }
        }
    }

    // MARK: - Writing meals

    func addMeal(_ recipe: CloudRecipe, dayIndex: Int, to anchor: CKRecord, scope: Scope, addedBy: String) async throws {
        try await saveMeal(
            recipeID: recipe.id,
            name: recipe.name,
            ingredients: recipe.ingredients,
            dietaryTags: recipe.dietaryTags,
            serves: recipe.serves,
            dayIndex: dayIndex,
            to: anchor,
            scope: scope,
            addedBy: addedBy
        )
    }

    /// Plan a night for leftovers already sitting in the shared frydge.
    func addLeftover(_ leftover: PlannableLeftover, dayIndex: Int, to anchor: CKRecord, scope: Scope, addedBy: String) async throws {
        try await saveMeal(
            recipeID: PlannedLeftover.recipeID(forItem: leftover.id),
            name: leftover.name,
            ingredients: [],
            dietaryTags: leftover.dietaryTags,
            serves: String(leftover.portions),
            dayIndex: dayIndex,
            to: anchor,
            scope: scope,
            addedBy: addedBy
        )
    }

    private func saveMeal(
        recipeID: String,
        name: String,
        ingredients: [String],
        dietaryTags: [String],
        serves: String,
        dayIndex: Int,
        to anchor: CKRecord,
        scope: Scope,
        addedBy: String
    ) async throws {
        let rec = Self.makeMealRecord(
            anchorID: anchor.recordID,
            recipeID: recipeID,
            name: name,
            ingredients: ingredients,
            dietaryTags: dietaryTags,
            serves: serves,
            dayIndex: dayIndex,
            addedBy: addedBy
        )

        let saved = try await database(for: scope).save(rec)
        if let meal = SharedPlannedMeal(record: saved) {
            var list = mealsByFridge[anchor.recordID] ?? []
            list.append(meal)
            list.sort { ($0.dayIndex, $0.createdAt) < ($1.dayIndex, $1.createdAt) }
            mealsByFridge[anchor.recordID] = list
        }
    }

    func removeMeal(_ meal: SharedPlannedMeal, scope: Scope) async {
        do {
            _ = try await database(for: scope).deleteRecord(withID: meal.recordID)
            mealsByFridge[meal.fridgeID]?.removeAll { $0.recordID == meal.recordID }
        } catch {
            errorMessage = "Couldn't remove \(meal.recipeName): \(error.localizedDescription)"
        }
    }

    func clearWeek(for anchor: CKRecord, scope: Scope) async {
        let ids = meals(for: anchor.recordID).map(\.recordID)
        guard !ids.isEmpty else { return }
        do {
            _ = try await database(for: scope).modifyRecords(saving: [], deleting: ids)
            mealsByFridge[anchor.recordID] = []
        } catch {
            errorMessage = "Couldn't clear the week: \(error.localizedDescription)"
        }
    }

    // MARK: - Household staples (shared recurring restock)

    func staples(for fridgeID: CKRecord.ID) -> [RecurringHouseholdItem] {
        staplesByFridge[fridgeID] ?? []
    }

    func dueStaples(for fridgeID: CKRecord.ID, on date: Date = Date()) -> [RecurringHouseholdItem] {
        staples(for: fridgeID).filter { $0.isDue(on: date) }
    }

    func loadStaples(for anchor: CKRecord, scope: Scope) async {
        let db = database(for: scope)
        let ref = CKRecord.Reference(recordID: anchor.recordID, action: .none)
        let query = CKQuery(
            recordType: Self.stapleRecordType,
            predicate: NSPredicate(format: "%K == %@", Self.fridgeRefKey, ref)
        )
        do {
            let (matches, _) = try await db.records(matching: query, inZoneWith: anchor.recordID.zoneID)
            let items = matches
                .compactMap { try? $0.1.get() }
                .map { (record: $0, item: Self.staple(from: $0)) }
                .sorted { $0.record.creationDate ?? .distantPast < $1.record.creationDate ?? .distantPast }
                .compactMap(\.item)
            staplesByFridge[anchor.recordID] = items
        } catch {
            if !isUnknownTypeError(error) {
                errorMessage = "Couldn't load household staples: \(error.localizedDescription)"
            }
            if staplesByFridge[anchor.recordID] == nil { staplesByFridge[anchor.recordID] = [] }
        }
    }

    /// Adds a staple, or updates the interval/amount of one with the same name
    /// (mirrors WeekPlanStore.addRecurring).
    func addStaple(name: String, quantity: String = "1", unit: String = "", interval: RestockInterval,
                   to anchor: CKRecord, scope: Scope) async {
        let clean = name
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        var item: RecurringHouseholdItem
        if let existing = staples(for: anchor.recordID).first(where: { $0.name.lowercased() == clean.lowercased() }) {
            item = existing
            item.interval = interval
            item.quantity = quantity
            item.unit = unit
        } else {
            item = RecurringHouseholdItem(name: clean, quantity: quantity, unit: unit, interval: interval)
        }
        await saveStaple(item, to: anchor, scope: scope)
    }

    func updateStapleInterval(id: UUID, interval: RestockInterval, for anchor: CKRecord, scope: Scope) async {
        guard var item = staples(for: anchor.recordID).first(where: { $0.id == id }) else { return }
        item.interval = interval
        await saveStaple(item, to: anchor, scope: scope)
    }

    func removeStaple(id: UUID, for anchor: CKRecord, scope: Scope) async {
        let recordID = Self.stapleRecordID(for: id, in: anchor.recordID.zoneID)
        do {
            _ = try await database(for: scope).deleteRecord(withID: recordID)
            staplesByFridge[anchor.recordID]?.removeAll { $0.id == id }
        } catch {
            errorMessage = "Couldn't remove that staple: \(error.localizedDescription)"
        }
    }

    /// Call after due staples were pushed to a shopping list so their next-due
    /// date rolls forward for everyone.
    func markStaplesAdded(ids: Set<UUID>, for anchor: CKRecord, scope: Scope, on date: Date = Date()) async {
        guard !ids.isEmpty else { return }
        for var item in staples(for: anchor.recordID) where ids.contains(item.id) {
            item.lastAddedToList = date
            await saveStaple(item, to: anchor, scope: scope)
        }
    }

    /// Upsert by deterministic record name. `.changedKeys` means two members
    /// editing the same staple don't trip over each other's change tags.
    private func saveStaple(_ item: RecurringHouseholdItem, to anchor: CKRecord, scope: Scope) async {
        let rec = Self.makeStapleRecord(item, anchorID: anchor.recordID)

        do {
            let (saveResults, _) = try await database(for: scope).modifyRecords(
                saving: [rec], deleting: [], savePolicy: .changedKeys, atomically: true
            )
            if let result = saveResults[rec.recordID] {
                _ = try result.get()
            }
            var list = staplesByFridge[anchor.recordID] ?? []
            if let idx = list.firstIndex(where: { $0.id == item.id }) {
                list[idx] = item
            } else {
                list.append(item)
            }
            staplesByFridge[anchor.recordID] = list
        } catch {
            errorMessage = "Couldn't save \(item.name): \(error.localizedDescription)"
        }
    }

    nonisolated private static func stapleRecordID(for itemID: UUID, in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: "staple-" + itemID.uuidString, zoneID: zoneID)
    }

    nonisolated private static func staple(from record: CKRecord) -> RecurringHouseholdItem? {
        guard let name = record["name"] as? String, !name.isEmpty else { return nil }
        let id = (record["itemID"] as? String).flatMap(UUID.init(uuidString:))
            ?? UUID(uuidString: record.recordID.recordName.replacingOccurrences(of: "staple-", with: ""))
            ?? UUID()
        return RecurringHouseholdItem(
            id: id,
            name: name,
            quantity: (record["quantity"] as? String) ?? "1",
            unit: (record["unit"] as? String) ?? "",
            interval: RestockInterval(rawValue: (record["interval"] as? String) ?? "") ?? .monthly,
            lastAddedToList: record["lastAddedToList"] as? Date
        )
    }

    // MARK: - Notices

    /// Posts a message everyone else sharing the frydge will see as a
    /// notification. The author's own device remembers the record so it never
    /// notifies itself.
    func postNotice(title: String, body: String, to anchor: CKRecord, scope: Scope, authorName: String) async throws {
        let rec = Self.makeNoticeRecord(
            anchorID: anchor.recordID,
            title: title,
            body: body,
            authorName: authorName,
            authorUserRecordName: await myUserRecordName()
        )

        rememberMyNotice(rec.recordID.recordName)
        _ = try await database(for: scope).save(rec)
    }

    // MARK: - Sync (meals + staples + notices for every frydge I'm in)

    private func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            // Let SharedFridgeManager finish its own reload first so the anchor
            // list is fresh.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.syncAll()
        }
    }

    /// Reloads every frydge's plan and turns unseen notices from other members
    /// into local notifications. Safe to call repeatedly.
    func syncAll() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let anchors = await resolveAnchors()
        guard !anchors.isEmpty else { return }

        for (anchor, scope) in anchors {
            await loadMeals(for: anchor, scope: scope)
            await loadStaples(for: anchor, scope: scope)
            await processNotices(for: anchor, scope: scope)
        }
    }

    /// Called from the push handler so the background wake-up actually waits
    /// for the fetch before the system suspends the app again.
    func handleRemotePush() async {
        await syncAll()
    }

    private func resolveAnchors() async -> [(CKRecord, Scope)] {
        if let manager = fridgeManager, !manager.sharedFrydgeAnchors.isEmpty {
            return manager.owned.map { ($0, Scope.owned) } + manager.incoming.map { ($0, Scope.incoming) }
        }
        // Background launch or the manager hasn't loaded yet: discover directly.
        return await discoverAnchors()
    }

    private func discoverAnchors() async -> [(CKRecord, Scope)] {
        var out: [(CKRecord, Scope)] = []
        let pred = NSPredicate(format: "category == %@", "Fridge")

        // Owned (only anchors that are actually shared matter here).
        let ownedZone = CKRecordZone.ID(zoneName: "FrydgeFridgeZone", ownerName: CKCurrentUserDefaultName)
        if let (matches, _) = try? await container.privateCloudDatabase.records(
            matching: CKQuery(recordType: "ShareAnchor", predicate: pred), inZoneWith: ownedZone
        ) {
            for rec in matches.compactMap({ try? $0.1.get() }) where rec.share != nil {
                out.append((rec, .owned))
            }
        }

        // Incoming: one shared zone per accepted share.
        let sharedDB = container.sharedCloudDatabase
        if let zones = try? await sharedDB.allRecordZones() {
            for zone in zones {
                if let (matches, _) = try? await sharedDB.records(
                    matching: CKQuery(recordType: "ShareAnchor", predicate: pred), inZoneWith: zone.zoneID
                ) {
                    for rec in matches.compactMap({ try? $0.1.get() }) {
                        out.append((rec, .incoming))
                    }
                }
            }
        }
        return out
    }

    // MARK: - Notices → local notifications

    private func processNotices(for anchor: CKRecord, scope: Scope) async {
        let db = database(for: scope)
        let ref = CKRecord.Reference(recordID: anchor.recordID, action: .none)
        let query = CKQuery(
            recordType: Self.noticeRecordType,
            predicate: NSPredicate(format: "%K == %@", Self.fridgeRefKey, ref)
        )
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        let records: [CKRecord]
        do {
            let (matches, _) = try await db.records(matching: query, inZoneWith: anchor.recordID.zoneID, resultsLimit: 20)
            records = matches.compactMap { try? $0.1.get() }
        } catch {
            return // best-effort; unknown type just means no notices yet
        }

        var seen = Set(defaults.stringArray(forKey: seenNoticesKey) ?? [])
        let mine = Set(defaults.stringArray(forKey: myNoticesKey) ?? [])
        let me = await myUserRecordName()
        let firstSync = !defaults.bool(forKey: didInitialSyncKey)
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let fridgeName = (anchor["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        for rec in records {
            let name = rec.recordID.recordName
            guard !seen.contains(name) else { continue }
            seen.insert(name)

            // Never notify about my own posts.
            if mine.contains(name) { continue }
            if let me, let author = rec["authorUserRecordName"] as? String, author == me { continue }

            // Don't replay history the first time this device syncs, and skip
            // anything stale.
            let created = (rec["createdAt"] as? Date) ?? rec.creationDate ?? .distantPast
            if firstSync || created < cutoff { continue }

            let title = (rec["title"] as? String) ?? "\(fridgeName ?? "Shared frydge") meal plan updated"
            let body = (rec["body"] as? String) ?? ""
            postLocalNotification(id: name, title: title, body: body, thread: anchor.recordID.recordName)
        }

        // Keep the seen set bounded.
        defaults.set(Array(seen.suffix(500)), forKey: seenNoticesKey)
        defaults.set(true, forKey: didInitialSyncKey)
    }

    private func postLocalNotification(id: String, title: String, body: String, thread: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "mealplan." + thread
        content.categoryIdentifier = SharedFridgeManager.sharedFrydgeUpdatedCategory

        let request = UNNotificationRequest(
            identifier: Self.localNotificationPrefix + id,
            content: content,
            trigger: nil // deliver now
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("[MealPlan] local notification failed:", error.localizedDescription) }
        }
    }

    // MARK: - Record builders
    //
    // Every field the app ever writes for a record type lives here, so the
    // writers above and the DEBUG schema seed below can't drift apart. CloudKit
    // only creates a field the first time it's saved with a value, so anything
    // added here must also be set in seedDevelopmentSchemaIfNeeded.

    nonisolated private static func makeMealRecord(
        anchorID: CKRecord.ID,
        recipeID: String,
        name: String,
        ingredients: [String],
        dietaryTags: [String],
        serves: String,
        dayIndex: Int,
        addedBy: String
    ) -> CKRecord {
        let rec = CKRecord(
            recordType: mealRecordType,
            recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: anchorID.zoneID)
        )
        rec.parent = CKRecord.Reference(recordID: anchorID, action: .none)
        rec[fridgeRefKey] = CKRecord.Reference(recordID: anchorID, action: .deleteSelf)
        rec["dayIndex"] = dayIndex as CKRecordValue
        rec["recipeID"] = recipeID as CKRecordValue
        rec["recipeName"] = name as CKRecordValue
        rec["ingredients"] = ingredients as CKRecordValue
        rec["dietaryTags"] = dietaryTags as CKRecordValue
        rec["serves"] = serves as CKRecordValue
        rec["addedBy"] = addedBy as CKRecordValue
        rec["createdAt"] = Date() as CKRecordValue
        return rec
    }

    nonisolated private static func makeStapleRecord(_ item: RecurringHouseholdItem, anchorID: CKRecord.ID) -> CKRecord {
        let rec = CKRecord(recordType: stapleRecordType, recordID: stapleRecordID(for: item.id, in: anchorID.zoneID))
        rec.parent = CKRecord.Reference(recordID: anchorID, action: .none)
        rec[fridgeRefKey] = CKRecord.Reference(recordID: anchorID, action: .deleteSelf)
        rec["itemID"] = item.id.uuidString as CKRecordValue
        rec["name"] = item.name as CKRecordValue
        rec["quantity"] = item.quantity as CKRecordValue
        rec["unit"] = item.unit as CKRecordValue
        rec["interval"] = item.interval.rawValue as CKRecordValue
        rec["lastAddedToList"] = item.lastAddedToList as CKRecordValue?
        rec["createdAt"] = Date() as CKRecordValue
        return rec
    }

    nonisolated private static func makeNoticeRecord(
        anchorID: CKRecord.ID,
        title: String,
        body: String,
        authorName: String,
        authorUserRecordName: String?
    ) -> CKRecord {
        let rec = CKRecord(
            recordType: noticeRecordType,
            recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: anchorID.zoneID)
        )
        rec.parent = CKRecord.Reference(recordID: anchorID, action: .none)
        rec[fridgeRefKey] = CKRecord.Reference(recordID: anchorID, action: .deleteSelf)
        rec["title"] = title as CKRecordValue
        rec["body"] = body as CKRecordValue
        rec["authorName"] = authorName as CKRecordValue
        rec["createdAt"] = Date() as CKRecordValue
        if let authorUserRecordName {
            rec["authorUserRecordName"] = authorUserRecordName as CKRecordValue
        }
        return rec
    }

    // MARK: - Helpers

    private func database(for scope: Scope) -> CKDatabase {
        scope == .owned ? container.privateCloudDatabase : container.sharedCloudDatabase
    }

    private func rememberMyNotice(_ recordName: String) {
        var mine = defaults.stringArray(forKey: myNoticesKey) ?? []
        mine.append(recordName)
        defaults.set(Array(mine.suffix(200)), forKey: myNoticesKey)
    }

    private func myUserRecordName() async -> String? {
        if let cached = defaults.string(forKey: myUserRecordNameKey) { return cached }
        guard let id = try? await container.userRecordID() else { return nil }
        defaults.set(id.recordName, forKey: myUserRecordNameKey)
        return id.recordName
    }

    private func isUnknownTypeError(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return false }
        // CloudKit reports a never-before-saved record type as .unknownItem in
        // development, or .invalidArguments ("Unknown record type") in production.
        return ck.code == .unknownItem || ck.code == .invalidArguments
    }
}

#if DEBUG
// MARK: - Development schema seed

extension SharedMealPlanStore {

    /// Bump when a builder above gains a field, so the next debug launch
    /// re-seeds and the new field appears in the Development schema.
    nonisolated private static let devSchemaSeedVersion = 1
    private var devSchemaSeedKey: String { "mealPlan.devSchemaSeedVersion" }

    /// Debug builds talk to CloudKit's Development environment, where a record
    /// type and its fields are created the first time a record carrying them
    /// is saved. Rather than relying on someone exercising every UI path (and
    /// remembering that `lastAddedToList` and `authorUserRecordName` are only
    /// written on some of them), this saves one fully populated PlannedMeal,
    /// HouseholdStaple and MealPlanNotice, runs the app's own queries against
    /// them to prove the `fridge` / `createdAt` indexes exist, then deletes
    /// them again.
    ///
    /// Records go in the owner's private, unshared zone and point at a
    /// synthetic anchor, so no household member's device is woken or notified
    /// and the real plan never sees them. Runs once per install, and only once
    /// the save and all three queries succeed. Not compiled into release.
    func seedDevelopmentSchemaIfNeeded() async {
        guard defaults.integer(forKey: devSchemaSeedKey) < Self.devSchemaSeedVersion else { return }

        let db = container.privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: "FrydgeFridgeZone", ownerName: CKCurrentUserDefaultName)
        // CloudKit doesn't require a reference's target to exist; the schema
        // only cares that the field is a Reference.
        let anchorID = CKRecord.ID(recordName: "schema-seed-anchor", zoneID: zoneID)
        let anchorRef = CKRecord.Reference(recordID: anchorID, action: .none)

        let meal = Self.makeMealRecord(
            anchorID: anchorID,
            recipeID: "schema-seed",
            name: "Schema seed meal",
            ingredients: ["1 cup seed"],
            dietaryTags: ["Vegetarian"],
            serves: "2",
            dayIndex: 0,
            addedBy: "Schema seed"
        )
        let staple = Self.makeStapleRecord(
            RecurringHouseholdItem(name: "Schema seed staple", quantity: "1", unit: "pack",
                                   interval: .monthly, lastAddedToList: Date()),
            anchorID: anchorID
        )
        let notice = Self.makeNoticeRecord(
            anchorID: anchorID,
            title: "Schema seed",
            body: "Temporary record used to create the CloudKit schema; deleted immediately.",
            authorName: "Schema seed",
            authorUserRecordName: await myUserRecordName() ?? "schema-seed-user"
        )
        let records = [meal, staple, notice]
        // `parent` is a system field that doesn't affect the schema, and the
        // synthetic anchor doesn't exist, so don't claim it as a parent.
        for rec in records { rec.parent = nil }

        // The zone normally exists already (SharedFridgeManager.ensureZone);
        // saving it again is a harmless upsert on a fresh install.
        _ = try? await db.save(CKRecordZone(zoneID: zoneID))

        do {
            let (saveResults, _) = try await db.modifyRecords(
                saving: records, deleting: [], savePolicy: .changedKeys, atomically: true
            )
            for result in saveResults.values { _ = try result.get() }
            print("[SchemaSeed] ✅ Saved PlannedMeal, HouseholdStaple and MealPlanNotice to Development")
        } catch {
            print("[SchemaSeed] ❌ Save failed, schema not created: \(error.localizedDescription)")
            return
        }

        // Same queries the store runs for real anchors. A failure here means
        // the Development schema is missing an index the app depends on:
        // QUERYABLE on `fridge` for every type, SORTABLE on `createdAt` for notices.
        var allQueriesOK = true
        for type in [Self.mealRecordType, Self.stapleRecordType, Self.noticeRecordType] {
            let query = CKQuery(recordType: type, predicate: NSPredicate(format: "%K == %@", Self.fridgeRefKey, anchorRef))
            if type == Self.noticeRecordType {
                query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            }
            do {
                // Count is informational only: freshly saved records can lag
                // the query index by a few seconds. No error = index exists.
                let (matches, _) = try await db.records(matching: query, inZoneWith: zoneID)
                print("[SchemaSeed] ✅ \(type) query OK (\(matches.count) matched)")
            } catch {
                allQueriesOK = false
                print("[SchemaSeed] ❌ \(type) query failed: \(error.localizedDescription)")
            }
        }

        do {
            _ = try await db.modifyRecords(saving: [], deleting: records.map(\.recordID))
            print("[SchemaSeed] 🧹 Seed records deleted")
        } catch {
            print("[SchemaSeed] ⚠️ Couldn't delete seed records (\(error.localizedDescription)); remove them in CloudKit Dashboard → Development → FrydgeFridgeZone")
        }

        if allQueriesOK {
            defaults.set(Self.devSchemaSeedVersion, forKey: devSchemaSeedKey)
            print("[SchemaSeed] Done. Check CloudKit Dashboard → Development → Record Types, then Deploy Schema Changes to Production.")
        } else {
            print("[SchemaSeed] Add the missing indexes in CloudKit Dashboard (Development), then relaunch to re-verify.")
        }
    }
}
#endif
