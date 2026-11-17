//
//  ProductImageCacheManager.swift
//  FrydgeRecipes
//
//  Created by Josh on 14/04/2026.

import Foundation
import UIKit

struct CachedProductImageInfo: Codable, Equatable {
    let itemKey: String
    let productName: String
    let storeName: String?
    let remoteURL: String
    let localFilename: String
    let updatedAt: Date
}

final class ProductImageCacheManager {
    static let shared = ProductImageCacheManager()

    // ─── Edamam Food Database API credentials ────────────────────────────────
    // Sign up free at https://developer.edamam.com → "Food Database API".
    // Credentials live in the gitignored `secrets.plist` (keys `EdamamAppID`
    // and `EdamamAppKey`) so they never land in source control. Both resolve
    // to "" when absent, which simply disables the Edamam image lookup.
    private let edamamAppID  = FrydgeSecrets.edamamAppID
    private let edamamAppKey = FrydgeSecrets.edamamAppKey
    // ─────────────────────────────────────────────────────────────────────────

    // ─── Spoonacular Ingredient Image API ────────────────────────────────────
    // Free key (150 req/day): https://spoonacular.com/food-api → sign up → API Console
    private let spoonacularApiKey = ""  // ← paste your key here
    // ─────────────────────────────────────────────────────────────────────────

    private let fm = FileManager.default
    // Serial queue used for disk writes only
    private let ioQueue = DispatchQueue(label: "ProductImageCacheManager.io", qos: .utility)
    // Protects _metadata and hasLoadedMetadata across threads
    private let metadataLock = NSLock()
    private let metadataFilename = "product-image-cache-metadata.json"
    private let folderName = "ProductImages"
    private let staleInterval: TimeInterval = 7 * 24 * 60 * 60

