//
//  RemoteImageFetcher.swift
//  FrydgeRecipes
//
//  The one place every remote image download goes through.
//
//  Why this exists: App Review repeatedly reported "images don't load". The
//  photo pipeline had four independent weaknesses that each produce exactly
//  that symptom on a fresh device with a flaky or slow connection:
//
//    1. No retry. A single timeout, 429 or 5xx (Wikimedia rate-limits shared
//       IPs such as Apple's review network) left the placeholder up for good.
//    2. No "wait for connectivity". Requests fired during launch, before the
//       network path was up, failed instantly and were never re-attempted.
//    3. Full-size originals. Wikimedia Commons originals are often 5-20 MB
//       and up to 8000 px wide; decoding dozens of those for list cards is
//       slow on a good network and a jetsam crash on a bad day.
//    4. `AsyncImage` everywhere, which has none of the above and no disk cache.
//
//  This fetcher fixes all four: a dedicated URLSession (waits for
//  connectivity, bigger URLCache), bounded retries with back-off that honour
//  Retry-After, Wikimedia thumbnail URLs with an automatic fall-back to the
//  original, ImageIO downsampling so decoded bitmaps stay small, and a
//  memory + disk cache keyed by URL. `CachedAsyncImage` at the bottom is a
//  drop-in replacement for `AsyncImage(url:) { phase in }`.
//

import SwiftUI
import UIKit
import ImageIO
import CryptoKit
import os

