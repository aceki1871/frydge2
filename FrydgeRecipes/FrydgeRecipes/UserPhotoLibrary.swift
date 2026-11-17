import Foundation
import UIKit

/// Centralized store for user-uploaded food photos, keyed by normalized ingredient name.
/// Photos added anywhere in the app (fridge, shopping list, etc.) are shared across all views.
///
/// Photo bytes live as individual JPEG files in `Documents/UserPhotos/`; only a
/// small manifest (name → ordered filenames) is loaded at launch. The previous
/// design embedded every photo as base64 in one JSON file, which made first
/// access — and every add/remove — re-read/re-write the entire library.
@MainActor
final class UserPhotoLibrary: ObservableObject {
    static let shared = UserPhotoLibrary()

    /// Ordered photo filenames per normalized ingredient name (newest first).
    @Published private(set) var manifest: [String: [String]] = [:]

    private var imageCache: [String: UIImage] = [:]

    private let directoryURL: URL
    private let manifestURL: URL
    /// Pre-refactor library: one JSON file embedding every photo as base64.
    private let legacyFileURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        directoryURL = docs.appendingPathComponent("UserPhotos", isDirectory: true)
        manifestURL = directoryURL.appendingPathComponent("manifest.json")
        legacyFileURL = docs.appendingPathComponent("userPhotoLibrary.json")
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        loadManifest()
        migrateLegacyLibraryIfNeeded()
    }

    // MARK: - Public API

    /// Full-size photo bytes for a name, newest first. Reads from disk — call
    /// when actually displaying (detail sheets), not per row.
    func photos(for name: String) -> [Data] {
        (manifest[normalize(name)] ?? []).compactMap { try? Data(contentsOf: fileURL(for: $0)) }
    }

    /// Photos for an item, falling back to the copies CloudKit synced for that
    /// item when this device has none for the name yet.
    ///
    /// Ownership: per-item `CDItemPhoto` rows (synced, owned by `FrydgeManager`)
    /// are the durable copy; this name-keyed library is the device-local read
    /// cache the detail views display from. Seeding the cache here is what makes
    /// a photo taken on one device appear on another instead of sitting in a
    /// store no view reads.
    func photosWithSyncedFallback(for name: String, synced: () -> [Data]) -> [Data] {
        let local = photos(for: name)
        if !local.isEmpty { return local }
        let remote = synced()
        guard !remote.isEmpty else { return [] }
        seed(remote, for: name)
        return remote
    }

    /// Writes already-bounded synced photo bytes into the local library
    /// without re-encoding. Skips the group if the manifest already has photos
    /// for the name so a sync never duplicates what the user added locally.
    private func seed(_ blobs: [Data], for name: String) {
        let key = normalize(name)
        guard (manifest[key] ?? []).isEmpty else { return }
        var filenames: [String] = []
        for blob in blobs {
            let filename = UUID().uuidString + ".jpg"
            if (try? blob.write(to: fileURL(for: filename), options: .atomic)) != nil {
                filenames.append(filename)
            }
        }
        guard !filenames.isEmpty else { return }
        imageCache.removeValue(forKey: key)
        manifest[key] = filenames
        saveManifest()
    }

    /// Thumbnails are small, but a long-lived library on a big fridge could
    /// otherwise grow this cache without bound.
    private let imageCacheLimit = 200

    /// Returns the decoded first UIImage for a name, caching the result so thumbnails don't re-decode on every render.
    func firstUIImage(for name: String) -> UIImage? {
        let key = normalize(name)
        if let cached = imageCache[key] { return cached }
        guard let filename = manifest[key]?.first,
              let data = try? Data(contentsOf: fileURL(for: filename)),
              let img = UIImage.frydgeBounded(data: data, maxPixelSize: ImageBudget.thumbnail) else { return nil }
        if imageCache.count >= imageCacheLimit { imageCache.removeAll(keepingCapacity: true) }
        imageCache[key] = img
        return img
    }

    func addPhoto(_ jpeg: Data, for name: String) {
        let key = normalize(name)
        let filename = UUID().uuidString + ".jpg"
        // Re-encode through the size budget so a raw camera frame never lands
        // in the library at full resolution (callers may pass unbounded bytes).
        let bounded = UIImage.frydgeBounded(data: jpeg, maxPixelSize: ImageBudget.upload)?
            .frydgeBoundedJPEG(maxPixelSize: ImageBudget.upload, quality: 0.8) ?? jpeg
        do {
            try bounded.write(to: fileURL(for: filename), options: .atomic)
        } catch {
            print("[UserPhotoLibrary] Failed to write photo: \(error.localizedDescription)")
            return
        }
        imageCache.removeValue(forKey: key)
        manifest[key, default: []].insert(filename, at: 0)
        saveManifest()
    }

    func removePhoto(at index: Int, for name: String) {
        let key = normalize(name)
        guard var filenames = manifest[key], index < filenames.count else { return }
        let removed = filenames.remove(at: index)
        try? FileManager.default.removeItem(at: fileURL(for: removed))
        imageCache.removeValue(forKey: key)
        manifest[key] = filenames.isEmpty ? nil : filenames
        saveManifest()
    }

    // MARK: - Persistence

    private func normalize(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fileURL(for filename: String) -> URL {
        directoryURL.appendingPathComponent(filename)
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else { return }
        manifest = decoded
    }

    @discardableResult
    private func saveManifest() -> Bool {
        guard let data = try? JSONEncoder().encode(manifest) else { return false }
        do {
            try data.write(to: manifestURL, options: .atomic)
            return true
        } catch {
            print("[UserPhotoLibrary] Failed to write manifest: \(error.localizedDescription)")
            return false
        }
    }

    /// One-time upgrade: unpacks the old all-photos-in-one-JSON library into
    /// individual files, then removes the legacy file so it's never parsed again.
    ///
    /// All-or-nothing: the legacy file is the only copy of those photos until
    /// every blob and the manifest are durable. If any write fails, the files
    /// written this run are removed, the manifest is restored and the legacy
    /// file is left in place so the next launch retries without duplicating.
    private func migrateLegacyLibraryIfNeeded() {
        guard FileManager.default.fileExists(atPath: legacyFileURL.path) else { return }

        guard let data = try? Data(contentsOf: legacyFileURL),
              let legacy = try? JSONDecoder().decode([String: [Data]].self, from: data) else {
            // Unreadable legacy file: set it aside rather than delete, and stop
            // re-attempting the migration on every launch.
            try? FileManager.default.moveItem(
                at: legacyFileURL,
                to: legacyFileURL.appendingPathExtension("unreadable")
            )
            return
        }

        let manifestBefore = manifest
        var written: [String] = []
        var failed = false

        outer: for (key, blobs) in legacy {
            var filenames: [String] = []
            for blob in blobs {
                let filename = UUID().uuidString + ".jpg"
                do {
                    try blob.write(to: fileURL(for: filename), options: .atomic)
                    filenames.append(filename)
                    written.append(filename)
                } catch {
                    print("[UserPhotoLibrary] Migration write failed: \(error.localizedDescription)")
                    failed = true
                    break outer
                }
            }
            if !filenames.isEmpty {
                manifest[key, default: []].append(contentsOf: filenames)
            }
        }

        if !failed, saveManifest() {
            try? FileManager.default.removeItem(at: legacyFileURL)
            print("[UserPhotoLibrary] Migrated \(legacy.count) photo groups out of legacy JSON.")
            return
        }

        // Roll back: the legacy file stays authoritative for the retry.
        for filename in written {
            try? FileManager.default.removeItem(at: fileURL(for: filename))
        }
        manifest = manifestBefore
        saveManifest()
        print("[UserPhotoLibrary] Migration rolled back; legacy library kept for retry.")
    }
}