    // Hot in-memory layer: O(1) lookup, evicted automatically under memory pressure
    private let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 500
        cache.totalCostLimit = 200 * 1024 * 1024 // 200 MB
        return cache
    }()

    private var _metadata: [String: CachedProductImageInfo] = [:]
    private var hasLoadedMetadata = false

    // Dedup: actor-isolated set of keys currently being fetched
    private let inFlight = InFlightSet()

    private init() {
        // Publish credentials to EdamamService so it can use the same keys
        EdamamCredentials.appID  = edamamAppID
        EdamamCredentials.appKey = edamamAppKey
    }

    // MARK: - Public

    func imageCacheKey(name: String, quantity: String, unit: String) -> String {
        let raw = [name, quantity, unit]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return raw
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    func cachedInfo(forKey key: String) -> CachedProductImageInfo? {
        metadataLock.lock()
        defer { metadataLock.unlock() }
        loadMetadataLocked()
        return _metadata[key]
    }

    func localImageURL(forKey key: String) -> URL? {
        metadataLock.lock()
        defer { metadataLock.unlock() }
        loadMetadataLocked()
        guard let info = _metadata[key] else { return nil }

        let url = imagesDirectoryURL().appendingPathComponent(info.localFilename)
        guard fm.fileExists(atPath: url.path) else {
            _metadata.removeValue(forKey: key)
            persistMetadataAsyncUnderLock()
            return nil
        }
        return url
    }

    func uiImage(forKey key: String) -> UIImage? {
        // Hot path: in-memory cache avoids disk I/O on repeated access within a session
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        guard let url = localImageURL(forKey: key),
              let image = UIImage.frydgeBounded(contentsOf: url, maxPixelSize: ImageBudget.display) else {
            return nil
        }

        let cost = Int(image.size.width * image.size.height) * 4
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)
        return image
    }

    func isStale(forKey key: String) -> Bool {
        metadataLock.lock()
        defer { metadataLock.unlock() }
        loadMetadataLocked()
        guard let info = _metadata[key] else { return true }
        return Date().timeIntervalSince(info.updatedAt) > staleInterval
    }

    func allCachedEntries() -> [CachedProductImageInfo] {
        metadataLock.lock()
        defer { metadataLock.unlock() }
        loadMetadataLocked()
        return Array(_metadata.values).sorted { $0.productName.lowercased() < $1.productName.lowercased() }
    }

    @discardableResult
    func storeImage(
        from remoteURL: URL,
        forKey key: String,
        productName: String,
        storeName: String?
    ) async throws -> URL {
        // Ensure metadata is loaded before the network call
        metadataLock.withLock { loadMetadataLocked() }

        // Shared image session: waits for connectivity, retries transient
        // failures and 429/5xx, and identifies the app to Wikimedia hosts.
        let (data, response) = try await RemoteImageFetcher.data(from: remoteURL)

        if let http = response, !(200...299).contains(http.statusCode) {
            throw ImageCacheError.badResponse
        }

        // Reject suspiciously small payloads — 1×1 trackers, empty error bodies, etc.
        guard data.count >= 1_024 else {
            throw ImageCacheError.tooSmall
        }

        // Decode bounded: the cached JPEG written below is then at most
        // ImageBudget.display on its longest edge, however large the source.
        guard let image = UIImage.frydgeBounded(data: data, maxPixelSize: ImageBudget.display) else {
            throw ImageCacheError.invalidImageData
        }

        // Reject images that decoded to a trivially small canvas (degenerate/corrupt)
        guard image.size.width >= 32, image.size.height >= 32 else {
            throw ImageCacheError.tooSmall
        }

        let jpegData = image.jpegData(compressionQuality: 0.88) ?? data
        let filename = sanitizedFilename(forKey: key) + ".jpg"
        let localURL = imagesDirectoryURL().appendingPathComponent(filename)

        try ensureImagesDirectoryExists()
        try jpegData.write(to: localURL, options: .atomic)

        let info = CachedProductImageInfo(
            itemKey: key,
            productName: productName,
            storeName: storeName,
            remoteURL: remoteURL.absoluteString,
            localFilename: filename,
            updatedAt: Date()
        )

        metadataLock.withLock {
            _metadata[key] = info
            persistMetadataAsyncUnderLock()
        }

        // Populate memory cache so the next uiImage(forKey:) call is instant
        let cost = Int(image.size.width * image.size.height) * 4
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)

        return localURL
    }

    func updateFromRemoteURLString(
        _ remoteURLString: String?,
        name: String,
        quantity: String,
        unit: String,
        productName: String? = nil,
        storeName: String? = nil
    ) async {
        guard let remoteURLString,
              let remoteURL = URL(string: remoteURLString),
              !remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let key = imageCacheKey(name: name, quantity: quantity, unit: unit)

        if let existing = cachedInfo(forKey: key),
           existing.remoteURL == remoteURLString,
           localImageURL(forKey: key) != nil,
           !isStale(forKey: key) {
            return
        }

        do {
            _ = try await storeImage(
                from: remoteURL,
                forKey: key,
                productName: productName ?? name,
                storeName: storeName
            )
        } catch {
            // Best-effort cache. Fail silently here unless you want debug logging.
        }
    }

    /// Returns total bytes used on disk by the image cache folder.
    func diskUsageBytes() -> Int64 {
        let folder = imagesDirectoryURL()
        guard let files = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return files.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    /// Formatted string like "14.2 MB" for display in UI.
    func diskUsageFormatted() -> String {
        let bytes = diskUsageBytes()
        if bytes == 0 { return "0 KB" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1024
        return String(format: "%.1f MB", mb)
    }

    // MARK: - Background Prefetch

    /// Fetches and caches an image for the given ingredient name if one isn't already stored.
    /// Safe to call repeatedly — skips items that already have a fresh cached image.
    func prefetchIfNeeded(for name: String) async {
        let key = imageCacheKey(name: name, quantity: "", unit: "")
        guard localImageURL(forKey: key) == nil || isStale(forKey: key) else { return }
        guard await inFlight.tryInsert(key) else { return }
        // Try the brand-stripped food word first ("Anchor Butter" → "butter"),
        // then any other food keywords in the name, then the name minus pack
        // sizes. Each variant walks the whole source chain before the next
        // one is tried, so a photo is found for far more items.
        var imageURL: URL? = nil
        for query in Self.imageQueryVariants(for: name) {
            if let url = await fetchFirstImageURL(for: query) { imageURL = url; break }
        }
        guard let imageURL else {
            await inFlight.remove(key); return
        }
        _ = try? await storeImage(from: imageURL, forKey: key, productName: name, storeName: nil)
        await inFlight.remove(key)
    }

    /// Distinct search phrases for a fridge item name, most specific first.
    static func imageQueryVariants(for name: String) -> [String] {
        var out: [String] = []
        func push(_ s: String) {
            let t = s.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            guard t.count >= 2, !out.contains(t) else { return }
            out.append(t)
        }
        push(FoodEmoji.searchTerm(for: name))
        for keyword in FoodEmoji.wholeWordKeywords(in: name) { push(keyword) }
        // Raw name with pack sizes / counts removed ("Mainland Tasty 500g" → "mainland tasty").
        push(name.replacingOccurrences(
            of: "\\b\\d+(?:\\.\\d+)?\\s*(?:kg|g|l|ml|pk|pack|pc|pcs|x|ea|each|dozen)?\\b",
            with: "", options: [.regularExpression, .caseInsensitive]))
        return Array(out.prefix(3))
    }

    private func fetchFirstImageURL(for name: String) async -> URL? {
        // Stage 0 — Frydge products DB (OFF mirror on Cloudflare). When the product
        // exists there with a photo it's the real packaged product, so it wins.
        // ~30% of products carry an image; the rest fall through to the sources below.
        if let url = await fetchFrydgeProductImageURL(for: name) { return url }

        // Stage 0 — Spoonacular: purpose-built ingredient image CDN, most accurate food photos.
        if !spoonacularApiKey.isEmpty,
           let url = await fetchSpoonacularImageURL(for: name) { return url }

        // Stage 1 — Edamam: food-specific database, highest image quality for cooking ingredients.
        // Cap at 4 s: if it responds (URL or nil) before then, move on immediately.
        if !edamamAppID.isEmpty, !edamamAppKey.isEmpty {
            let edamamURL: URL? = await withTaskGroup(of: URL?.self) { group in
                group.addTask { await self.fetchEdamamImageURL(for: name) }
                group.addTask { try? await Task.sleep(for: .seconds(4)); return nil }
                for await result in group { group.cancelAll(); return result }
                return nil
            }
            if let url = edamamURL { return url }
        }

        // Stage 2 — OFF + Wikipedia: broader coverage, race for the first valid result.
        let raced: URL? = await withTaskGroup(of: URL?.self) { group in
            group.addTask { await self.fetchOFFImageURL(for: name) }
            group.addTask { await self.fetchWikipediaThumbnailURL(for: name) }
            var found: URL? = nil
            for await result in group {
                if let url = result, found == nil { found = url; group.cancelAll() }
            }
            return found
        }
        if let raced { return raced }

        // Stage 3 — Wikipedia full-text search (catches "capsicum" → "Bell pepper"
        // where the direct slug missed) and Wikimedia Commons photo search.
        if let url = await fetchWikipediaSearchThumbnail(for: name) { return url }
        return await fetchWikimediaCommonsImageURLs(for: name, limit: 1).first
    }

    // MARK: - Gallery

    /// Several distinct photos for an item, for the detail sheet's carousel:
    /// product shots from the products DB first, then Wikimedia Commons.
    /// Results are memoised per name for the life of the process.
    func galleryImageURLs(for name: String, limit: Int = 4) async -> [URL] {
        let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = galleryLock.withLock({ galleryCache[key] }) { return cached }

        var urls: [URL] = []
        var seen = Set<String>()
        func push(_ url: URL) {
            guard urls.count < limit, seen.insert(url.absoluteString).inserted else { return }
            urls.append(url)
        }

        let variants = Self.imageQueryVariants(for: name)
        if let first = variants.first,
           let hits = try? await OpenFoodFactsService.shared.searchRich(first) {
            for hit in hits {
                guard let raw = hit.imageURL ?? hit.imageSmallURL, let url = URL(string: raw) else { continue }
                push(url)
            }
        }
        if urls.count < limit, let first = variants.first {
            for url in await fetchWikimediaCommonsImageURLs(for: first, limit: limit - urls.count) { push(url) }
        }

        galleryLock.withLock { galleryCache[key] = urls }
        return urls
    }

    private let galleryLock = NSLock()
    private var galleryCache: [String: [URL]] = [:]

    /// Looks the name up in the Frydge products DB and returns its image URL, if any.
    private func fetchFrydgeProductImageURL(for query: String) async -> URL? {
        guard let hit = try? await OpenFoodFactsService.shared.searchRich(query).first,
              let urlString = hit.imageURL,
              !urlString.isEmpty,
              let url = URL(string: urlString) else { return nil }
        return url
    }

    private func fetchEdamamImageURL(for query: String) async -> URL? {
        guard var components = URLComponents(string: "https://api.edamam.com/api/food-database/v2/parser") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "app_id", value: edamamAppID),
            URLQueryItem(name: "app_key", value: edamamAppKey),
            URLQueryItem(name: "ingr", value: query),
            URLQueryItem(name: "nutrition-type", value: "logging")
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        struct EdamamResponse: Decodable {
            struct Hint: Decodable {
                struct Food: Decodable { let label: String?; let image: String? }
                let food: Food
            }
            let hints: [Hint]
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            let decoded = try JSONDecoder().decode(EdamamResponse.self, from: data)
            if let hint = decoded.hints.first,
               let imageStr = hint.food.image,
               isFoodRelevant(responseText: hint.food.label ?? "", query: query) {
                return URL(string: imageStr)
            }
        } catch { return nil }
        return nil
    }

    private func fetchSpoonacularImageURL(for query: String) async -> URL? {
        guard !spoonacularApiKey.isEmpty else { return nil }
        guard var components = URLComponents(string: "https://api.spoonacular.com/food/ingredients/search") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "number", value: "1"),
            URLQueryItem(name: "apiKey", value: spoonacularApiKey)
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 6)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        struct SpoonacularResponse: Decodable {
            struct Ingredient: Decodable { let image: String? }
            let results: [Ingredient]
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            let decoded = try JSONDecoder().decode(SpoonacularResponse.self, from: data)
            if let imageName = decoded.results.first?.image,
               !imageName.isEmpty,
               let imageURL = URL(string: "https://spoonacular.com/cdn/ingredients_500x500/\(imageName)") {
                return imageURL
            }
        } catch { return nil }
        return nil
    }

    private func fetchOFFImageURL(for query: String) async -> URL? {
        guard var components = URLComponents(string: "https://world.openfoodfacts.org/cgi/search.pl") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "search_terms", value: query),
            URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "action", value: "process"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "page_size", value: "1")
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            let decoded = try JSONDecoder().decode(PICMOFFSearchResponse.self, from: data)
            if let product = decoded.products.first,
               let raw = product.imageFrontURL ?? product.imageURL,
               let imageURL = URL(string: raw) {
                let name = product.productName ?? ""
                // Accept when name is unavailable or when it contains a query keyword
                guard name.isEmpty || isFoodRelevant(responseText: name, query: query) else { return nil }
                return imageURL
            }
        } catch { return nil }
        return nil
    }

    private func fetchWikipediaThumbnailURL(for name: String) async -> URL? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        var terms: [String] = [clean]
        let firstWord = clean.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.first ?? clean
        if firstWord.lowercased() != clean.lowercased() { terms.append(firstWord) }
        return await withTaskGroup(of: URL?.self) { group in
            for term in terms { group.addTask { await self.fetchWikipediaSummaryThumbnail(for: term) } }
            var found: URL? = nil
            for await result in group {
                if let url = result, found == nil { found = url; group.cancelAll() }
            }
            return found
        }
    }

    private func fetchWikipediaSummaryThumbnail(for term: String) async -> URL? {
        let slug = term.replacingOccurrences(of: " ", with: "_")
        guard let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        struct WikiSummary: Decodable {
            struct Thumbnail: Decodable { let source: String }
            let thumbnail: Thumbnail?
            let type: String?
            let title: String?
            let description: String?
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            let decoded = try JSONDecoder().decode(WikiSummary.self, from: data)
            guard decoded.type != "disambiguation" else { return nil }
            let pageText = [decoded.title, decoded.description].compactMap { $0 }.joined(separator: " ")
            // Gate 1: article title/description must share a word with the food query
            guard isFoodRelevant(responseText: pageText, query: term) else { return nil }
            // Gate 2: article must actually be in the food domain — catches brand names
            // that match unrelated Wikipedia articles (e.g. "Anchor" → nautical anchor)
            guard isFoodDomainArticle(pageText) else { return nil }
            if let source = decoded.thumbnail?.source { return URL(string: source) }
        } catch { return nil }
        return nil
    }

    /// Wikipedia full-text search with page thumbnails. Finds the article even
    /// when the food is known by another name ("capsicum" → "Bell pepper",
    /// "kumara" → "Sweet potato"). Same relevance gates as the slug lookup.
    private func fetchWikipediaSearchThumbnail(for term: String) async -> URL? {
        guard var components = URLComponents(string: "https://en.wikipedia.org/w/api.php") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: "\(term) food"),
            URLQueryItem(name: "gsrlimit", value: "4"),
            URLQueryItem(name: "prop", value: "pageimages|description"),
            URLQueryItem(name: "piprop", value: "thumbnail"),
            URLQueryItem(name: "pithumbsize", value: "600")
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        struct Response: Decodable {
            struct Query: Decodable { let pages: [String: Page]? }
            struct Page: Decodable {
                struct Thumbnail: Decodable { let source: String }
                let title: String?
                let description: String?
                let thumbnail: Thumbnail?
                let index: Int?
            }
            let query: Query?
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let pages = (decoded.query?.pages ?? [:]).values.sorted { ($0.index ?? 99) < ($1.index ?? 99) }
            for page in pages {
                guard let source = page.thumbnail?.source else { continue }
                let text = [page.title, page.description].compactMap { $0 }.joined(separator: " ")
                guard isFoodDomainArticle(text) else { continue }
                if let url = URL(string: source) { return url }
            }
        } catch { return nil }
        return nil
    }

    /// Photos from Wikimedia Commons' file search. Broad coverage for whole
    /// foods and far more than one picture per food, which the gallery uses.
    /// Only JPEG/PNG files whose name mentions the query word are accepted.
    private func fetchWikimediaCommonsImageURLs(for term: String, limit: Int) async -> [URL] {
        guard limit > 0, var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: "\(term) food"),
            URLQueryItem(name: "gsrnamespace", value: "6"),
            URLQueryItem(name: "gsrlimit", value: "\(min(10, limit * 3))"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|mime"),
            URLQueryItem(name: "iiurlwidth", value: "600")
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        struct Response: Decodable {
            struct Query: Decodable { let pages: [String: Page]? }
            struct Page: Decodable {
                struct Info: Decodable { let thumburl: String?; let url: String?; let mime: String? }
                let title: String?
                let index: Int?
                let imageinfo: [Info]?
            }
            let query: Query?
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return [] }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let pages = (decoded.query?.pages ?? [:]).values.sorted { ($0.index ?? 99) < ($1.index ?? 99) }
            var out: [URL] = []
            for page in pages where out.count < limit {
                guard let info = page.imageinfo?.first,
                      let mime = info.mime, mime == "image/jpeg" || mime == "image/png",
                      let raw = info.thumburl ?? info.url,
                      isFoodRelevant(responseText: page.title ?? "", query: term),
                      let url = URL(string: raw) else { continue }
                out.append(url)
            }
            return out
        } catch { return [] }
    }

    func removeImage(forKey key: String) {
        memoryCache.removeObject(forKey: key as NSString)

        metadataLock.lock()
        defer { metadataLock.unlock() }
        loadMetadataLocked()

        if let info = _metadata[key] {
            let url = imagesDirectoryURL().appendingPathComponent(info.localFilename)
            try? fm.removeItem(at: url)
        }

        _metadata.removeValue(forKey: key)
        persistMetadataAsyncUnderLock()
    }

    func clearAll() {
        memoryCache.removeAllObjects()

        metadataLock.lock()
        defer { metadataLock.unlock() }
        loadMetadataLocked()

        let folder = imagesDirectoryURL()
        try? fm.removeItem(at: folder)

        _metadata.removeAll()
        persistMetadataAsyncUnderLock()
    }

    func pruneOrphanedFiles() {
        metadataLock.lock()
        loadMetadataLocked()
        let validFilenames = Set(_metadata.values.map(\.localFilename))
        metadataLock.unlock()

        let folder = imagesDirectoryURL()

        guard let files = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for file in files where !validFilenames.contains(file.lastPathComponent) {
            try? fm.removeItem(at: file)
        }
    }

    // MARK: - Private

    // Must be called while holding metadataLock
    private func loadMetadataLocked() {
        guard !hasLoadedMetadata else { return }
        hasLoadedMetadata = true

        let url = metadataFileURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: CachedProductImageInfo].self, from: data) else {
            _metadata = [:]
            return
        }

        _metadata = decoded
    }

    // Must be called while holding metadataLock — captures snapshot before dispatching
    private func persistMetadataAsyncUnderLock() {
        let snapshot = _metadata
        let url = metadataFileURL()

        ioQueue.async {
            do {
                let folder = self.imagesDirectoryURL()
                if !self.fm.fileExists(atPath: folder.path) {
                    try self.fm.createDirectory(at: folder, withIntermediateDirectories: true)
                }

                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                // Best-effort cache persistence
            }
        }
    }

    private func ensureImagesDirectoryExists() throws {
        let folder = imagesDirectoryURL()
        if !fm.fileExists(atPath: folder.path) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    private func imagesDirectoryURL() -> URL {
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    private func metadataFileURL() -> URL {
        imagesDirectoryURL().appendingPathComponent(metadataFilename)
    }

    private func sanitizedFilename(forKey key: String) -> String {
        let cleaned = key
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9-_]", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))

        return cleaned.isEmpty ? UUID().uuidString.lowercased() : cleaned
    }
}

