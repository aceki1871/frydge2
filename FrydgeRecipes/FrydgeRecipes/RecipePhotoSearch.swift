//
//  RecipePhotoSearch.swift
//  FrydgeRecipes
//
//  Last-resort photo lookup by recipe *name*. `RecipeImageLoader` calls this
//  only after every stored source (memory, disk, CKAsset, imageSourceURL,
//  CloudKit record) has come up empty, so the emoji placeholder is reserved
//  for recipes no image can be found for at all.
//
//  Two public sources are tried in order, both already used elsewhere in the
//  app for product photos:
//    1. Wikipedia article search with page images — "Thai Green Curry" →
//       the lead photo of the "Green curry" article.
//    2. Wikimedia Commons file search — broader coverage for dishes that
//       have photos but no article.
//  Results are gated the same way product lookups are: the article must share
//  a word with the query and read as food, so "Mum's Tuesday Special" never
//  turns into a picture of a railway station.
//

import Foundation

nonisolated enum RecipePhotoSearch {

    /// Thumbnail width requested from the APIs. A standard Wikimedia step so
    /// hot-linked thumbnails are served from the edge cache.
    static let thumbnailWidth = RemoteImageFetcher.wikimediaThumbnailWidth

    /// First candidate photo URL for a recipe name, or nil if nothing food
    /// related matches. Network failures also return nil; the caller decides
    /// how long to remember the miss.
    static func imageURL(for recipeName: String) async -> URL? {
        for term in searchTerms(for: recipeName) {
            if Task.isCancelled { return nil }
            if let url = await wikipediaPageImage(for: term) { return url }
            if Task.isCancelled { return nil }
            if let url = await commonsFileImage(for: term) { return url }
        }
        return nil
    }

    // MARK: - Query shaping

    /// Words that describe the cook, not the dish. Stripped before searching
    /// so "Quick & Easy Weeknight Chicken Stir-Fry" searches as
    /// "Chicken Stir-Fry".
    private static let fillerWords: Set<String> = [
        "easy", "quick", "simple", "best", "ultimate", "perfect", "classic",
        "homemade", "home-made", "healthy", "weeknight", "weekend", "favourite",
        "favorite", "delicious", "tasty", "yummy", "amazing", "authentic",
        "traditional", "cheap", "budget", "leftover", "leftovers", "minute",
        "recipe", "recipes", "style", "my", "our", "the", "a", "an", "with",
        "and", "&", "of", "for", "in", "on", "one-pot", "one-pan", "sheet-pan",
        "air", "fryer", "airfryer", "air-fryer", "slow", "cooker", "instant", "pot"
    ]

    /// Ordered search terms: the cleaned full name, then its trailing words
    /// (dish names usually end with the dish: "... Chicken Curry" → "Curry").
    static func searchTerms(for recipeName: String) -> [String] {
        var text = recipeName

        // Drop parentheticals and anything after a dash/colon subtitle.
        text = text.replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
        if let range = text.range(of: #"\s+[-–—:|]\s+"#, options: .regularExpression) {
            text = String(text[..<range.lowerBound])
        }

        // Possessives ("Mum's", "Josh's") are never the dish.
        text = text.replacingOccurrences(of: #"\b\w+['’]s\b"#, with: "", options: .regularExpression)

        // Numbers ("5-minute", "3 ingredient") and leftover punctuation.
        text = text.replacingOccurrences(of: #"\b\d+[\w-]*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[^\p{L}\p{M}\s'-]"#, with: " ", options: .regularExpression)

        let words = text
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-'")) }
            .filter { !$0.isEmpty && !fillerWords.contains($0.lowercased()) }

        guard !words.isEmpty else {
            let raw = recipeName.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? [] : [raw]
        }

        var terms: [String] = [words.joined(separator: " ")]
        if words.count > 2 { terms.append(words.suffix(2).joined(separator: " ")) }
        if words.count > 1, let last = words.last { terms.append(last) }

        // Dedupe case-insensitively while keeping order.
        var seen = Set<String>()
        return terms.filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: - Relevance gates

    private static let stopWords: Set<String> = ["a", "an", "the", "of", "with", "and", "or", "in", "on", "at", "to", "for", "by", "from"]

    /// The hit must share a meaningful word with what was searched.
    static func sharesWord(_ text: String, with query: String) -> Bool {
        let lower = text.lowercased()
        let queryWords = query.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 2 && !stopWords.contains($0) }
        guard !queryWords.isEmpty else { return true }
        return queryWords.contains { lower.contains($0) }
    }

    private static let foodSignals: [String] = [
        "food", "ingredient", "cuisine", "dish", "vegetable", "fruit", "meat", "dairy",
        "bread", "sauce", "spice", "herb", "cooking", "cooked", "baking", "baked",
        "beverage", "drink", "grain", "legume", "edible", "flavour", "flavor",
        "culinary", "recipe", "dessert", "soup", "stew", "salad", "pasta", "noodle",
        "rice", "cake", "pie", "curry", "sandwich", "snack", "meal", "breakfast",
        "lunch", "dinner", "seasoning", "eaten", "served", "fried", "roast", "grill",
        "cheese", "fish", "seafood", "poultry", "chicken", "beef", "pork", "lamb",
        "pastry", "sweet", "savoury", "savory", "dumpling", "pizza", "taco", "burger"
    ]

    /// Title + description must read as food, not a place, band or person.
    static func looksLikeFood(_ text: String) -> Bool {
        let lower = text.lowercased()
        return foodSignals.contains { lower.contains($0) }
    }

    // MARK: - Wikipedia article search

    private static func wikipediaPageImage(for term: String) async -> URL? {
        guard var components = URLComponents(string: "https://en.wikipedia.org/w/api.php") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: term),
            URLQueryItem(name: "gsrlimit", value: "5"),
            URLQueryItem(name: "prop", value: "pageimages|description"),
            URLQueryItem(name: "piprop", value: "thumbnail"),
            URLQueryItem(name: "pithumbsize", value: "\(thumbnailWidth)")
        ]
        guard let url = components.url else { return nil }

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

        guard let decoded: Response = await fetchJSON(url) else { return nil }
        let pages = (decoded.query?.pages ?? [:]).values.sorted { ($0.index ?? 99) < ($1.index ?? 99) }
        for page in pages {
            guard let source = page.thumbnail?.source else { continue }
            let text = [page.title, page.description].compactMap { $0 }.joined(separator: " ")
            guard sharesWord(text, with: term), looksLikeFood(text) else { continue }
            if let imageURL = URL(string: source) { return imageURL }
        }
        return nil
    }

    // MARK: - Wikimedia Commons file search

    private static func commonsFileImage(for term: String) async -> URL? {
        guard var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: "\(term) food"),
            URLQueryItem(name: "gsrnamespace", value: "6"),
            URLQueryItem(name: "gsrlimit", value: "8"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|mime"),
            URLQueryItem(name: "iiurlwidth", value: "\(thumbnailWidth)")
        ]
        guard let url = components.url else { return nil }

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

        guard let decoded: Response = await fetchJSON(url) else { return nil }
        let pages = (decoded.query?.pages ?? [:]).values.sorted { ($0.index ?? 99) < ($1.index ?? 99) }
        for page in pages {
            guard let info = page.imageinfo?.first,
                  let mime = info.mime, mime == "image/jpeg" || mime == "image/png",
                  let raw = info.thumburl ?? info.url,
                  sharesWord(page.title ?? "", with: term),
                  let imageURL = URL(string: raw) else { continue }
            return imageURL
        }
        return nil
    }

    // MARK: - Transport

    /// Goes through `RemoteImageFetcher.data(from:)` so the Wikimedia
    /// User-Agent, retries and wait-for-connectivity all apply.
    private static func fetchJSON<T: Decodable>(_ url: URL) async -> T? {
        do {
            let (data, _) = try await RemoteImageFetcher.data(from: url)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }
}
