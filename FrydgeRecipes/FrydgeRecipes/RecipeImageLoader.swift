//
//  RecipeImageLoader.swift
//  FrydgeRecipes
//
//  Resolves the photo for a recipe: in-memory → disk (Documents/recipe-images)
//  → CKAsset temp file → remote imageSourceURL → CloudKit record fetch
//  → photo search by recipe name (`RecipePhotoSearch`).
//
//  The last leg exists so a real photograph always wins over the emoji
//  placeholder: the emoji is only shown when nothing at all can be found for
//  the recipe. Found photos are written to the same permanent disk cache as
//  every other source, so the lookup happens once per recipe, not per scroll.
//
//  Network legs go through `RemoteImageFetcher` (retry, wait-for-connectivity,
//  Wikimedia thumbnails, downsampled decoding) — see that file for the App
//  Review history behind it. The CloudKit leg is only attempted for recipes
//  that have actually been a CKRecord (bundled default-pack recipes never
//  have a server-side image) and misses are remembered, so a list of 200
//  cards no longer fires 200 doomed CloudKit requests on every scroll.
//

import UIKit
import CloudKit

@MainActor
final class RecipeImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var isLoading = false

    private static let memCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 100 * 1024 * 1024
        return cache
    }()

    private var loadedID: String?
    private var downloadTask: Task<Void, Never>?

    func load(recipe: CloudRecipe) {
        let id = recipe.id
        if id == loadedID, image != nil || isLoading {
            return
        }

        // 0. Recipe has an in-memory UIImage (e.g., just created)
        if let img = recipe.image {
            loadedID = id
            downloadTask?.cancel()
            Self.memCache.setObject(img, forKey: id as NSString)
            image = img
            isLoading = false
            return
        }

        // Only recipes that came from CloudKit (they carry a server creation
        // date) can have a server-side image asset worth fetching.
        let mayExistInCloudKit = recipe.creationDate != nil || recipe.imageAsset != nil

        load(
            id: id,
            assetFileURL: recipe.imageAsset?.fileURL,
            remoteURLString: recipe.imageSourceURL,
            mayExistInCloudKit: mayExistInCloudKit,
            recipeName: recipe.name
        )
    }

    /// Lighter-weight entry point for callers that only have the id and a
    /// possible remote URL (e.g. thumbnail rows that don't hold a full
    /// `CloudRecipe`). Same disk cache → asset → remote resolution and the
    /// same off-main-thread load as `load(recipe:)`. Pass `recipeName` so a
    /// recipe with no stored photo can still be found by name.
    func load(id: String, assetFileURL: URL? = nil, remoteURLString: String?, mayExistInCloudKit: Bool = true, recipeName: String? = nil) {
        if id == loadedID, image != nil || isLoading {
            return
        }

        loadedID = id
        downloadTask?.cancel()
        image = nil
        isLoading = false

        // 1. Memory cache
        if let cached = Self.memCache.object(forKey: id as NSString) {
            image = cached
            return
        }

        isLoading = true

        downloadTask = Task { [weak self, id, assetFileURL, remoteURLString, mayExistInCloudKit, recipeName] in
            let loadedImage = await Task.detached(priority: .utility) {
                await Self.loadCachedOrRemoteImage(
                    id: id,
                    assetFileURL: assetFileURL,
                    remoteURLString: remoteURLString,
                    mayExistInCloudKit: mayExistInCloudKit,
                    recipeName: recipeName
                )
            }.value

            guard !Task.isCancelled, let self else { return }

            if let loadedImage {
                let cost = Int(loadedImage.size.width * loadedImage.scale * loadedImage.size.height * loadedImage.scale) * 4
                Self.memCache.setObject(loadedImage, forKey: id as NSString, cost: cost)
                image = loadedImage
            }

            isLoading = false
        }
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        isLoading = false

        if image == nil {
            loadedID = nil
        }
    }

    // MARK: - Resolution chain (off main thread)

    private nonisolated static func loadCachedOrRemoteImage(
        id: String,
        assetFileURL: URL?,
        remoteURLString: String?,
        mayExistInCloudKit: Bool,
        recipeName: String?
    ) async -> UIImage? {
        if Task.isCancelled { return nil }

        // 2. Disk cache (permanent storage in Documents/recipe-images/{id}.jpg)
        if let disk = loadFromDisk(id: id) {
            return disk
        }

        if Task.isCancelled { return nil }

        // 3. CKAsset temp file — valid for this process lifetime; copy to disk while we can
        if let assetFileURL,
           let assetImage = RemoteImageFetcher.decodeDownsampled(contentsOf: assetFileURL) {
            saveToDisk(assetImage, id: id)
            return assetImage
        }

        if Task.isCancelled { return nil }

        // 4. Remote imageSourceURL — download (with retries, thumbnail first) and persist to disk
        if let remoteURLString = remoteURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
           !remoteURLString.isEmpty,
           let url = URL(string: remoteURLString) {
            do {
                let candidates = RemoteImageFetcher.wikimediaCandidates(for: url)
                let remoteImage = try await RemoteImageFetcher.fetchImage(candidates: candidates)
                if Task.isCancelled { return nil }
                saveToDisk(remoteImage, id: id)
                return remoteImage
            } catch is CancellationError {
                return nil
            } catch {
                // Fall through to the CloudKit asset.
            }
        }

        if Task.isCancelled { return nil }

        // 5. CloudKit asset. Recipes restored from the on-device cache lose
        //    their CKAsset (it isn't Codable) and may have no remote URL, so
        //    the photo only exists on the server. Fetch just the image field
        //    and persist it, after which step 2 above serves it offline.
        if mayExistInCloudKit, !cloudKitMisses.contains(id), !hasRecentCloudKitMissMarker(id: id),
           let cloudImage = await loadFromCloudKit(id: id) {
            return cloudImage
        }

        if Task.isCancelled { return nil }

        // 6. Photo search by name. Nothing is stored for this recipe anywhere,
        //    so look the dish up on Wikipedia / Wikimedia Commons. A hit is
        //    persisted like any other source; a miss is remembered for a day
        //    so lists don't re-query for recipes that genuinely have no photo.
        return await loadByName(id: id, recipeName: recipeName)
    }

    // MARK: - Name search

    /// Recipe IDs whose name search found nothing, for this process.
    private nonisolated static let nameSearchMisses = IDSet()

    private nonisolated static func loadByName(id: String, recipeName: String?) async -> UIImage? {
        guard let recipeName = recipeName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !recipeName.isEmpty,
              !nameSearchMisses.contains(id),
              !hasRecentNameSearchMissMarker(id: id) else {
            return nil
        }

        guard let url = await RecipePhotoSearch.imageURL(for: recipeName) else {
            if !Task.isCancelled {
                nameSearchMisses.insert(id)
                writeNameSearchMissMarker(id: id)
            }
            return nil
        }

        if Task.isCancelled { return nil }

        do {
            let image = try await RemoteImageFetcher.fetchImage(candidates: RemoteImageFetcher.wikimediaCandidates(for: url))
            if Task.isCancelled { return nil }
            saveToDisk(image, id: id)
            return image
        } catch {
            // Transient download failure: leave it open to retry next time.
            return nil
        }
    }

    /// Name-search misses expire after a day; the catalogues grow and a
    /// transient outage shouldn't pin the placeholder for good.
    private nonisolated static let nameSearchMissTTL: TimeInterval = 24 * 60 * 60

    private nonisolated static func nameSearchMissMarkerURL(id: String) -> URL {
        imagesDirectory().appendingPathComponent("\(id).nophoto")
    }

    private nonisolated static func hasRecentNameSearchMissMarker(id: String) -> Bool {
        let url = nameSearchMissMarkerURL(id: id)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else { return false }
        if Date().timeIntervalSince(modified) > nameSearchMissTTL {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return true
    }

    private nonisolated static func writeNameSearchMissMarker(id: String) {
        let dir = imagesDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data().write(to: nameSearchMissMarkerURL(id: id), options: [.atomic])
    }

    // MARK: - CloudKit

    private nonisolated static let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")

    /// Record IDs that CloudKit confirmed have no image, for this process.
    private nonisolated static let cloudKitMisses = IDSet()

    private final class IDSet: @unchecked Sendable {
        private let lock = NSLock()
        private var ids = Set<String>()
        func contains(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
        func insert(_ id: String) { lock.lock(); defer { lock.unlock() }; ids.insert(id) }
    }

    private nonisolated static func loadFromCloudKit(id: String) async -> UIImage? {
        guard !id.isEmpty else { return nil }
        do {
            let records = try await container.publicCloudDatabase.records(
                for: [CKRecord.ID(recordName: id)],
                desiredKeys: ["image"]
            )
            guard !Task.isCancelled else { return nil }
            guard case .success(let record)? = records[CKRecord.ID(recordName: id)],
                  let asset = record["image"] as? CKAsset,
                  let fileURL = asset.fileURL,
                  let image = RemoteImageFetcher.decodeDownsampled(contentsOf: fileURL) else {
                // Definitive answer from the server: no image. Remember it.
                cloudKitMisses.insert(id)
                writeCloudKitMissMarker(id: id)
                return nil
            }
            saveToDisk(image, id: id)
            return image
        } catch let error as CKError where error.code == .unknownItem {
            cloudKitMisses.insert(id)
            writeCloudKitMissMarker(id: id)
            return nil
        } catch {
            // Network / rate-limit errors: leave it open to retry next time.
            return nil
        }
    }

    /// Miss markers live next to the images and expire after six hours so an
    /// image added later on another device still shows up.
    private nonisolated static let cloudKitMissTTL: TimeInterval = 6 * 60 * 60

    private nonisolated static func cloudKitMissMarkerURL(id: String) -> URL {
        imagesDirectory().appendingPathComponent("\(id).nocloudimage")
    }

    private nonisolated static func hasRecentCloudKitMissMarker(id: String) -> Bool {
        let url = cloudKitMissMarkerURL(id: id)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else { return false }
        if Date().timeIntervalSince(modified) > cloudKitMissTTL {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return true
    }

    private nonisolated static func writeCloudKitMissMarker(id: String) {
        let dir = imagesDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data().write(to: cloudKitMissMarkerURL(id: id), options: [.atomic])
    }

    // MARK: - Disk

    private nonisolated static func imagesDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recipe-images", isDirectory: true)
    }

    private nonisolated static func loadFromDisk(id: String) -> UIImage? {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let candidates = [
            imagesDirectory().appendingPathComponent("\(id).jpg"),
            base.appendingPathComponent("\(id).jpg")
        ]

        for url in candidates {
            if Task.isCancelled { return nil }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let img = RemoteImageFetcher.decodeDownsampled(contentsOf: url) {
                return img
            }
            // A file that exists but won't decode (e.g. an HTML error page or
            // a .djvu saved under .jpg by an older prefetch) would otherwise
            // be re-tried on every appearance. Remove it so the chain can
            // re-download a good copy.
            try? FileManager.default.removeItem(at: url)
        }

        return nil
    }

    private nonisolated static func saveToDisk(_ img: UIImage, id: String) {
        let dir = imagesDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = img.jpegData(compressionQuality: 0.8) else { return }
        try? data.write(to: dir.appendingPathComponent("\(id).jpg"), options: [.atomic])
        try? FileManager.default.removeItem(at: cloudKitMissMarkerURL(id: id))
    }
}
