//
//  WeekPlanStore.swift
//  FrydgeRecipes
//
//  Weekly meal planning + recurring household restock.
//
//  Holds two lists:
//  - Planned recipes: recipes assigned to days of the week, so a whole week of
//    cooking can be expanded into the shopping list in one go.
//  - Recurring household items: staples like dishwashing liquid or bin liners
//    that need replacing every few weeks/months. Each remembers when it was
//    last pushed to the shopping list and reports when it is due again.
//
//  SOURCE OF TRUTH IS CORE DATA, synced across devices by
//  NSPersistentCloudKitContainer via PersistenceController — the same pattern
//  as ShoppingListManager. The App Group UserDefaults JSON is kept as a
//  rollback backup and as the one-time seed for plans created before the
//  Core Data cutover.
//

import Foundation
import SwiftUI
import Combine
import CoreData

// MARK: - Planned recipe

/// A recipe assigned to a day of the week (0 = Monday … 6 = Sunday).
struct PlannedRecipe: Identifiable, Codable, Hashable {
    var id: UUID
    var dayIndex: Int
    var recipeID: String
    var recipeName: String
    /// Snapshot of the recipe's ingredient lines at planning time, so the plan
    /// still works offline and survives the recipe being edited or deleted.
    var ingredients: [String]
    var dietaryTags: [String]
    var serves: String

    init(id: UUID = UUID(), dayIndex: Int, recipe: CloudRecipe) {
        self.id = id
        self.dayIndex = dayIndex
        self.recipeID = recipe.id
        self.recipeName = recipe.name
        self.ingredients = recipe.ingredients
        self.dietaryTags = recipe.dietaryTags
        self.serves = recipe.serves
    }

    init(
        id: UUID,
        dayIndex: Int,
        recipeID: String,
        recipeName: String,
        ingredients: [String],
        dietaryTags: [String],
        serves: String
    ) {
        self.id = id
        self.dayIndex = dayIndex
        self.recipeID = recipeID
        self.recipeName = recipeName
        self.ingredients = ingredients
        self.dietaryTags = dietaryTags
        self.serves = serves
    }

    /// Leftovers from the frydge planned as a meal. No ingredients, so the
    /// shopping, pricing and defrost logic all naturally skip it.
    init(id: UUID = UUID(), dayIndex: Int, leftover: PlannableLeftover) {
        self.id = id
        self.dayIndex = dayIndex
        self.recipeID = PlannedLeftover.recipeID(forItem: leftover.id)
        self.recipeName = leftover.name
        self.ingredients = []
        self.dietaryTags = leftover.dietaryTags
        self.serves = String(leftover.portions)
    }

    static let dayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    var dayName: String {
        guard (0..<Self.dayNames.count).contains(dayIndex) else { return "" }
        return Self.dayNames[dayIndex]
    }

    var isLeftover: Bool { PlannedLeftover.isLeftover(recipeID: recipeID) }

    /// The frydge item (StoredIngredient UUID string) a planned leftover points at.
    var leftoverItemID: String? { PlannedLeftover.itemID(from: recipeID) }
}

// MARK: - Recurring household items

/// How often a household staple needs replacing.
enum RestockInterval: String, Codable, CaseIterable, Identifiable {
    case weekly
    case fortnightly
    case monthly
    case twoMonths
    case threeMonths
    case sixMonths

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .weekly:      return "Weekly"
        case .fortnightly: return "Fortnightly"
        case .monthly:     return "Monthly"
        case .twoMonths:   return "Every 2 months"
        case .threeMonths: return "Every 3 months"
        case .sixMonths:   return "Every 6 months"
        }
    }

    var days: Int {
        switch self {
        case .weekly:      return 7
        case .fortnightly: return 14
        case .monthly:     return 30
        case .twoMonths:   return 61
        case .threeMonths: return 91
        case .sixMonths:   return 182
        }
    }
}

