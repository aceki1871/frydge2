//
//  CoreDataHousekeeping.swift
//  FrydgeRecipes
//
//  Was CoreDataMirror.swift — the Phase 2 dual-write scaffolding. Both managers
//  now read and write Core Data directly (Phase 3a/3b), so the mirroring and the
//  one-time importer are gone and only periodic housekeeping remains.
//

import CoreData
import Foundation
import os

actor CoreDataHousekeeping {

    static let shared = CoreDataHousekeeping()

    private static let log = Logger(subsystem: "com.Clark-Online.Recipes", category: "CoreDataHousekeeping")

    /// Kill switch — set true to skip housekeeping without a rebuild.
    private static let killSwitchKey = "coreDataHousekeepingDisabled"

    private var isEnabled: Bool {
        if UserDefaults.standard.bool(forKey: Self.killSwitchKey) { return false }
        if PersistenceController.shared.isDegraded { return false }
        return true
    }

    private init() {}

    /// Hard-deletes soft-deleted rows past the retention window.
    ///
    /// Safe in a way the old local tombstones were not: by the time a row is
    /// purged the delete has already replicated to every device as a real synced
    /// change, so there is no live copy left anywhere to resurrect it. The old
    /// design expired tombstones locally after 7 days while other devices still
    /// held the item, which is exactly how deletes came back.
    func purgeOldTombstones() async {
        guard isEnabled else { return }

        let context = PersistenceController.shared.newBackgroundContext()
        do {
            try await context.perform {
                try context.purgeSoftDeleted()
                if context.hasChanges { try context.save() }
            }
        } catch {
            Self.log.error("Tombstone purge failed: \(String(describing: error))")
            await context.perform { context.rollback() }
        }
    }
}
