//
//
//  OFFProductLite.swift
//  FrydgeRecipes
//
//  Created by Josh on 15/09/2025.
//
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct OFFProductLite: Sendable {
    public let code: String
    public let name: String
    public let brands: String
    public let imageURL: String
    public let ingredientsText: String
    public let allergens: String
    /// JSON string of per-100g nutriments as stored in OFF
    public let nutrimentsJSON: String
    public let lastModified: Int
}

public final class OFFLocalDB: @unchecked Sendable {
    public static let shared = OFFLocalDB()

    private var db: OpaquePointer?
    private let dbFileName = "products.db"
    /// Optional bundled sqlite DB placed in app bundle Resources (uncompressed).
    /// If not present, the app will still run and will rely on remote OFF lookup.
    private let bundledDBName = "products"
    private let bundledDBExtension = "db"
    private let queue = DispatchQueue(label: "off.local.db.queue", qos: .userInitiated)

    private init() {}

    // MARK: - Public API

    /// Call once at app launch (or lazily on first lookup).
    /// - If an uncompressed products.db exists in the app bundle, it is copied once into Application Support and opened read-only.
    /// - If not present, this returns false and the app should fall back to remote OFF requests.
    @discardableResult
    public func prepareBundledDatabase() -> Bool {
        do {
            // Prefer already-copied DB.
            let dst = try appSupportURL().appendingPathComponent(dbFileName)
            if FileManager.default.fileExists(atPath: dst.path) {
                return open(at: dst)
            }

            // Copy from bundle if available.
            if let src = Bundle.main.url(forResource: bundledDBName, withExtension: bundledDBExtension) {
                try FileManager.default.copyItem(at: src, to: dst)
                return open(at: dst)
            }

            // No local DB present.
            return false
        } catch {
            print("[OFFLocalDB] prepare error: \(error.localizedDescription)")
            return false
        }
    }

    /// Simple barcode lookup. Returns nil if not found.
    public func lookup(barcode: String) -> OFFProductLite? {
        // Lazy open if caller didn't prepare at launch.
        if db == nil {
            _ = prepareBundledDatabase()
        }
        guard let db else { return nil }
        var stmt: OpaquePointer?
        // Schema (recommended):
        // CREATE TABLE products(
        //   code TEXT PRIMARY KEY,
        //   name TEXT, brands TEXT, img_url TEXT,
        //   nutriments_json TEXT, ingredients_text TEXT,
        //   allergens TEXT, last_modified INTEGER);
        let sql = "SELECT code,name,brands,img_url,nutriments_json,ingredients_text,allergens,last_modified FROM products WHERE code = ? LIMIT 1;"
        var result: OFFProductLite?

        queue.sync {
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                print("[OFFLocalDB] prepare failed: \(errorMessage())"); return
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (barcode as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let code = String(cString: sqlite3_column_text(stmt, 0))
                let name = String(cString: sqlite3_column_text(stmt, 1))
                let brands = String(cString: sqlite3_column_text(stmt, 2))
                let img = String(cString: sqlite3_column_text(stmt, 3))
                let nutr = String(cString: sqlite3_column_text(stmt, 4))
                let ingred = String(cString: sqlite3_column_text(stmt, 5))
                let allergens = String(cString: sqlite3_column_text(stmt, 6))
                let lm = Int(sqlite3_column_int(stmt, 7))
                result = OFFProductLite(
                    code: code,
                    name: name,
                    brands: brands,
                    imageURL: img,
                    ingredientsText: ingred,
                    allergens: allergens,
                    nutrimentsJSON: nutr,
                    lastModified: lm
                )
            }
        }
        return result
    }

    /// Async lookup to avoid blocking the main thread.
    public func lookupAsync(barcode: String) async -> OFFProductLite? {
        await withCheckedContinuation { cont in
            queue.async {
                let res = self.lookup(barcode: barcode)
                cont.resume(returning: res)
            }
        }
    }

    // MARK: - Open / Paths

    private func open(at url: URL) -> Bool {
        if db != nil { return true }
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil)
        if rc == SQLITE_OK, let h = handle {
            db = h
            // Speed: set immutable if you built DB with immutable flag (optional)
            // sqlite3_file_control(db, nil, SQLITE_FCNTL_PDB, nil)
            return true
        } else {
            if let err = handle { sqlite3_close(err) }
            print("[OFFLocalDB] open failed rc=\(rc) msg=\(errorMessage())")
            return false
        }
    }

    private func appSupportURL() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let appDir = base.appendingPathComponent("FrydgeRecipes", isDirectory: true)
        if !fm.fileExists(atPath: appDir.path) {
            try fm.createDirectory(at: appDir, withIntermediateDirectories: true, attributes: nil)
        }
        return appDir
    }

    private func errorMessage() -> String {
        guard let db else { return "no db" }
        if let c = sqlite3_errmsg(db) { return String(cString: c) }
        return "unknown"
    }
}

// MARK: - Optional helper to parse nutriments JSON into a Swift dict
public extension OFFLocalDB {
    func nutrimentsDict(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