nonisolated enum RemoteImageFetcher {

    private static let log = Logger(subsystem: "com.Clark-Online.Recipes", category: "RemoteImage")

    /// Largest edge, in pixels, that a decoded remote image is allowed to
    /// have. Cards and headers never exceed ~1300 px on a 3x device.
    static let maxPixelSize: CGFloat = 1600

    /// Wikimedia thumbnail width requested before falling back to the original.
    /// Must be one of Wikimedia's standard steps (20, 40, 60, 120, 250, 330,
    /// 500, 960, 1280, 1920, 3840) — hot-linked thumbnails at any other width
    /// are rejected with HTTP 400. See mediawiki.org/wiki/Common_thumbnail_sizes.
    static let wikimediaThumbnailWidth = 1280

    enum FetchError: Error {
        case badStatus(Int)
        case notAnImage
        case noCandidates
    }

    // MARK: - Session

    /// Shared session for image bytes. Separate from `URLSession.shared` so
    /// the cache is sized for photos and so requests wait for connectivity
    /// instead of failing during the first second after launch.
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 90
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .returnCacheDataElseLoad
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("remote-image-urlcache", isDirectory: true)
        config.urlCache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024,
            directory: cacheDir
        )
        return URLSession(configuration: config)
    }()

    /// Wikimedia's User-Agent policy asks apps to identify themselves; generic
    /// or empty agents get 403/429 from shared IP ranges. Only sent to
    /// Wikimedia hosts so retailer CDNs keep seeing the default CFNetwork agent.
    private static let wikimediaUserAgent: String = {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let build = (info?["CFBundleVersion"] as? String) ?? "1"
        return "Frydge/\(version).\(build) (iOS recipe app; App Store; https://apps.apple.com) CFNetwork"
    }()

    private static func isWikimedia(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.hasSuffix("wikimedia.org") || host.hasSuffix("wikipedia.org")
    }

    // MARK: - Public API

    /// Memory-cache lookup only. Cheap enough to call from a view body so a
    /// previously shown image appears without a placeholder flash.
    static func cachedImage(for url: URL) -> UIImage? {
        memoryCache.object(forKey: url.absoluteString as NSString)
    }

    /// Memory → disk → network, with the network leg retried and (for
    /// Wikimedia) served as a thumbnail when possible. Returns nil only after
    /// everything has been tried; permanent failures (404 etc.) are remembered
    /// for the life of the process so lists don't hammer a dead URL.
    static func image(for url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let hit = memoryCache.object(forKey: key) { return hit }

        let diskPath = diskURL(for: url)
        if let fromDisk = decodeDownsampled(contentsOf: diskPath) {
            store(fromDisk, forKey: key)
            return fromDisk
        }

        if state.isPermanentlyFailed(url) { return nil }

        do {
            let image = try await fetchImage(candidates: wikimediaCandidates(for: url))
            store(image, forKey: key)
            writeToDisk(image, at: diskPath)
            return image
        } catch FetchError.badStatus(let code) where isPermanentStatus(code) {
            state.markPermanentlyFailed(url)
            log.notice("Giving up on \(url.absoluteString, privacy: .public): HTTP \(code)")
            return nil
        } catch FetchError.notAnImage {
            state.markPermanentlyFailed(url)
            log.notice("Not an image: \(url.absoluteString, privacy: .public)")
            return nil
        } catch {
            log.notice("Transient failure for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Downloads and decodes a single URL (with retries). Throws on failure.
    static func fetchImage(from url: URL, maxPixelSize: CGFloat = maxPixelSize) async throws -> UIImage {
        let (data, _) = try await data(from: url)
        guard let image = decodeDownsampled(data, maxPixelSize: maxPixelSize) else {
            throw FetchError.notAnImage
        }
        return image
    }

    /// Tries each candidate in order and returns the first that yields a
    /// decodable image. A Wikimedia thumbnail that answers 400 (source smaller
    /// than the requested width) or 404 simply falls through to the original.
    static func fetchImage(candidates: [URL], maxPixelSize: CGFloat = maxPixelSize) async throws -> UIImage {
        guard !candidates.isEmpty else { throw FetchError.noCandidates }
        var lastError: Error = FetchError.noCandidates
        for candidate in candidates {
            try Task.checkCancellation()
            do {
                return try await fetchImage(from: candidate, maxPixelSize: maxPixelSize)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Raw bytes with bounded retry. Retries on transient URL errors and on
    /// 408/425/429/5xx, honouring Retry-After (capped). Other 4xx throw at once.
    static func data(from url: URL, attempts: Int = 3) async throws -> (Data, HTTPURLResponse?) {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 25)
        request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if isWikimedia(url) {
            request.setValue(wikimediaUserAgent, forHTTPHeaderField: "User-Agent")
        }

        var lastError: Error = URLError(.unknown)
        for attempt in 0..<max(1, attempts) {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { return (data, nil) }
                if (200..<300).contains(http.statusCode) { return (data, http) }

                if isRetryableStatus(http.statusCode), attempt < attempts - 1 {
                    let delay = retryDelay(attempt: attempt, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                throw FetchError.badStatus(http.statusCode)
            } catch let error as URLError where isTransient(error) && attempt < attempts - 1 {
                lastError = error
                try await Task.sleep(for: .seconds(retryDelay(attempt: attempt, retryAfter: nil)))
            }
        }
        throw lastError
    }

    // MARK: - Wikimedia URLs

    /// For a Commons original (`/wikipedia/commons/a/ab/File.jpg`) returns
    /// `[thumbnail, original]`; anything else returns `[url]`. Thumbnails are
    /// ~10x smaller and served straight from Wikimedia's edge cache.
    static func wikimediaCandidates(for url: URL, width: Int = wikimediaThumbnailWidth) -> [URL] {
        guard url.host?.lowercased() == "upload.wikimedia.org" else { return [url] }
        let parts = url.pathComponents   // ["/", "wikipedia", "commons", "6", "67", "File.jpg"]
        guard parts.count == 6,
              parts[1] == "wikipedia",
              parts[3].count == 1,
              parts[4].count == 2 else { return [url] }

        let file = parts[5]
        let ext = (file as NSString).pathExtension.lowercased()
        let thumbName: String
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp": thumbName = "\(width)px-\(file)"
        case "svg":                                thumbName = "\(width)px-\(file).png"
        case "djvu", "pdf":                        thumbName = "page1-\(width)px-\(file).jpg"
        case "tif", "tiff":                        thumbName = "lossy-page1-\(width)px-\(file).jpg"
        default:                                   return [url]
        }

        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "upload.wikimedia.org"
        comps.path = "/\(parts[1])/\(parts[2])/thumb/\(parts[3])/\(parts[4])/\(file)/\(thumbName)"
        guard let thumb = comps.url else { return [url] }
        return [thumb, url]
    }

    // MARK: - Decoding

    /// ImageIO downsampling: decodes straight to a bitmap no larger than
    /// `maxPixelSize` on its longest edge, without ever materialising the
    /// full-resolution image. Returns nil for data that isn't an image.
    static func decodeDownsampled(_ data: Data, maxPixelSize: CGFloat = maxPixelSize) -> UIImage? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return thumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    static func decodeDownsampled(contentsOf fileURL: URL, maxPixelSize: CGFloat = maxPixelSize) -> UIImage? {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let source = CGImageSourceCreateWithURL(fileURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return thumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    private static func thumbnail(from source: CGImageSource, maxPixelSize: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Caches

    private static let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 120 * 1024 * 1024
        return cache
    }()

    private static func store(_ image: UIImage, forKey key: NSString) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale) * 4
        memoryCache.setObject(image, forKey: key, cost: cost)
    }

    private static let diskDirectory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("remote-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func diskURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appendingPathComponent(name).appendingPathExtension("jpg")
    }

    private static func writeToDisk(_ image: UIImage, at fileURL: URL) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    /// Process-lifetime record of URLs that answered with a permanent error.
    private final class FailureState: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = Set<String>()

        func isPermanentlyFailed(_ url: URL) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return failed.contains(url.absoluteString)
        }

        func markPermanentlyFailed(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            failed.insert(url.absoluteString)
        }
    }

    private static let state = FailureState()

    // MARK: - Retry policy

    private static func isRetryableStatus(_ code: Int) -> Bool {
        code == 408 || code == 425 || code == 429 || (500...599).contains(code)
    }

    private static func isPermanentStatus(_ code: Int) -> Bool {
        (400...499).contains(code) && !isRetryableStatus(code)
    }

    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
             .dnsLookupFailed, .cannotFindHost, .resourceUnavailable, .badServerResponse,
             .secureConnectionFailed, .internationalRoamingOff, .callIsActive, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    private static func retryDelay(attempt: Int, retryAfter: String?) -> Double {
        let base: [Double] = [0.8, 2.0, 4.5]
        let scheduled = base[min(attempt, base.count - 1)]
        if let retryAfter, let seconds = Double(retryAfter.trimmingCharacters(in: .whitespaces)) {
            return min(max(seconds, scheduled), 10)
        }
        return scheduled
    }
}

// MARK: - CachedAsyncImage

/// Drop-in replacement for `AsyncImage(url:) { phase in ... }` backed by
/// `RemoteImageFetcher`: retries, waits for connectivity, downsampled
/// decoding, memory + disk cache, Wikimedia thumbnails. Same `AsyncImagePhase`
/// closure, so call sites only change the type name.
struct CachedAsyncImage<Content: View>: View {
    private let url: URL?
    private let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty
    @State private var loadedURL: URL?

    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
    }

    var body: some View {
        content(displayedPhase)
            .task(id: url) { await load() }
    }

    /// Serve a memory-cached image synchronously so re-appearing rows never
    /// flash their placeholder.
    private var displayedPhase: AsyncImagePhase {
        if let url, loadedURL != url || isEmpty(phase),
           let cached = RemoteImageFetcher.cachedImage(for: url) {
            return .success(Image(uiImage: cached))
        }
        if let url, loadedURL != url { return .empty }
        return phase
    }

    private func isEmpty(_ phase: AsyncImagePhase) -> Bool {
        if case .empty = phase { return true }
        return false
    }

    private func load() async {
        guard let url else {
            phase = .empty
            loadedURL = nil
            return
        }
        if let cached = RemoteImageFetcher.cachedImage(for: url) {
            phase = .success(Image(uiImage: cached))
            loadedURL = url
            return
        }
        phase = .empty
        loadedURL = url
        let image = await RemoteImageFetcher.image(for: url)
        guard !Task.isCancelled else { return }
        if let image {
            phase = .success(Image(uiImage: image))
        } else {
            phase = .failure(URLError(.cannotLoadFromNetwork))
        }
    }
}
