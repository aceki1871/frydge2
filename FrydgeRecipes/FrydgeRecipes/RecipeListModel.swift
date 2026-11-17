import CloudKit
import Foundation
import UIKit

@MainActor
class RecipeListModel: ObservableObject {
    @Published var recipes: [CloudRecipe] = []
    @Published var syncStatus: String = "Syncing..."
    private let lastFetchKey   = "recipesLastFetchDate"
    /// Recipes received through share links that aren't in the public
    /// CloudKit database (the sender never synced them). Kept separately so a
    /// full refresh from CloudKit doesn't drop them.
    private let importedSharesKey = "importedSharedRecipes"
    private let container: CKContainer
    private var publicDatabase: CKDatabase

    init() {
        container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
        publicDatabase = container.publicCloudDatabase
        loadCachedRecipes()
        applyDefaultPack()
        applyImportedShares()
        prefetchRecipeImages()

        NotificationCenter.default.addObserver(
            forName: .frydgeResetRecipesToDefaults,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resetToDefaults()
            }
        }
    }

    // MARK: - Fetch

    /// Fetches from CloudKit only when the local cache is empty or older than `maxAge`.
    /// Pull-to-refresh always calls `fetchRecipesFromCloud()` directly.
    func fetchIfStale(maxAge: TimeInterval = 15 * 60) async {
        let lastFetch = UserDefaults.standard.object(forKey: lastFetchKey) as? Date
        let isStale = lastFetch == nil || Date().timeIntervalSince(lastFetch!) > maxAge
        guard isStale else {
            syncStatus = "Up to date"
            return
        }
        await fetchRecipesFromCloud()
    }

    func fetchRecipesFromCloud() async {
        let query = CKQuery(recordType: "Recipe", predicate: NSPredicate(value: true))

        do {
            var fetchedRecords: [CKRecord] = []
            let firstPage = try await publicDatabase.records(matching: query)
            fetchedRecords.append(contentsOf: successfulRecords(from: firstPage.matchResults))

            var cursor = firstPage.queryCursor
            while let nextCursor = cursor {
                let page = try await publicDatabase.records(continuingMatchFrom: nextCursor)
                fetchedRecords.append(contentsOf: successfulRecords(from: page.matchResults))
                cursor = page.queryCursor
            }

            await MainActor.run {
                self.recipes = fetchedRecords.map { CloudRecipe(from: $0) }
                self.applyDefaultPack()
                self.applyImportedShares()
                self.syncStatus = "Sync Complete"
                self.saveRecipesToCache()
                self.prefetchRecipeImages()
                UserDefaults.standard.set(Date(), forKey: self.lastFetchKey)
            }
        } catch {
            await MainActor.run {
                self.syncStatus = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func successfulRecords(from matchResults: [(CKRecord.ID, Result<CKRecord, Error>)]) -> [CKRecord] {
        matchResults.compactMap { _, result in
            switch result {
            case .success(let record):
                return record
            case .failure(let error):
                print("[CK ERROR] Fetch: \(error.localizedDescription)")
                return nil
            }
        }
    }

    // MARK: - Resolve one recipe (share links)

    /// Finds a recipe by id for a share / universal link: the local list
    /// first, then a direct CloudKit record fetch, then the payload stored
    /// with the share link on frydge2.com. Anything found remotely is added to
    /// the list so the detail view can open it straight away.
    func resolveRecipe(id rawID: String) async -> CloudRecipe? {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        if let local = recipes.first(where: { $0.id == id }) {
            return local
        }

        // 1) Public CloudKit record by id (works for any synced recipe,
        //    even if this device's cache is stale).
        do {
            let record = try await publicDatabase.record(for: CKRecord.ID(recordName: id))
            let recipe = CloudRecipe(from: record)
            upsertLocally(recipe)
            print("[RECIPE] Resolved shared recipe id=\(id) from CloudKit")
            return recipe
        } catch {
            print("[RECIPE] CloudKit lookup for shared recipe id=\(id) failed: \(error.localizedDescription)")
        }

        // 2) Payload published with the share link.
        do {
            let recipe = try await FrydgeRecipeShareService.shared.fetchSharedRecipe(id: id)
            rememberImportedShare(recipe)
            upsertLocally(recipe)
            print("[RECIPE] Resolved shared recipe id=\(id) from share payload")
            return recipe
        } catch {
            print("[RECIPE] Share payload lookup for id=\(id) failed: \(error.localizedDescription)")
        }

        return nil
    }

    private func upsertLocally(_ recipe: CloudRecipe) {
        if let index = recipes.firstIndex(where: { $0.id == recipe.id }) {
            recipes[index] = recipe
        } else {
            recipes.insert(recipe, at: 0)
        }
        saveRecipesToCache()
    }

    // MARK: - Add / Upsert
    func addRecipe(_ newRecipe: CloudRecipe) async {
        do {
            let record = newRecipe.toCKRecord()
            let savedRecord = try await publicDatabase.save(record)
            let savedRecipe = CloudRecipe(from: savedRecord)

            await MainActor.run {
                if let index = self.recipes.firstIndex(where: { $0.id == savedRecipe.id }) {
                    self.recipes[index] = savedRecipe
                } else {
                    self.recipes.append(savedRecipe)
                }
                self.saveRecipesToCache()
                self.syncStatus = "Save Complete"
            }
        } catch {
            print("[CK ERROR] Save failed: \(error.localizedDescription)")
            // Durable offline fallback. The queue retries on launch, foreground
            // and reconnect, and drops the entry only after CloudKit confirms.
            RecipeUploadQueue.shared.enqueue(newRecipe, image: newRecipe.image)
            // Keep the recipe visible locally instead of making it vanish until
            // the upload lands.
            upsertLocally(newRecipe)
            syncStatus = "Saved offline, will sync later"
        }
    }

    // MARK: - Update
    func updateRecipe(_ updatedRecipe: CloudRecipe) async {
        await addRecipe(updatedRecipe) // upsert pattern
    }

    // MARK: - Cache
    static func cacheSavedRecipe(_ recipe: CloudRecipe) {
        var cachedRecipes = CachedRecipeLibrary.shared.load()

        if let index = cachedRecipes.firstIndex(where: { $0.id == recipe.id }) {
            cachedRecipes[index] = recipe
        } else {
            cachedRecipes.insert(recipe, at: 0)
        }

        cachedRecipes = cachedRecipes.sorted {
            ($0.modificationDate ?? $0.creationDate ?? .distantPast) > ($1.modificationDate ?? $1.creationDate ?? .distantPast)
        }

        CachedRecipeLibrary.shared.store(cachedRecipes)
    }

    // MARK: - Cache
    private func loadCachedRecipes() {
        // Decoded once per process (see CachedRecipeLibrary), not once per
        // screen that owns a RecipeListModel.
        let cached = CachedRecipeLibrary.shared.load()
        if !cached.isEmpty {
            self.recipes = cached
        }
    }

    private func saveRecipesToCache() {
        let sortedRecipes = recipes.sorted {
            ($0.modificationDate ?? $0.creationDate ?? .distantPast) > ($1.modificationDate ?? $1.creationDate ?? .distantPast)
        }
        CachedRecipeLibrary.shared.store(sortedRecipes)
    }

    private func applyDefaultPack() {
        recipes = DefaultRecipePack.merged(into: recipes)
    }

    // MARK: - Imported shares

    private func loadImportedShares() -> [CloudRecipe] {
        guard let data = UserDefaults.standard.data(forKey: importedSharesKey),
              let decoded = try? JSONDecoder().decode([CloudRecipe].self, from: data) else {
            return []
        }
        return decoded
    }

    private func applyImportedShares() {
        let imported = loadImportedShares()
        guard !imported.isEmpty else { return }
        let existingIDs = Set(recipes.map(\.id))
        let missing = imported.filter { !existingIDs.contains($0.id) }
        guard !missing.isEmpty else { return }
        recipes.append(contentsOf: missing)
    }

    private func rememberImportedShare(_ recipe: CloudRecipe) {
        var imported = loadImportedShares()
        if let index = imported.firstIndex(where: { $0.id == recipe.id }) {
            imported[index] = recipe
        } else {
            imported.insert(recipe, at: 0)
        }
        if let data = try? JSONEncoder().encode(imported) {
            UserDefaults.standard.set(data, forKey: importedSharesKey)
        }
    }

    func resetToDefaults() {
        CachedRecipeLibrary.shared.clear()
        UserDefaults.standard.removeObject(forKey: lastFetchKey)
        UserDefaults.standard.removeObject(forKey: importedSharesKey)
        recipes = []
        applyDefaultPack()
        saveRecipesToCache()
        syncStatus = "Reset to defaults"
    }

    /// Warms the on-disk recipe image cache (Documents/recipe-images/{id}.jpg)
    /// so cards show a photo the moment they scroll in. Only recipes that
    /// have a photo source do any work. Downloads go through
    /// `RemoteImageFetcher` (retries, Wikimedia thumbnails, downsampling) and
    /// are validated as images before anything is written — the previous
    /// version wrote raw bytes, so a `.djvu` or an HTML error page could sit
    /// in the cache as `{id}.jpg` forever and never decode.
    private func prefetchRecipeImages(limit: Int = 80) {
        let candidates = recipes
            .filter { $0.imageAsset != nil || !($0.imageSourceURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
            .prefix(limit)
        guard !candidates.isEmpty else { return }

        let work: [(id: String, assetURL: URL?, remoteURL: String?)] = candidates.map {
            ($0.id, $0.imageAsset?.fileURL, $0.imageSourceURL?.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let directory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("recipe-images", isDirectory: true)

            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                print("[RECIPE IMAGE] Could not create image cache: \(error.localizedDescription)")
                return
            }

            // A few at a time: fast enough to fill the first screen quickly,
            // gentle enough not to trip Wikimedia's per-IP rate limiting.
            let maxConcurrent = 3
            await withTaskGroup(of: Void.self) { group in
                var iterator = work.makeIterator()

                func enqueueNext() -> Bool {
                    guard let item = iterator.next() else { return false }
                    group.addTask {
                        await Self.prefetchOne(id: item.id, assetURL: item.assetURL, remoteURL: item.remoteURL, directory: directory)
                    }
                    return true
                }

                for _ in 0..<maxConcurrent where !enqueueNext() { break }
                while await group.next() != nil {
                    _ = enqueueNext()
                }
            }
        }
    }

    private nonisolated static func prefetchOne(id: String, assetURL: URL?, remoteURL: String?, directory: URL) async {
        let fileManager = FileManager.default
        let targetURL = directory.appendingPathComponent("\(id).jpg")
        let sourceMarkerURL = directory.appendingPathComponent("\(id).source")

        // 1. CKAsset temp file — copy to permanent disk cache while it's available
        if !fileManager.fileExists(atPath: targetURL.path),
           let assetURL,
           let img = RemoteImageFetcher.decodeDownsampled(contentsOf: assetURL),
           let data = img.jpegData(compressionQuality: 0.8) {
            try? data.write(to: targetURL, options: [.atomic])
            return
        }

        // 2. Remote imageSourceURL
        guard let remoteURL, !remoteURL.isEmpty, let url = URL(string: remoteURL) else { return }

        let cachedSource = (try? String(contentsOf: sourceMarkerURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if fileManager.fileExists(atPath: targetURL.path), cachedSource == remoteURL {
            return
        }

        do {
            let image = try await RemoteImageFetcher.fetchImage(candidates: RemoteImageFetcher.wikimediaCandidates(for: url))
            guard let data = image.jpegData(compressionQuality: 0.8) else { return }
            try data.write(to: targetURL, options: [.atomic])
            try remoteURL.write(to: sourceMarkerURL, atomically: true, encoding: .utf8)
        } catch {
            print("[RECIPE IMAGE] Failed to prefetch \(id): \(error.localizedDescription)")
        }
    }
}

extension Notification.Name {
    static let frydgeResetRecipesToDefaults = Notification.Name("FrydgeResetRecipesToDefaults")
}

/// Process-wide memo of the decoded recipe library (the "cachedRecipes"
/// blob in UserDefaults).
///
/// Seven screens each own a `RecipeListModel`, and the expiry-reminder
/// scheduler and Use-it-up AI read the same library. Before this, every one
/// of them re-decoded roughly half a megabyte of JSON on the main thread each
/// time it was created or ran, which stacked up into multi-second stalls when
/// switching tabs. Now the bytes are decoded once and reused until they change.
///
/// Thread-safe: `load()` is called from background tasks as well as the main
/// actor.
final class CachedRecipeLibrary: @unchecked Sendable {
    static let shared = CachedRecipeLibrary()

    static let userDefaultsKey = "cachedRecipes"

    private let lock = NSLock()
    private var lastData: Data?
    private var lastDecoded: [CloudRecipe] = []

    private init() {}

    /// The decoded library. Re-decodes only when the stored bytes differ from
    /// the last decode (for example after an older build or a reset wrote them).
    func load() -> [CloudRecipe] {
        let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey)
        return lock.withLock {
            if data == lastData { return lastDecoded }
            guard let data else {
                lastData = nil
                lastDecoded = []
                return []
            }
            let decoded = (try? JSONDecoder().decode([CloudRecipe].self, from: data)) ?? []
            lastData = data
            lastDecoded = decoded
            return decoded
        }
    }

    /// Encodes and persists `recipes`, keeping the decoded copy so the next
    /// `load()` is free. The memo mirrors what a decode would return, so the
    /// transient in-memory image fields are dropped.
    func store(_ recipes: [CloudRecipe]) {
        guard let data = try? JSONEncoder().encode(recipes) else { return }
        let asDecoded = recipes.map { recipe -> CloudRecipe in
            var copy = recipe
            copy.image = nil
            copy.imageAsset = nil
            return copy
        }
        lock.withLock {
            lastData = data
            lastDecoded = asDecoded
        }
        UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
    }

    func clear() {
        lock.withLock {
            lastData = nil
            lastDecoded = []
        }
        UserDefaults.standard.removeObject(forKey: Self.userDefaultsKey)
    }
}