// MARK: - Errors

enum ImageCacheError: Error {
    case badResponse
    case invalidImageData
    case tooSmall   // payload < 2 KB or canvas < 32×32 — likely a placeholder/tracker
}

// MARK: - Image relevance check

func isFoodRelevant(responseText: String, query: String) -> Bool {
    guard !responseText.isEmpty else { return true }
    let stops: Set<String> = ["a", "an", "the", "of", "with", "and", "or", "in", "on", "at", "to", "for", "by", "from"]
    let lower = responseText.lowercased()
    let queryWords = query.lowercased()
        .components(separatedBy: .whitespaces)
        .filter { !$0.isEmpty && $0.count > 2 && !stops.contains($0) }
    guard !queryWords.isEmpty else { return true }
    // A query word like "carrot" matches "carrots" because it's a direct substring
    return queryWords.contains { lower.contains($0) }
}

/// Returns true when the Wikipedia article title+description signals a food or ingredient context.
/// This catches brand-name first-word fallbacks like "Anchor" (nautical) matching "Anchor Butter".
func isFoodDomainArticle(_ text: String) -> Bool {
    let foodSignals: Set<String> = [
        "food", "ingredient", "cuisine", "dish", "vegetable", "fruit",
        "meat", "dairy", "bread", "sauce", "spice", "herb", "cooking",
        "baking", "beverage", "drink", "grain", "legume", "crop", "edible",
        "flavour", "flavor", "nutrition", "culinary", "recipe",
        "plant", "species", "cultivar", "fish", "poultry", "livestock",
        "seasoning", "eaten", "consumed", "taste"
    ]
    let lower = text.lowercased()
    return foodSignals.contains { lower.contains($0) }
}

// MARK: - OFF response types (file-private to avoid conflicts with FridgeView's copy)

private struct PICMOFFSearchResponse: Decodable {
    let products: [PICMOFFProduct]
}

private struct PICMOFFProduct: Decodable {
    let imageFrontURL: String?
    let imageURL: String?
    let productName: String?

    enum CodingKeys: String, CodingKey {
        case imageFrontURL = "image_front_url"
        case imageURL = "image_url"
        case productName = "product_name"
    }
}

// MARK: - Concurrency helper

private actor InFlightSet {
    private var keys: Set<String> = []
    func tryInsert(_ key: String) -> Bool {
        guard !keys.contains(key) else { return false }
        keys.insert(key)
        return true
    }
    func remove(_ key: String) { keys.remove(key) }
}
