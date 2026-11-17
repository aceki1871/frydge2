//
//  RecipeImportInbox.swift
//  FrydgeRecipes
//
//  The single reader for links the Share Extension drops into the App Group
//  container. The extension appends to `recipe_import_inbox_queue.json`;
//  an older build wrote a one-item `recipe_import_inbox.json`, which is
//  still folded in so nothing shared before an update is lost.
//
//  Both the import window (list, tap to import, remove) and the deep-link
//  handler (pop the newest item) go through here, so there is exactly one
//  definition of what an inbox item is.
//

import Foundation

struct RecipeImportInboxItem: Identifiable, Codable, Hashable {
    var id: String
    var urlString: String
    var createdAtISO8601: String
    var source: String

    var url: URL? { URL(string: urlString) }

    var displayHost: String {
        let host = url?.host?.lowercased() ?? ""
        if host.contains("instagram") { return "Instagram" }
        if host.contains("tiktok") { return "TikTok" }
        if host.contains("youtube") || host.contains("youtu.be") { return "YouTube" }
        if host.contains("facebook") || host.contains("fb.watch") { return "Facebook" }
        if host.contains("pinterest") || host.contains("pin.it") { return "Pinterest" }
        if host.isEmpty { return "Shared link" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var createdAt: Date? { ISO8601DateFormatter().date(from: createdAtISO8601) }

    var displayDate: String {
        guard let d = createdAt else { return "" }
        return d.formatted(.relative(presentation: .named))
    }
}

enum RecipeImportInbox {
    static let appGroupID = "group.Clark-Online.FrydgeRecipeAPN"
    static let queueFilename = "recipe_import_inbox_queue.json"
    static let legacyFilename = "recipe_import_inbox.json"

    /// Newest first. Empty when the App Group isn't available.
    static func items() -> [RecipeImportInboxItem] {
        var items = readQueue()
        if let legacy = readLegacy(), !items.contains(where: { $0.urlString == legacy.urlString }) {
            items.append(legacy)
        }
        return items
    }

    /// Removes and returns the newest shared link, or nil when empty.
    @discardableResult
    static func popFirstURL() -> URL? {
        withQueueLock {
            var queue = readQueue()
            if let first = queue.first, let url = first.url {
                queue.removeAll { $0.urlString == first.urlString }
                writeQueue(queue)
                return url
            }
            if let legacy = readLegacy(), let url = legacy.url {
                removeLegacy()
                return url
            }
            return nil
        }
    }

    static func peekFirstURL() -> URL? {
        items().first?.url
    }

    static func remove(_ item: RecipeImportInboxItem) {
        remove(urlString: item.urlString)
    }

    static func remove(urlString: String) {
        withQueueLock {
            var queue = readQueue()
            queue.removeAll { $0.urlString == urlString }
            writeQueue(queue)
            if readLegacy()?.urlString == urlString { removeLegacy() }
        }
    }

    static func clear() {
        withQueueLock {
            writeQueue([])
            removeLegacy()
        }
    }

    // MARK: - Files

    private static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// Name of the advisory lock file shared with the Share Extension's
    /// `RecipeImportInboxQueue.enqueue`. Both sides read-modify-write the same
    /// JSON file from different processes; without the lock an import removed
    /// here could resurrect, or a link shared while the app was draining could
    /// be dropped.
    static let lockFilename = ".frydge-recipe-inbox.lock"

    private static func withQueueLock<T>(_ body: () -> T) -> T {
        guard let lockURL = folder?.appendingPathComponent(lockFilename) else { return body() }
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return body() }
        defer { close(fd) }
        if flock(fd, LOCK_EX) != 0 { return body() }
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    private static func readQueue() -> [RecipeImportInboxItem] {
        guard let url = folder?.appendingPathComponent(queueFilename),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RecipeImportInboxItem].self, from: data)) ?? []
    }

    private static func writeQueue(_ items: [RecipeImportInboxItem]) {
        guard let url = folder?.appendingPathComponent(queueFilename) else { return }
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    /// Older share-extension builds wrote a single payload rather than a queue.
    private struct LegacyPayload: Codable {
        var urlString: String?
        var url: String?
        var text: String?
    }

    private static func readLegacy() -> RecipeImportInboxItem? {
        guard let url = folder?.appendingPathComponent(legacyFilename),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(LegacyPayload.self, from: data),
              let raw = payload.urlString ?? payload.url, URL(string: raw) != nil else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
        return RecipeImportInboxItem(
            id: "legacy-\(raw.hashValue)",
            urlString: raw,
            createdAtISO8601: ISO8601DateFormatter().string(from: modified),
            source: "legacy"
        )
    }

    private static func removeLegacy() {
        guard let url = folder?.appendingPathComponent(legacyFilename) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