/// A staple (cleaning product, foil, bin liners…) that is re-added to the
/// shopping list every `interval`.
struct RecurringHouseholdItem: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var quantity: String
    var unit: String
    var interval: RestockInterval
    /// When it was last pushed to the shopping list. nil = never, i.e. due now.
    var lastAddedToList: Date?

    init(
        id: UUID = UUID(),
        name: String,
        quantity: String = "1",
        unit: String = "",
        interval: RestockInterval = .monthly,
        lastAddedToList: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.interval = interval
        self.lastAddedToList = lastAddedToList
    }

    var nextDueDate: Date? {
        guard let last = lastAddedToList else { return nil }
        return Calendar.current.date(byAdding: .day, value: interval.days, to: last)
    }

    func isDue(on date: Date = Date()) -> Bool {
        guard let next = nextDueDate else { return true }
        return next <= date
    }

    /// Short human label for the row, e.g. "Due now" or "Due in 12d".
    func dueLabel(on date: Date = Date()) -> String {
        guard let next = nextDueDate else { return "Due now" }
        let days = Calendar.current.dateComponents([.day], from: date, to: next).day ?? 0
        if days <= 0 { return "Due now" }
        return "Due in \(days)d"
    }
}

// MARK: - Store

@MainActor
final class WeekPlanStore: ObservableObject {

    /// Single shared instance: the planner is reachable from both the fridge
    /// and shopping list tabs, and both must see the same plan.
    static let shared = WeekPlanStore()

    @Published private(set) var plannedRecipes: [PlannedRecipe] = []
    @Published private(set) var recurringItems: [RecurringHouseholdItem] = []

    private let appGroupName = "group.Clark-Online.FrydgeRecipeAPN"
    private let plannedKey = "weekPlan_plannedRecipes_v1"
    private let recurringKey = "weekPlan_recurringItems_v1"

    private var cancellables: Set<AnyCancellable> = []

