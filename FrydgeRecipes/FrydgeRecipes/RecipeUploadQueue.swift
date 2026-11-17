//
//  RecipeUploadQueue.swift
//  FrydgeRecipes
//
//  Durable queue for recipes that could not be saved to CloudKit (offline,
//  iCloud hiccup, app killed mid-save). Replaces three earlier partial
//  implementations that shared a single UserDefaults key:
//
//    • CloudRecipe.syncOfflineRecipes()  — fired uploads then wiped the whole
//      queue before any of them finished. Also never called.
//    • Networking.syncOfflineRecipes()   — the version the app actually called;
//      an empty stub, so queued recipes were never uploaded at all.
//    • SyncQueueManager                  — unused, wrote "TODO" as record data.
//
//  Guarantees:
//    • An entry is removed only after CloudKit confirms that specific save.
//    • A failed save stays queued (attempt count + last error recorded) and is
//      retried on the next drain. Other entries in the same drain are unaffected.
//    • Re-uploading is idempotent: the CKRecord name is the recipe's stable ID
//      and the save policy is `.changedKeys`, so a retry after a lost success
//      callback overwrites the same record instead of failing on a change tag.
//    • Entries that cannot be understood (legacy formats, corrupt JSON) are
//      moved to a quarantine file for inspection, never silently dropped.
//

import Foundation
import CloudKit
import UIKit
import os

// MARK: - Model

/// One recipe waiting to be saved to the public CloudKit database.
struct PendingRecipeUpload: Codable, Identifiable {
    /// Same as `recipe.id`, which is also the CKRecord name.
    var id: String { recipe.id }
    var recipe: CloudRecipe
    /// JPEG bytes captured at enqueue time. `CloudRecipe.image` is a UIImage and
    /// is not Codable, so the picture travels separately.
    var imageData: Data?
    var enqueuedAt: Date
    var attempts: Int
    var lastError: String?
}

/// A queue entry that could not be processed. Kept so nothing is lost silently.
struct QuarantinedRecipeUpload: Codable, Identifiable {
    var id: UUID
    var reason: String
    /// Best-effort serialisation of the original entry (JSON or plist bytes).
    var payload: Data?
    var quarantinedAt: Date
}

/// Result of one `drain()` pass.
struct RecipeUploadDrainSummary: Equatable {
    var uploaded: [String] = []
    var failed: [String: String] = [:]
    var skipped = false

    func succeeded(_ id: String) -> Bool { uploaded.contains(id) }
}

// MARK: - CloudKit seam

/// The one CloudKit call the queue needs. Abstracted so tests can drive the
/// queue with a fake and assert on exactly which records were saved.
protocol RecipeRecordSaving {
    func saveRecipeRecord(_ record: CKRecord) async throws
}

extension CKDatabase: RecipeRecordSaving {
    func saveRecipeRecord(_ record: CKRecord) async throws {
        // `.changedKeys` ignores the server change tag. On a brand-new CKRecord
        // every set key counts as changed, so this is an upsert of our fields
        // that leaves any server-only fields (e.g. an image we don't have) alone.
        let result = try await modifyRecords(
            saving: [record],
            deleting: [],
            savePolicy: .changedKeys,
            atomically: true
        )
        if case .failure(let error)? = result.saveResults[record.recordID] {
            throw error
        }
    }
}

// MARK: - Queue

final class RecipeUploadQueue: @unchecked Sendable {

    static let shared = RecipeUploadQueue()

    private static let log = Logger(subsystem: "com.Clark-Online.Recipes", category: "RecipeUploadQueue")

    /// After this many consecutive failed drains an entry is moved to quarantine
    /// so a permanently rejected record (e.g. a schema violation) stops being
    /// retried on every launch. It is still kept on disk for inspection.
    static let maxAttemptsBeforeQuarantine = 25

    private let directory: URL
    private let saver: RecipeRecordSaving
    private let isNetworkAvailable: () -> Bool

