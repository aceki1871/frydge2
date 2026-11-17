//
//  RecipeImportManager.swift
//  FrydgeRecipes
//
//  Created by Josh on 10/01/2026.
//
//  Refactored: efficient HTML fetching + SwiftSoup parsing + parallel image prefetch.
//

import Foundation
import UIKit
import SwiftSoup

@MainActor
final class RecipeImportManager: ObservableObject {

    // MARK: - Types

    struct ImportedIngredient: Identifiable, Hashable, Codable {
        var id = UUID()
        var name: String
        var quantity: String? // keep string to preserve fractions like "1/2"
        var unit: String?
        var originalLine: String

        init(name: String, quantity: String?, unit: String?, originalLine: String) {
            self.name = name
            self.quantity = quantity?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            self.unit = unit?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            self.originalLine = originalLine.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func asAppIngredientLine() -> String {
            // User preference: single string with a space between name and quantity/unit, e.g. "Cheese 1kg"
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let q = quantity?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let u = unit?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

            guard let q else { return n }
            if let u {
                return "\(n) \(q)\(u)"
            }
            return "\(n) \(q)"
        }
    }

    struct RecipeImportDraft: Codable, Hashable {
        var sourceURL: URL?
        var name: String
        var ingredients: [ImportedIngredient]
        var instructions: String

        /// Image URL for preview + later save
        var imageURL: URL?

        var hasMinimumToImport: Bool {
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !ingredients.isEmpty
        }
    }