    private var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupName) ?? .standard
    }

    private var storeContext: NSManagedObjectContext {
        PersistenceController.shared.container.viewContext
    }

    private var coreDataAvailable: Bool {
        !PersistenceController.shared.isDegraded
    }

    init() {
        loadFromStore()
        startObservingRemoteChanges()
    }

    /// iCloud account switched while installed: re-read the plan from the
    /// store rather than keep showing the previous account's week.
    func handleAccountChange() {
        loadFromStore()
    }

    // MARK: Planned recipes

    func recipes(for dayIndex: Int) -> [PlannedRecipe] {
        plannedRecipes.filter { $0.dayIndex == dayIndex }
    }

    func addRecipe(_ recipe: CloudRecipe, to dayIndex: Int) {
        plannedRecipes.append(PlannedRecipe(dayIndex: dayIndex, recipe: recipe))
        save()
    }

    /// Plan a night for leftovers already in the frydge.
    func addLeftover(_ leftover: PlannableLeftover, to dayIndex: Int) {
        plannedRecipes.append(PlannedRecipe(dayIndex: dayIndex, leftover: leftover))
        save()
    }

    /// Frydge item IDs of every leftover already on the plan.
    var plannedLeftoverItemIDs: Set<String> {
        Set(plannedRecipes.compactMap(\.leftoverItemID))
    }

    func removePlanned(id: UUID) {
        plannedRecipes.removeAll { $0.id == id }
        save()
    }

    func clearWeek() {
        plannedRecipes.removeAll()
        save()
    }

    // MARK: Recurring items

    func addRecurring(name: String, quantity: String = "1", unit: String = "", interval: RestockInterval) {
        let clean = name
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        // Update in place if the same staple already exists.
        if let idx = recurringItems.firstIndex(where: { $0.name.lowercased() == clean.lowercased() }) {
            recurringItems[idx].interval = interval
            recurringItems[idx].quantity = quantity
            recurringItems[idx].unit = unit
        } else {
            recurringItems.append(RecurringHouseholdItem(name: clean, quantity: quantity, unit: unit, interval: interval))
        }
        save()
    }

    func updateInterval(id: UUID, interval: RestockInterval) {
        guard let idx = recurringItems.firstIndex(where: { $0.id == id }) else { return }
        recurringItems[idx].interval = interval
        save()
    }

    func removeRecurring(id: UUID) {
        recurringItems.removeAll { $0.id == id }
        save()
    }

    func dueRecurringItems(on date: Date = Date()) -> [RecurringHouseholdItem] {
        recurringItems.filter { $0.isDue(on: date) }
    }

    /// Call after due items were pushed to the shopping list so their next-due
    /// date rolls forward.
    func markAddedToList(ids: Set<UUID>, on date: Date = Date()) {
        guard !ids.isEmpty else { return }
        for idx in recurringItems.indices where ids.contains(recurringItems[idx].id) {
            recurringItems[idx].lastAddedToList = date
        }
        save()
    }

    // MARK: Persistence

    private func save() {
        writeThroughToStore()
        writeBackupJSON()
        DefrostReminderPlanner.refresh()
    }

    /// Core Data wins. The UserDefaults JSON is consulted only when the store
    /// has no plan rows — the first launch after the CloudKit cutover, when the
    /// plan only exists in the old local-only format.
    /// Set once the Core Data store has been confirmed as the source of truth.
    /// After that an empty fetch means "no plan" and the UserDefaults backup is
    /// never used to reseed it.
    private let seedCompletedKey = "coreDataSeedCompleted.weekPlan"

    private var seedCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: seedCompletedKey) }
        set { UserDefaults.standard.set(newValue, forKey: seedCompletedKey) }
    }

    /// IDs present the last time each array was loaded from, or persisted to,
    /// the store. Deletions are derived from these snapshots, never from the
    /// store's current contents, so a row that synced in before the array
    /// refreshed cannot be soft-deleted by a save of the stale array.
    private var lastPersistedPlanIDs: Set<UUID> = []
    private var lastPersistedRecurringIDs: Set<UUID> = []

    private func loadFromStore() {
        if coreDataAvailable {
            do {
                let planRows = try storeContext.fetch(CDPlannedRecipe.fetchRequestForActiveItems())
                let recurringRows = try storeContext.fetch(CDRecurringItem.fetchRequestForActiveItems())
                if !planRows.isEmpty || !recurringRows.isEmpty {
                    plannedRecipes = planRows.map { $0.toPlannedRecipe() }
                    recurringItems = recurringRows.map { $0.toRecurringItem() }
                    snapshotPersistedIDs()
                    seedCompleted = true
                    return
                }
                if seedCompleted {
                    // Genuinely empty. Do not resurrect the backup.
                    plannedRecipes = []
                    recurringItems = []
                    snapshotPersistedIDs()
                    return
                }
            } catch {
                print("[STORE ERROR] week plan initial fetch failed: \(error.localizedDescription)")
                return
            }
        }
        seedFromBackupJSON()
    }

    private func snapshotPersistedIDs() {
        lastPersistedPlanIDs = Set(plannedRecipes.map(\.id))
        lastPersistedRecurringIDs = Set(recurringItems.map(\.id))
    }

    /// One-way upgrade path: read the pre-CloudKit local JSON and push it into
    /// Core Data so it starts syncing. Marked complete only after the store
    /// accepted the rows.
    private func seedFromBackupJSON() {
        var seeded = false
        if let data = defaults.data(forKey: plannedKey),
           let decoded = try? JSONDecoder().decode([PlannedRecipe].self, from: data), !decoded.isEmpty {
            plannedRecipes = decoded
            seeded = true
        }
        if let data = defaults.data(forKey: recurringKey),
           let decoded = try? JSONDecoder().decode([RecurringHouseholdItem].self, from: data), !decoded.isEmpty {
            recurringItems = decoded
            seeded = true
        }
        guard seeded else {
            if coreDataAvailable { seedCompleted = true }
            return
        }
        lastPersistedPlanIDs = []
        lastPersistedRecurringIDs = []
        guard writeThroughToStore() else { return }
        seedCompleted = true
        print("[MIGRATE] Seeded week plan (\(plannedRecipes.count) recipes, \(recurringItems.count) staples) into Core Data.")
    }

    /// Rollback backup + degraded-store fallback only.
    private func writeBackupJSON() {
        if let data = try? JSONEncoder().encode(plannedRecipes) {
            defaults.set(data, forKey: plannedKey)
        }
        if let data = try? JSONEncoder().encode(recurringItems) {
            defaults.set(data, forKey: recurringKey)
        }
    }

    /// Pushes the in-memory arrays into Core Data.
    ///
    /// Upserts present rows and soft-deletes only IDs that were in the last
    /// persisted snapshot and are now absent. Rows another device already
    /// soft-deleted stay deleted when the local array still holds them from
    /// before the deletion synced; IDs new to this device are restored.
    @discardableResult
    private func writeThroughToStore() -> Bool {
        guard coreDataAvailable else { return false }
        let ctx = storeContext
        do {
            let presentPlans = Set(plannedRecipes.map(\.id))
            var planSurvivors = presentPlans
            for plan in plannedRecipes {
                let row = try ctx.upsertPlannedRecipe(id: plan.id)
                if row.deletedAt != nil {
                    if lastPersistedPlanIDs.contains(plan.id) {
                        planSurvivors.remove(plan.id)  // synced deletion wins
                        continue
                    }
                    row.deletedAt = nil  // explicit re-add
                }
                row.apply(plan)
            }
            let removedPlans = lastPersistedPlanIDs.subtracting(presentPlans)
            if !removedPlans.isEmpty {
                for row in try ctx.fetch(CDPlannedRecipe.fetchRequestForActiveItems()) {
                    guard let id = row.id, removedPlans.contains(id) else { continue }
                    row.softDelete()
                }
            }

            let presentRecurring = Set(recurringItems.map(\.id))
            var recurringSurvivors = presentRecurring
            for item in recurringItems {
                let row = try ctx.upsertRecurringItem(id: item.id)
                if row.deletedAt != nil {
                    if lastPersistedRecurringIDs.contains(item.id) {
                        recurringSurvivors.remove(item.id)
                        continue
                    }
                    row.deletedAt = nil
                }
                row.apply(item)
            }
            let removedRecurring = lastPersistedRecurringIDs.subtracting(presentRecurring)
            if !removedRecurring.isEmpty {
                for row in try ctx.fetch(CDRecurringItem.fetchRequestForActiveItems()) {
                    guard let id = row.id, removedRecurring.contains(id) else { continue }
                    row.softDelete()
                }
            }

            guard PersistenceController.shared.saveIfNeeded(ctx) else { return false }
            lastPersistedPlanIDs = planSurvivors
            lastPersistedRecurringIDs = recurringSurvivors
            return true
        } catch {
            print("[STORE ERROR] week plan write-through failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Rebuilds the published arrays from Core Data after a CloudKit pull lands.
    func reloadFromStore() {
        guard coreDataAvailable else { return }
        do {
            let planRows = try storeContext.fetch(CDPlannedRecipe.fetchRequestForActiveItems())
            let recurringRows = try storeContext.fetch(CDRecurringItem.fetchRequestForActiveItems())
            plannedRecipes = planRows.map { $0.toPlannedRecipe() }
            recurringItems = recurringRows.map { $0.toRecurringItem() }
            snapshotPersistedIDs()
            seedCompleted = true
            // Keep the backup in step with the store so a stale copy can never
            // reseed rows that were deleted elsewhere.
            writeBackupJSON()
            DefrostReminderPlanner.refresh()
        } catch {
            print("[STORE ERROR] week plan reload failed: \(error.localizedDescription)")
        }
    }

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
}

// MARK: - Core Data mapping

/// [String] is not CloudKit-mirrorable; persisted as a JSON array string,
/// preserving order (ingredient lines are ordered, unlike dietary tags).
private enum StringArrayCoding {
    static func encode(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    static func decode(_ json: String?) -> [String] {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return array
    }
}

extension CDPlannedRecipe {

    static func fetchRequestForActiveItems() -> NSFetchRequest<CDPlannedRecipe> {
        let request = NSFetchRequest<CDPlannedRecipe>(entityName: "CDPlannedRecipe")
        request.predicate = NSPredicate(format: "deletedAt == nil")
        request.sortDescriptors = [
            NSSortDescriptor(key: "dayIndex", ascending: true),
            NSSortDescriptor(key: "createdAt", ascending: true)
        ]
        return request
    }

    static func fetchRequest(forID id: UUID) -> NSFetchRequest<CDPlannedRecipe> {
        let request = NSFetchRequest<CDPlannedRecipe>(entityName: "CDPlannedRecipe")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return request
    }

    func toPlannedRecipe() -> PlannedRecipe {
        PlannedRecipe(
            id: id ?? UUID(),
            dayIndex: Int(dayIndex),
            recipeID: recipeID ?? "",
            recipeName: recipeName ?? "",
            ingredients: StringArrayCoding.decode(ingredientsJSON),
            dietaryTags: StringArrayCoding.decode(dietaryTagsJSON),
            serves: serves ?? "4"
        )
    }

    /// Assigns only on change — a dirty property is a CloudKit write.
    func apply(_ plan: PlannedRecipe) {
        if id != plan.id { id = plan.id }
        if dayIndex != Int16(clamping: plan.dayIndex) { dayIndex = Int16(clamping: plan.dayIndex) }
        if recipeID != plan.recipeID { recipeID = plan.recipeID }
        if recipeName != plan.recipeName { recipeName = plan.recipeName }

        let ingredients = StringArrayCoding.encode(plan.ingredients)
        if ingredientsJSON != ingredients { ingredientsJSON = ingredients }

        let tags = StringArrayCoding.encode(plan.dietaryTags)
        if dietaryTagsJSON != tags { dietaryTagsJSON = tags }

        if serves != plan.serves { serves = plan.serves }
        if createdAt == nil { createdAt = Date() }

        if hasPersistentChangedValues { updatedAt = Date() }
    }

    func softDelete() {
        guard deletedAt == nil else { return }
        deletedAt = Date()
        updatedAt = Date()
    }
}

extension CDRecurringItem {

    static func fetchRequestForActiveItems() -> NSFetchRequest<CDRecurringItem> {
        let request = NSFetchRequest<CDRecurringItem>(entityName: "CDRecurringItem")
        request.predicate = NSPredicate(format: "deletedAt == nil")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        return request
    }

    static func fetchRequest(forID id: UUID) -> NSFetchRequest<CDRecurringItem> {
        let request = NSFetchRequest<CDRecurringItem>(entityName: "CDRecurringItem")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return request
    }

    func toRecurringItem() -> RecurringHouseholdItem {
        RecurringHouseholdItem(
            id: id ?? UUID(),
            name: name ?? "",
            quantity: quantity ?? "1",
            unit: unit ?? "",
            interval: RestockInterval(rawValue: intervalRaw ?? "monthly") ?? .monthly,
            lastAddedToList: lastAddedToList
        )
    }

    func apply(_ item: RecurringHouseholdItem) {
        if id != item.id { id = item.id }
        if name != item.name { name = item.name }
        if quantity != item.quantity { quantity = item.quantity }
        if unit != item.unit { unit = item.unit }
        if intervalRaw != item.interval.rawValue { intervalRaw = item.interval.rawValue }
        if lastAddedToList != item.lastAddedToList { lastAddedToList = item.lastAddedToList }
        if createdAt == nil { createdAt = Date() }

        if hasPersistentChangedValues { updatedAt = Date() }
    }

    func softDelete() {
        guard deletedAt == nil else { return }
        deletedAt = Date()
        updatedAt = Date()
    }
}

extension NSManagedObjectContext {

    /// No unique constraint on `id` (CloudKit mirroring rejects them); uniqueness
    /// is enforced here, matching upsertShoppingItem / upsertFridgeItem.
    func upsertPlannedRecipe(id: UUID) throws -> CDPlannedRecipe {
        if let existing = try fetch(CDPlannedRecipe.fetchRequest(forID: id)).first {
            return existing
        }
        let created = CDPlannedRecipe(context: self)
        created.id = id
        created.createdAt = Date()
        created.updatedAt = Date()
        return created
    }

    func upsertRecurringItem(id: UUID) throws -> CDRecurringItem {
        if let existing = try fetch(CDRecurringItem.fetchRequest(forID: id)).first {
            return existing
        }
        let created = CDRecurringItem(context: self)
        created.id = id
        created.createdAt = Date()
        created.updatedAt = Date()
        return created
    }
}
