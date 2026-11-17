//
//  ShareViewController.swift
//  FrydgeRecipesImportExtension
//
//  Created by Josh on 10/01/2026.
//

import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        handleSharedContentAndExit()
    }

    private func handleSharedContentAndExit() {
        guard let inputItems = extensionContext?.inputItems, !inputItems.isEmpty else {
            NSLog("[EXT] ❌ No inputItems")
            complete()
            return
        }

        var providers: [NSItemProvider] = []
        for item in inputItems {
            if let extItem = item as? NSExtensionItem, let att = extItem.attachments {
                providers.append(contentsOf: att)
            }
        }

        guard !providers.isEmpty else {
            NSLog("[EXT] ❌ No attachments/providers")
            complete()
            return
        }

        let urlType = UTType.url.identifier
        let textType = UTType.plainText.identifier
        let utf8TextType = UTType.utf8PlainText.identifier
        let movieType = UTType.movie.identifier

        for (idx, p) in providers.enumerated() {
            NSLog("[EXT] provider[\(idx)] types=\(p.registeredTypeIdentifiers)")
        }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(urlType) }) {
            loadURL(from: provider)
            return
        }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(textType) }) {
            loadText(from: provider)
            return
        }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(utf8TextType) }) {
            loadText(from: provider)
            return
        }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(movieType) }) {
            loadVideo(from: provider, typeIdentifier: movieType)
            return
        }

        NSLog("[EXT] ❌ No URL, text, or video provider found")
        complete()
    }

    private func loadVideo(from provider: NSItemProvider, typeIdentifier: String) {
        // The temporary file is deleted as soon as this completion handler returns,
        // so `enqueueVideoAndExit` must copy it synchronously before returning.
        _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
            guard let self else { return }

            if let error {
                NSLog("[EXT] ❌ loadVideo error=\(String(describing: error))")
                self.completeOnMain()
                return
            }

            guard let src = url else {
                NSLog("[EXT] ❌ loadVideo: no file URL returned")
                self.completeOnMain()
                return
            }

            NSLog("[EXT] ✅ Got video at \(src.path)")
            self.enqueueVideoAndExit(src)
        }
    }

    private func enqueueVideoAndExit(_ srcURL: URL) {
        guard let folder = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: RecipeImportInboxQueue.appGroupID
        ) else {
            NSLog("[EXT] ❌ AppGroup folder not found")
            completeOnMain()
            return
        }

        let ext = srcURL.pathExtension.isEmpty ? "mp4" : srcURL.pathExtension
        let videoFilename = "pending_recipe_video.\(ext)"
        let dstURL = folder.appendingPathComponent(videoFilename)
        let metaURL = folder.appendingPathComponent("pending_recipe_video_meta.json")

        do {
            try? FileManager.default.removeItem(at: dstURL)
            try FileManager.default.copyItem(at: srcURL, to: dstURL)

            let meta: [String: String] = [
                "videoPath": videoFilename,
                "createdAt": ISO8601DateFormatter().string(from: Date())
            ]
            let metaData = try JSONSerialization.data(withJSONObject: meta)
            try metaData.write(to: metaURL, options: .atomic)

            NSLog("[EXT] ✅ Video queued at \(dstURL.path)")
        } catch {
            NSLog("[EXT] ❌ Failed to copy video: \(String(describing: error))")
            completeOnMain()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let appURL = URL(string: "frydgerecipes://import-video") else {
                self.completeOnMain()
                return
            }
            self.extensionContext?.open(appURL) { didOpen in
                if didOpen || self.openAppViaResponderChain(appURL) {
                    NSLog("[EXT] ✅ Requested app open for video import")
                } else {
                    NSLog("[EXT] ⚠️ Could not open app; video import remains queued")
                }
                self.completeOnMain()
            }
        }
    }

    private func loadURL(from provider: NSItemProvider) {
        _ = provider.loadObject(ofClass: URL.self) { [weak self] url, error in
            guard let self else { return }

            if let error {
                NSLog("[EXT] ❌ loadURL error=\(String(describing: error))")
                self.completeOnMain()
                return
            }

            guard let url else {
                NSLog("[EXT] ❌ loadURL: no URL returned")
                self.completeOnMain()
                return
            }

            NSLog("[EXT] ✅ Got URL=\(url.absoluteString)")
            self.enqueueAndExit(url: url)
        }
    }

    private func loadText(from provider: NSItemProvider) {
        _ = provider.loadObject(ofClass: String.self) { [weak self] text, error in
            guard let self else { return }

            if let error {
                NSLog("[EXT] ❌ loadText error=\(String(describing: error))")
                self.completeOnMain()
                return
            }

            guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = self.firstURL(in: raw) else {
                NSLog("[EXT] ❌ loadText: Could not extract URL from text=\(String(describing: text))")
                self.completeOnMain()
                return
            }

            NSLog("[EXT] ✅ Extracted URL from text=\(url.absoluteString)")
            self.enqueueAndExit(url: url)
        }
    }

    private func firstURL(in text: String) -> URL? {
        if let u = URL(string: text), u.scheme != nil { return u }
        let pattern = #"https?://[^\s]+"#
        if let range = text.range(of: pattern, options: .regularExpression) {
            return URL(string: String(text[range]))
        }
        return nil
    }

    private func enqueueAndExit(url: URL) {
        RecipeImportInboxQueue.enqueue(url: url)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let appURL = URL(string: "frydgerecipes://import") else {
                self.completeOnMain()
                return
            }

            self.extensionContext?.open(appURL) { didOpen in
                if didOpen || self.openAppViaResponderChain(appURL) {
                    NSLog("[EXT] ✅ Requested app open for import")
                } else {
                    NSLog("[EXT] ⚠️ Could not open app directly; import remains queued")
                }
                self.completeOnMain()
            }
        }
    }

    private func openAppViaResponderChain(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self

        while let current = responder {
            if current.responds(to: selector) {
                current.perform(selector, with: url)
                return true
            }
            responder = current.next
        }

        return false
    }

    private func completeOnMain() {
        DispatchQueue.main.async { self.complete() }
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}