    enum ImportError: LocalizedError {
        case invalidURL
        case network(String)
        case parse(String)
        case noRecipeFound

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid URL"
            case .network(let msg): return "Network error: \(msg)"
            case .parse(let msg): return "Parse error: \(msg)"
            case .noRecipeFound: return "No recipe found on that page"
            }
        }
    }

    // MARK: - Published

    @Published var urlText: String = ""
    @Published var isLoading: Bool = false
    @Published var loadingMessage: String = ""
    @Published var errorMessage: String?
    @Published var draft: RecipeImportDraft?

    /// Hero image downloaded in parallel with parsing so the wizard can show it
    /// without a second network round-trip. Cleared on `clear()`.
    @Published var prefetchedImage: UIImage?

    // MARK: - Config (App Group inbox)

    static let appGroupID = "group.Clark-Online.FrydgeRecipeAPN"
    static let inboxFilename = "recipe_import_inbox.json"

    // MARK: - Dedicated URLSession

    /// Dedicated session for recipe imports. Configured for low-latency single-page
    /// fetches without polluting the shared cache.
    nonisolated private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        // Import pages can carry large JSON-LD and hero images, so keep a larger
        // short-lived cache for retries without forcing another network pass.
        config.urlCache = URLCache(memoryCapacity: 24 * 1024 * 1024,
                                   diskCapacity: 128 * 1024 * 1024,
                                   diskPath: "frydge-recipe-import")
        return URLSession(configuration: config)
    }()

    nonisolated private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// In-flight image prefetch (cancelled when a new fetch starts)
    private var imagePrefetchTask: Task<Void, Never>?

    // MARK: - Public API

    func setURL(_ url: URL) {
        urlText = url.absoluteString
    }

    func clear() {
        errorMessage = nil
        loadingMessage = ""
        draft = nil
        isLoading = false
        prefetchedImage = nil
        imagePrefetchTask?.cancel()
        imagePrefetchTask = nil
    }

    func fetchAndParse() async {
        errorMessage = nil
        draft = nil
        prefetchedImage = nil
        imagePrefetchTask?.cancel()
        imagePrefetchTask = nil

        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.hasPrefix("http") == true else {
            errorMessage = ImportError.invalidURL.localizedDescription
            return
        }

        isLoading = true
        loadingMessage = "Fetching recipe page..."
        defer { isLoading = false }

        do {
            let html = try await Self.fetchHTML(url: url)
            loadingMessage = "Reading ingredients and method..."
            let (parsed, captionText) = try await Task.detached(priority: .userInitiated) {
                try Self.parseRecipe(fromHTML: html, sourceURL: url)
            }.value

            self.draft = await Self.bestDraft(
                parsed: parsed,
                captionText: captionText,
                sourceURL: url,
                statusUpdate: { [weak self] message in self?.loadingMessage = message }
            )

            if let imageURL = self.draft?.imageURL {
                let capturedURL = imageURL
                imagePrefetchTask = Task { [weak self] in
                    let image = await Self.downloadImage(from: capturedURL)
                    guard let self, !Task.isCancelled else { return }
                    if self.draft?.imageURL == capturedURL {
                        self.prefetchedImage = image
                    }
                }
            }
        } catch {
            self.errorMessage = error.localizedDescription
            self.loadingMessage = ""
        }
    }

    /// Instagram and TikTok (and most SPA-rendered pages) never ship a
    /// `Recipe` JSON-LD block and don't server-render a body, so the
    /// structured/naive scrape in `parseRecipe` comes back with a title and
    /// hero image but no ingredients or steps — the actual recipe lives in
    /// the post caption. When that happens, hand the caption (captured from
    /// `og:description` during parsing) to the on-device model that already
    /// splits pasted text and video transcripts into a draft.
    private static func bestDraft(
        parsed: RecipeImportDraft,
        captionText: String?,
        sourceURL: URL,
        statusUpdate: (String) -> Void
    ) async -> RecipeImportDraft {
        let isStructurallyEmpty = parsed.ingredients.isEmpty
            && parsed.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard isStructurallyEmpty,
              let captionText, !captionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusUpdate("Preparing confirmation windows...")
            return parsed
        }

        statusUpdate("No recipe data on the page — reading the caption...")
        guard let aiDraft = await RecipeImportAI.makeDraft(from: captionText) else {
            statusUpdate("Preparing confirmation windows...")
            return parsed
        }

        statusUpdate("Preparing confirmation windows...")
        return RecipeImportDraft(
            sourceURL: sourceURL,
            name: aiDraft.name == "Imported Recipe" ? parsed.name : aiDraft.name,
            ingredients: aiDraft.ingredients,
            instructions: aiDraft.instructions,
            imageURL: parsed.imageURL ?? aiDraft.imageURL
        )
    }

    // MARK: - Networking

    nonisolated private static func fetchHTML(url: URL) async throws -> String {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                     forHTTPHeaderField: "Accept")

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw ImportError.network("No HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw ImportError.network("HTTP \(http.statusCode)")
            }
            if let s = String(data: data, encoding: .utf8) { return s }
            if let s = String(data: data, encoding: .isoLatin1) { return s }
            throw ImportError.network("Unsupported text encoding")
        } catch let e as ImportError {
            throw e
        } catch {
            throw ImportError.network(error.localizedDescription)
        }
    }

    nonisolated private static func downloadImage(from url: URL) async -> UIImage? {
        // Keep the browser-style User-Agent (recipe-site CDNs often reject
        // app agents) but use the shared image session so the download waits
        // for connectivity, and decode downsampled so a 6000 px hero photo
        // doesn't become a 100 MB bitmap.
        var req = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 25)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        for attempt in 0..<2 {
            do {
                let (data, response) = try await RemoteImageFetcher.session.data(for: req)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    if attempt == 0, http.statusCode == 429 || http.statusCode >= 500 {
                        try? await Task.sleep(for: .seconds(1.5))
                        continue
                    }
                    return nil
                }
                return RemoteImageFetcher.decodeDownsampled(data)
            } catch {
                if attempt == 0 { try? await Task.sleep(for: .seconds(1.5)); continue }
                return nil
            }
        }
        return nil
    }

    // MARK: - Parsing (SwiftSoup + Schema.org JSON-LD)

    nonisolated private static func parseRecipe(fromHTML html: String, sourceURL: URL) throws -> (draft: RecipeImportDraft, captionText: String?) {
        let document: Document
        do {
            document = try SwiftSoup.parse(html, sourceURL.absoluteString)
        } catch {
            throw ImportError.parse("Failed to parse HTML")
        }

        // 1) JSON-LD first — already structured, no caption fallback needed.
        if let jsonLDObjects = extractJSONLDObjects(from: document),
           let recipeDict = findRecipeObject(in: jsonLDObjects),
           let draft = makeDraft(fromRecipeObject: recipeDict, sourceURL: sourceURL, document: document) {
            return (draft, nil)
        }

        // 2) Fallback: title + naive ingredients + OG image. Social platforms
        // (Instagram, TikTok) don't server-render a body, so this usually
        // comes back with no ingredients/instructions — keep the caption
        // text alongside so the caller can try the on-device model on it.
        if let fallback = fallbackParse(document: document, sourceURL: sourceURL) {
            return (fallback, extractMetaCaptionText(from: document))
        }

        throw ImportError.noRecipeFound
    }

    nonisolated private static func extractJSONLDObjects(from document: Document) -> [Any]? {
        guard let scripts = try? document.select("script[type=application/ld+json]") else { return nil }
        var results: [Any] = []
        for s in scripts.array() {
            let raw = s.data()
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty,
                  let data = cleaned.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                continue
            }
            results.append(obj)
        }
        return results.isEmpty ? nil : results
    }

    nonisolated private static func findRecipeObject(in jsonLDObjects: [Any]) -> [String: Any]? {
        for obj in jsonLDObjects {
            if let dict = obj as? [String: Any] {
                if let r = recipeDictIfRecipe(dict) { return r }
                if let graph = dict["@graph"] as? [Any] {
                    for g in graph {
                        if let gd = g as? [String: Any], let r = recipeDictIfRecipe(gd) { return r }
                    }
                }
            } else if let arr = obj as? [Any] {
                for a in arr {
                    if let d = a as? [String: Any], let r = recipeDictIfRecipe(d) { return r }
                }
            }
        }
        return nil
    }

    nonisolated private static func recipeDictIfRecipe(_ dict: [String: Any]) -> [String: Any]? {
        if let t = dict["@type"] as? String {
            if t.lowercased().contains("recipe") { return dict }
        } else if let ts = dict["@type"] as? [Any] {
            if ts.contains(where: { "\($0)".lowercased().contains("recipe") }) { return dict }
        }
        return nil
    }

    nonisolated private static func makeDraft(fromRecipeObject recipe: [String: Any], sourceURL: URL, document: Document) -> RecipeImportDraft? {
        let name = (recipe["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let ingredientLines: [String] = {
            if let arr = recipe["recipeIngredient"] as? [Any] {
                return arr.compactMap { $0 as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            if let arr = recipe["ingredients"] as? [Any] {
                return arr.compactMap { $0 as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            return []
        }()

        let importedIngredients = ingredientLines.map { parseIngredientLine($0) }
        let instructionsText = extractInstructions(fromRecipeObject: recipe)
        let imageURL = extractImageURL(fromRecipeObject: recipe, sourceURL: sourceURL)
            ?? extractOGImageURL(from: document, sourceURL: sourceURL)

        if name.isEmpty && importedIngredients.isEmpty && instructionsText.isEmpty {
            return nil
        }

        return RecipeImportDraft(
            sourceURL: sourceURL,
            name: name.isEmpty ? "Imported Recipe" : name,
            ingredients: importedIngredients,
            instructions: instructionsText,
            imageURL: imageURL
        )
    }

    /// Some sites put raw HTML (`<p>`, `<li>`, `<br>`) inside JSON-LD text
    /// fields. Turn block breaks into newlines and drop the remaining tags so
    /// the steps come out as clean lines rather than one tag-filled blob.
    nonisolated private static func plainTextLines(fromHTMLish s: String) -> [String] {
        var t = s.replacingOccurrences(
            of: #"<\s*(br|/p|/li|/div|/h\d)\s*/?>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        return t.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated private static func extractInstructions(fromRecipeObject recipe: [String: Any]) -> String {
        func flatten(_ obj: Any) -> [String] {
            if let s = obj as? String {
                return plainTextLines(fromHTMLish: s)
            }
            if let d = obj as? [String: Any] {
                if let t = d["text"] as? String {
                    return plainTextLines(fromHTMLish: t)
                }
                if let itemList = d["itemListElement"] as? [Any] {
                    return itemList.flatMap { flatten($0) }
                }
                if let steps = d["steps"] as? [Any] {
                    return steps.flatMap { flatten($0) }
                }
            }
            if let a = obj as? [Any] {
                return a.flatMap { flatten($0) }
            }
            return []
        }

        guard let raw = recipe["recipeInstructions"] else { return "" }
        let lines = flatten(raw)
        if lines.isEmpty { return "" }
        return lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    // MARK: - Image extraction

    nonisolated private static func extractImageURL(fromRecipeObject recipe: [String: Any], sourceURL: URL) -> URL? {
        guard let raw = recipe["image"] else { return nil }

        func asURL(_ s: String) -> URL? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            if let u = URL(string: t), u.scheme != nil { return u }
            return URL(string: t, relativeTo: sourceURL)?.absoluteURL
        }

        if let s = raw as? String { return asURL(s) }

        if let arr = raw as? [Any] {
            for item in arr {
                if let s = item as? String, let u = asURL(s) { return u }
                if let d = item as? [String: Any],
                   let s = (d["url"] as? String) ?? (d["@id"] as? String),
                   let u = asURL(s) { return u }
            }
        }

        if let d = raw as? [String: Any] {
            if let s = (d["url"] as? String) ?? (d["@id"] as? String) {
                return asURL(s)
            }
        }

        return nil
    }

    nonisolated private static func extractOGImageURL(from document: Document, sourceURL: URL) -> URL? {
        let selectors = [
            #"meta[property=og:image]"#,
            #"meta[property=og:image:url]"#,
            #"meta[name=twitter:image]"#,
            #"meta[name=twitter:image:src]"#
        ]
        for selector in selectors {
            if let element = try? document.select(selector).first(),
               let content = try? element.attr("content") {
                let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                if let u = URL(string: t), u.scheme != nil { return u }
                if let u = URL(string: t, relativeTo: sourceURL)?.absoluteURL { return u }
            }
        }
        return nil
    }

    // MARK: - Social caption extraction (Instagram/TikTok)

    /// Instagram/TikTok's `<title>` is often just "Username on Instagram" with
    /// no recipe content; `og:title` usually carries the actual post text.
    nonisolated private static func extractOGTitle(from document: Document) -> String? {
        guard let element = try? document.select(#"meta[property=og:title]"#).first(),
              let content = try? element.attr("content") else { return nil }
        return decodeHTMLEntities(content).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// The post caption — where Instagram/TikTok recipe accounts actually
    /// write the ingredients and method — is rendered server-side into the
    /// link-preview meta tags even though the rest of the page is a JS shell.
    nonisolated private static func extractMetaCaptionText(from document: Document) -> String? {
        let selectors = [
            #"meta[property=og:description]"#,
            #"meta[name=twitter:description]"#,
            #"meta[name=description]"#
        ]
        for selector in selectors {
            if let element = try? document.select(selector).first(),
               let content = try? element.attr("content") {
                if let text = decodeHTMLEntities(content).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                    return text
                }
            }
        }
        return nil
    }

    nonisolated private static func decodeHTMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
    }

    // MARK: - Fallback parsing

    nonisolated private static func fallbackParse(document: Document, sourceURL: URL) -> RecipeImportDraft? {
        let title = extractOGTitle(from: document)
            ?? ((try? document.title()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Imported Recipe"
        let ingredients = naiveIngredientLines(from: document).map { parseIngredientLine($0) }
        let imageURL = extractOGImageURL(from: document, sourceURL: sourceURL)
        let instructionLines = naiveInstructionLines(from: document)
        let instructions = instructionLines.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        return RecipeImportDraft(
            sourceURL: sourceURL,
            name: title,
            ingredients: ingredients,
            instructions: instructions,
            imageURL: imageURL
        )
    }

    /// Best-effort method extraction for pages without JSON-LD, so an import
    /// doesn't arrive with an empty Instructions step. Specific recipe-markup
    /// selectors first; a bare ordered list only as a last resort.
    nonisolated private static func naiveInstructionLines(from document: Document) -> [String] {
        let selectors = [
            "[itemprop=recipeInstructions] li",
            "[itemprop=recipeInstructions] p",
            "[itemprop=recipeInstructions]",
            ".recipe-instructions li",
            ".recipe-instruction",
            ".instructions li",
            ".instruction",
            ".recipe-method li",
            ".method li",
            ".recipe-directions li",
            ".directions li",
            ".wprm-recipe-instruction-text",
            ".tasty-recipes-instructions li",
            "ol li"
        ]
        for selector in selectors {
            guard let nodes = try? document.select(selector), nodes.size() > 0 else { continue }
            let lines = nodes.array()
                .compactMap { try? $0.text() }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 12 }
            // A generic ordered list is only trusted when it reads like a method.
            let minimum = selector == "ol li" ? 2 : 1
            if lines.count >= minimum { return lines }
        }
        return []
    }

    nonisolated private static func naiveIngredientLines(from document: Document) -> [String] {
        // Try common ingredient list selectors first
        let listSelectors = [
            "[itemprop=recipeIngredient]",
            ".recipe-ingredient",
            ".ingredient",
            ".ingredients li",
            "ul.ingredients li"
        ]
        for selector in listSelectors {
            if let nodes = try? document.select(selector), nodes.size() > 0 {
                let lines = nodes.array().compactMap { try? $0.text() }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !lines.isEmpty { return lines }
            }
        }

        // Last-ditch: scan body text for plausible ingredient lines
        guard let body = try? document.body()?.text() else { return [] }
        let lines = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count < 120 }

        if let idx = lines.firstIndex(where: { $0.lowercased().contains("ingredients") }) {
            let start = min(idx + 1, lines.count)
            let end = min(start + 40, lines.count)
            return Array(lines[start..<end]).filter { looksLikeIngredientLine($0) }
        }
        return lines.filter { looksLikeIngredientLine($0) }.prefix(25).map { $0 }
    }

    nonisolated private static func looksLikeIngredientLine(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3 else { return false }
        let lower = t.lowercased()
        if lower.hasPrefix("•") || lower.hasPrefix("-") { return true }
        if lower.first?.isNumber == true { return true }
        if lower.contains(" tbsp") || lower.contains(" tsp") { return true }
        if lower.contains(" g") || lower.contains(" kg") || lower.contains(" ml") || lower.contains(" l ") { return true }
        return false
    }

    // MARK: - Ingredient parsing (best-effort)

    /// Exposed internally so RecipeImportOCRParser can reuse the same parsing logic.
    nonisolated static func parseIngredientLine(_ line: String) -> ImportedIngredient {
        let original = line
            .replacingOccurrences(of: "•", with: "")
            .replacingOccurrences(of: "–", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let cleaned = original
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var tokens = cleaned.split(separator: " ").map(String.init)
        if tokens.isEmpty {
            return ImportedIngredient(name: "", quantity: nil, unit: nil, originalLine: original)
        }

        let quantity = extractLeadingQuantity(from: &tokens)

        // "fl oz" is a two-token unit; check before the generic single-token lookup
        var unit: String?
        if tokens.first?.lowercased() == "fl",
           tokens.dropFirst().first?.lowercased().hasPrefix("oz") == true {
            unit = "fl oz"
            tokens.removeFirst(2)
        } else {
            unit = tokens.first.flatMap { normalizeUnit($0) }
            if unit != nil { tokens.removeFirst() }
        }

        // Build name, stopping before any parenthetical note such as "(diced)" or "(optional)"
        var nameParts: [String] = []
        for token in tokens {
            if token.hasPrefix("(") { break }
            nameParts.append(token)
        }
        var name = nameParts
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ",:;."))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = cleaned }

        let (finalQty, finalUnit) = localizeUnits(quantity: quantity, unit: unit)
        return ImportedIngredient(name: name, quantity: finalQty, unit: finalUnit, originalLine: original)
    }

    /// Removes and returns a leading numeric quantity from `tokens`.
    /// Handles integers, decimals, ASCII fractions (1/2), unicode fractions (½),
    /// mixed numbers (1 1/2), and ranges (2-3 → lower bound).
    nonisolated private static func extractLeadingQuantity(from tokens: inout [String]) -> String? {
        guard let first = tokens.first, let firstValue = parseQuantityToken(first) else { return nil }
        tokens.removeFirst()
        // Mixed number: "1 1/2" — the next token is an ASCII fraction
        if let second = tokens.first,
           second.contains("/"), !second.hasPrefix("/"),
           let fracValue = parseASCIIFraction(second) {
            tokens.removeFirst()
            return formatQuantity(firstValue + fracValue)
        }
        return formatQuantity(firstValue)
    }

    nonisolated private static func parseQuantityToken(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        let unicodeFractions: [Character: Double] = [
            "½": 0.5,  "⅓": 1.0 / 3.0, "⅔": 2.0 / 3.0,
            "¼": 0.25, "¾": 0.75,
            "⅛": 0.125, "⅜": 0.375, "⅝": 0.625, "⅞": 0.875,
            "⅕": 0.2, "⅖": 0.4, "⅗": 0.6, "⅘": 0.8
        ]

        // Single unicode fraction character: "½"
        if t.unicodeScalars.count == 1, let c = t.first, let v = unicodeFractions[c] { return v }

        // Mixed unicode: "1½" — digit prefix followed by a unicode fraction character
        if let last = t.last, let fracVal = unicodeFractions[last] {
            let prefix = String(t.dropLast())
            if let whole = Double(prefix) { return whole + fracVal }
        }

        // Range like "2-3" — use the lower bound
        if t.contains("-"), !t.hasPrefix("-") {
            let parts = t.split(separator: "-")
            if parts.count == 2, let lo = Double(parts[0]), lo > 0 { return lo }
        }

        if let d = Double(t) { return d }
        return parseASCIIFraction(t)
    }

    nonisolated private static func parseASCIIFraction(_ s: String) -> Double? {
        let parts = s.split(separator: "/")
        guard parts.count == 2,
              let num = Double(parts[0]),
              let den = Double(parts[1]),
              den != 0 else { return nil }
        return num / den
    }

    nonisolated private static func parseQuantityValue(_ s: String) -> Double? {
        if let d = Double(s) { return d }
        return parseASCIIFraction(s)
    }

    nonisolated private static func formatQuantity(_ d: Double) -> String {
        if d.truncatingRemainder(dividingBy: 1) == 0 { return String(Int(d)) }
        let rounded = (d * 10).rounded() / 10
        let str = String(format: "%.1f", rounded)
        return str.hasSuffix(".0") ? String(Int(rounded)) : str
    }

    /// Converts US/imperial volume and weight units to metric when the device locale uses metric.
    /// tsp and tbsp are kept as-is since they're universally used in metric kitchens.
    nonisolated private static func localizeUnits(quantity: String?, unit: String?) -> (quantity: String?, unit: String?) {
        guard let unit,
              Locale.current.measurementSystem == .metric,
              let qStr = quantity,
              let qValue = parseQuantityValue(qStr) else {
            return (quantity, unit)
        }
        switch unit.lowercased() {
        case "cup":
            return (formatQuantity(qValue * 240), "ml")
        case "fl oz":
            return (formatQuantity(qValue * 29.574), "ml")
        case "oz":
            let g = qValue * 28.35
            return g >= 1000 ? (formatQuantity(g / 1000), "kg") : (formatQuantity(g), "g")
        case "lb":
            let g = qValue * 453.6
            return g >= 1000 ? (formatQuantity(g / 1000), "kg") : (formatQuantity(g), "g")
        default:
            return (quantity, unit)
        }
    }

    nonisolated private static func normalizeUnit(_ raw: String) -> String? {
        let t = raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()[]{}"))
        switch t {
        case "g", "gram", "grams":                     return "g"
        case "kg", "kilogram", "kilograms":             return "kg"
        case "mg":                                      return "mg"
        case "ml", "milliliter", "milliliters",
             "millilitre", "millilitres":               return "ml"
        case "l", "liter", "liters",
             "litre", "litres":                         return "l"
        case "cl":                                      return "cl"
        case "tsp", "teaspoon", "teaspoons":            return "tsp"
        case "tbsp", "tablespoon", "tablespoons", "tb": return "tbsp"
        case "cup", "cups", "c":                       return "cup"
        case "oz", "ounce", "ounces":                  return "oz"
        case "lb", "lbs", "pound", "pounds":           return "lb"
        case "pinch", "pinches":                       return "pinch"
        case "slice", "slices":                        return "slice"
        case "can", "cans":                            return "can"
        case "pack", "packs", "packet", "packets":     return "pack"
        case "bunch", "bunches":                       return "bunch"
        case "clove", "cloves":                        return "clove"
        case "sprig", "sprigs":                        return "sprig"
        case "handful", "handfuls":                    return "handful"
        case "piece", "pieces":                        return "piece"
        case "head", "heads":                          return "head"
        case "stalk", "stalks":                        return "stalk"
        case "sheet", "sheets":                        return "sheet"
        case "fillet", "fillets":                      return "fillet"
        default:                                        return nil
        }
    }

    // MARK: - App Group Inbox (Share Extension -> App)
    //
    // Thin shims kept for the deep-link handler; the store itself lives in
    // `RecipeImportInbox` so the import window reads the same files.

    static func readInboxURLAndClear() -> URL? {
        RecipeImportInbox.popFirstURL()
    }

    static func peekInboxURL() -> URL? {
        RecipeImportInbox.peekFirstURL()
    }
}

// MARK: - Small helpers

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