    /// Guards `pending`, `quarantined`, `isDraining` and all file writes.
    private let lock = NSLock()
    private var pendingStorage: [PendingRecipeUpload] = []
    private var quarantinedStorage: [QuarantinedRecipeUpload] = []
    private var isDraining = false

    private var pendingURL: URL { directory.appendingPathComponent("pending.json") }
    private var quarantineURL: URL { directory.appendingPathComponent("quarantine.json") }

    /// App-wide instance: Application Support storage, the public database,
    /// and a one-time migration of the legacy UserDefaults queue.
    private convenience init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(
            directory: base.appendingPathComponent("RecipeUploadQueue", isDirectory: true),
            saver: CKContainer(identifier: "iCloud.com.Clark-Online.Recipe").publicCloudDatabase,
            isNetworkAvailable: { NetworkMonitor.shared.isNetworkAvailable() }
        )
        migrateLegacyUserDefaults(.standard)
    }

    /// Designated initialiser. Tests pass a temporary directory and a fake saver.
    init(directory: URL, saver: RecipeRecordSaving, isNetworkAvailable: @escaping () -> Bool = { true }) {
        self.directory = directory
        self.saver = saver
        self.isNetworkAvailable = isNetworkAvailable
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        loadFromDisk()
    }

    // MARK: Read access

    var pending: [PendingRecipeUpload] {
        lock.lock(); defer { lock.unlock() }
        return pendingStorage
    }

    var quarantined: [QuarantinedRecipeUpload] {
        lock.lock(); defer { lock.unlock() }
        return quarantinedStorage
    }

    var pendingCount: Int { pending.count }

    // MARK: Enqueue

    /// Adds a recipe to the queue and persists immediately. A second enqueue of
    /// the same recipe ID replaces the earlier entry, so the latest edit wins and
    /// the record is uploaded once.
    func enqueue(_ recipe: CloudRecipe, image: UIImage? = nil) {
        var stored = recipe
        // UIImage / CKAsset are not encoded; carry the picture as JPEG bytes.
        let jpeg = (image ?? recipe.image)?.frydgeBoundedJPEG(quality: 0.8)
        stored.image = nil

        let entry = PendingRecipeUpload(
            recipe: stored,
            imageData: jpeg,
            enqueuedAt: Date(),
            attempts: 0,
            lastError: nil
        )

        lock.lock()
        pendingStorage.removeAll { $0.id == entry.id }
        pendingStorage.append(entry)
        persistPendingLocked()
        lock.unlock()

        Self.log.notice("Queued recipe \(entry.id, privacy: .public) for upload (\(self.pendingCount) pending)")
    }

    // MARK: Drain

    /// Convenience for call sites that are not async (app delegate hooks).
    func drainInBackground() {
        Task.detached(priority: .utility) { [self] in
            _ = await drain()
        }
    }

    /// Synchronous so the lock is never taken from an async context.
    /// Returns nil if a drain is already running, otherwise the entries to upload.
    private func beginDraining() -> [PendingRecipeUpload]? {
        lock.lock(); defer { lock.unlock() }
        if isDraining { return nil }
        isDraining = true
        return pendingStorage
    }

    private func endDraining() {
        lock.lock(); defer { lock.unlock() }
        isDraining = false
    }

    /// Attempts every pending upload once. Each entry is removed only after its
    /// own save succeeds. Failures are recorded and left in place. Returns a
    /// summary so a caller that just enqueued can report success or failure.
    @discardableResult
    func drain() async -> RecipeUploadDrainSummary {
        var summary = RecipeUploadDrainSummary()

        guard isNetworkAvailable() else {
            Self.log.notice("Offline; leaving \(self.pendingCount) recipe upload(s) queued")
            summary.skipped = true
            return summary
        }

        guard let snapshot = beginDraining() else {
            summary.skipped = true
            return summary
        }
        defer { endDraining() }

        guard !snapshot.isEmpty else { return summary }
        Self.log.notice("Draining \(snapshot.count) queued recipe upload(s)")

        for entry in snapshot {
            var recipe = entry.recipe
            recipe.image = UIImage.frydgeBounded(data: entry.imageData, maxPixelSize: ImageBudget.upload)
            let record = recipe.toCKRecord()

            do {
                try await saver.saveRecipeRecord(record)
                remove(entry)
                summary.uploaded.append(entry.id)
                Self.log.notice("Uploaded queued recipe \(entry.id, privacy: .public)")
            } catch {
                let message = (error as? CKError)?.friendlyMessage ?? error.localizedDescription
                recordFailure(for: entry, message: message)
                summary.failed[entry.id] = message
                Self.log.error("Queued recipe \(entry.id, privacy: .public) failed (attempt \(entry.attempts + 1)): \(message, privacy: .public)")
            }
        }

        return summary
    }

    /// Removes `entry` only if the stored version is the one we just uploaded.
    /// If the user re-saved the recipe while the drain was in flight, the newer
    /// entry stays and goes up on the next pass.
    private func remove(_ entry: PendingRecipeUpload) {
        lock.lock(); defer { lock.unlock() }
        pendingStorage.removeAll { $0.id == entry.id && $0.enqueuedAt == entry.enqueuedAt }
        persistPendingLocked()
    }

    private func recordFailure(for entry: PendingRecipeUpload, message: String) {
        lock.lock(); defer { lock.unlock() }
        guard let index = pendingStorage.firstIndex(where: { $0.id == entry.id && $0.enqueuedAt == entry.enqueuedAt }) else {
            return // replaced by a newer enqueue meanwhile; that one will be tried next
        }
        pendingStorage[index].attempts += 1
        pendingStorage[index].lastError = message

        if pendingStorage[index].attempts >= Self.maxAttemptsBeforeQuarantine {
            let stale = pendingStorage.remove(at: index)
            quarantinedStorage.append(QuarantinedRecipeUpload(
                id: UUID(),
                reason: "Gave up after \(stale.attempts) attempts. Last error: \(message)",
                payload: try? JSONEncoder().encode(stale),
                quarantinedAt: Date()
            ))
            persistQuarantineLocked()
        }
        persistPendingLocked()
    }

    // MARK: Quarantine

    /// Deletes quarantined entries. Only ever called deliberately (debug UI or a
    /// future "discard" action); the queue itself never does this.
    func clearQuarantine() {
        lock.lock(); defer { lock.unlock() }
        quarantinedStorage.removeAll()
        persistQuarantineLocked()
    }

    private func quarantine(reason: String, payload: Data?) {
        lock.lock(); defer { lock.unlock() }
        quarantinedStorage.append(QuarantinedRecipeUpload(id: UUID(), reason: reason, payload: payload, quarantinedAt: Date()))
        persistQuarantineLocked()
    }

    // MARK: Legacy migration

    static let legacyRecipesKey = "offlineRecipes"
    static let legacyUpdatesKey = "offlineUpdates"

    /// Imports the two UserDefaults arrays the old implementations wrote and
    /// removes the keys. Two formats shared `offlineRecipes`:
    ///   A. `["recipe": <JSON Data of CloudRecipe>, "imageData": Data?]`
    ///   B. flat plist dictionary from `CloudRecipe.toDictionary()` plus `imageData`
    /// Anything else, and every `offlineUpdates` entry (which never had an
    /// upload path), is quarantined rather than discarded.
    func migrateLegacyUserDefaults(_ defaults: UserDefaults) {
        let legacyRecipes = defaults.array(forKey: Self.legacyRecipesKey) as? [[String: Any]]
        let legacyUpdates = defaults.array(forKey: Self.legacyUpdatesKey) as? [[String: Any]]
        guard legacyRecipes != nil || legacyUpdates != nil else { return }

        var migrated = 0
        for entry in legacyRecipes ?? [] {
            if let (recipe, imageData) = Self.decodeLegacyEntry(entry) {
                lock.lock()
                pendingStorage.removeAll { $0.id == recipe.id }
                pendingStorage.append(PendingRecipeUpload(
                    recipe: recipe,
                    imageData: imageData,
                    enqueuedAt: Date(),
                    attempts: 0,
                    lastError: nil
                ))
                lock.unlock()
                migrated += 1
            } else {
                quarantine(reason: "Unrecognised legacy offlineRecipes entry", payload: Self.plistData(entry))
            }
        }

        for entry in legacyUpdates ?? [] {
            quarantine(reason: "Legacy offlineUpdates entry; no upload path existed for updates", payload: Self.plistData(entry))
        }

        lock.lock()
        persistPendingLocked()
        lock.unlock()

        defaults.removeObject(forKey: Self.legacyRecipesKey)
        defaults.removeObject(forKey: Self.legacyUpdatesKey)

        Self.log.notice("Migrated legacy offline queue: \(migrated) recipe(s) queued, \(self.quarantined.count) quarantined")
    }

    private static func decodeLegacyEntry(_ entry: [String: Any]) -> (CloudRecipe, Data?)? {
        let imageData = entry["imageData"] as? Data

        // Format A: JSON-encoded CloudRecipe under "recipe".
        if let data = entry["recipe"] as? Data {
            guard let recipe = try? JSONDecoder().decode(CloudRecipe.self, from: data) else { return nil }
            return (recipe, imageData)
        }

        // Format B: flat dictionary from toDictionary().
        guard let id = entry["id"] as? String, !id.isEmpty,
              let name = entry["name"] as? String else { return nil }

        var steps: [RecipeStep] = []
        if let stepsJSON = entry["stepsJSON"] as? String,
           let data = stepsJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([RecipeStep].self, from: data) {
            steps = decoded
        }

        let recipe = CloudRecipe(
            name: name,
            serves: entry["serves"] as? String ?? "4",
            ingredients: entry["ingredients"] as? [String] ?? [],
            pan: entry["pan"] as? String ?? "",
            instructions: entry["instructions"] as? String ?? "",
            steps: steps,
            id: id,
            location: entry["location"] as? String ?? "Fridge",
            dietaryTags: entry["dietaryTags"] as? [String] ?? [],
            creationDate: entry["creationDate"] as? Date,
            modificationDate: entry["modificationDate"] as? Date
        )
        return (recipe, imageData)
    }

    private static func plistData(_ entry: [String: Any]) -> Data? {
        if let data = try? PropertyListSerialization.data(fromPropertyList: entry, format: .binary, options: 0) {
            return data
        }
        return String(describing: entry).data(using: .utf8)
    }

    // MARK: Disk

    private func loadFromDisk() {
        lock.lock(); defer { lock.unlock() }

        // Quarantine first: an unreadable pending file below appends to it and
        // persists, and reading the file afterwards would double-count that entry.
        if let data = try? Data(contentsOf: quarantineURL),
           let decoded = try? JSONDecoder().decode([QuarantinedRecipeUpload].self, from: data) {
            quarantinedStorage = decoded
        }

        if let data = try? Data(contentsOf: pendingURL) {
            do {
                pendingStorage = try JSONDecoder().decode([PendingRecipeUpload].self, from: data)
            } catch {
                // Never throw the file away: keep the raw bytes for inspection.
                Self.log.error("Pending queue file unreadable; quarantining it: \(error.localizedDescription, privacy: .public)")
                quarantinedStorage.append(QuarantinedRecipeUpload(
                    id: UUID(),
                    reason: "pending.json failed to decode: \(error.localizedDescription)",
                    payload: data,
                    quarantinedAt: Date()
                ))
                persistQuarantineLocked()
                pendingStorage = []
                persistPendingLocked()
            }
        }
    }

    /// Caller must hold `lock`.
    private func persistPendingLocked() {
        write(pendingStorage, to: pendingURL)
    }

    /// Caller must hold `lock`.
    private func persistQuarantineLocked() {
        write(quarantinedStorage, to: quarantineURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.log.error("Failed to persist \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