// MARK: - App Group inbox queue writer (extension-side helper)

private enum RecipeImportInboxQueue {
    static let appGroupID = "group.Clark-Online.FrydgeRecipeAPN"
    static let inboxFilename = "recipe_import_inbox_queue.json"

    struct InboxItem: Codable, Hashable {
        var id: String
        var urlString: String
        var createdAtISO8601: String
        var source: String
    }

    /// Same advisory lock file the app's `RecipeImportInbox` takes while it
    /// drains the queue, so an append here and a removal there cannot
    /// interleave and lose a link (or resurrect a removed one).
    static let lockFilename = ".frydge-recipe-inbox.lock"

    static func enqueue(url: URL) {
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            NSLog("[EXT] ❌ AppGroup folder not found for \(appGroupID)")
            return
        }
        let lockURL = folder.appendingPathComponent(lockFilename)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 {
            defer { close(fd) }
            if flock(fd, LOCK_EX) == 0 {
                defer { flock(fd, LOCK_UN) }
                enqueueUnlocked(url: url, in: folder)
                return
            }
        }
        enqueueUnlocked(url: url, in: folder)
    }

    private static func enqueueUnlocked(url: URL, in folder: URL) {

        let fileURL = folder.appendingPathComponent(inboxFilename)

        var items = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([InboxItem].self, from: $0) } ?? []

        // Dedupe by URL (keep most recent at top)
        let urlString = url.absoluteString
        items.removeAll(where: { $0.urlString == urlString })

        let item = InboxItem(
            id: UUID().uuidString,
            urlString: urlString,
            createdAtISO8601: ISO8601DateFormatter().string(from: Date()),
            source: Bundle.main.bundleIdentifier ?? "unknown"
        )

        items.insert(item, at: 0)

        // Cap to avoid unbounded growth
        if items.count > 25 { items = Array(items.prefix(25)) }

        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: [.atomic])
            NSLog("[EXT] ✅ Enqueued inbox item, count=\(items.count) file=\(fileURL.path)")
        } catch {
            NSLog("[EXT] ❌ Failed writing inbox queue: \(String(describing: error))")
        }
    }
}
