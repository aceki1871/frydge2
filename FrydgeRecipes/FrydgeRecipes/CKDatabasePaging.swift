import CloudKit
import Foundation

extension CKDatabase {
    /// Fetches every record matching `query`, following CloudKit's query cursor
    /// until the server reports no more results.
    ///
    /// `records(matching:)` on its own returns at most one page (currently 100
    /// records) and hands back a cursor that the callers in this app used to
    /// discard. A household fridge, a receipt archive or a list of shared
    /// anchors beyond that page size silently appeared truncated. Use this
    /// wherever the intent is "the complete collection"; keep the single-page
    /// call only for deliberately bounded previews.
    ///
    /// Records whose per-record result failed are skipped rather than failing
    /// the whole fetch, matching the previous `try? result.get()` behaviour at
    /// each call site. Query-level failures (network, auth, missing schema)
    /// still throw so callers can surface them.
    func allRecords(
        matching query: CKQuery,
        inZoneWith zoneID: CKRecordZone.ID? = nil,
        desiredKeys: [CKRecord.FieldKey]? = nil
    ) async throws -> [CKRecord] {
        var out: [CKRecord] = []
        var seen: Set<CKRecord.ID> = []

        var (matches, cursor) = try await records(
            matching: query,
            inZoneWith: zoneID,
            desiredKeys: desiredKeys,
            resultsLimit: CKQueryOperation.maximumResults
        )

        func append(_ page: [(CKRecord.ID, Result<CKRecord, Error>)]) {
            for (_, result) in page {
                guard let record = try? result.get() else { continue }
                // Defensive de-dupe across pages; CloudKit has returned the same
                // record on a page boundary in the past.
                if seen.insert(record.recordID).inserted {
                    out.append(record)
                }
            }
        }

        append(matches)

        while let next = cursor {
            (matches, cursor) = try await records(
                continuingMatchFrom: next,
                desiredKeys: desiredKeys,
                resultsLimit: CKQueryOperation.maximumResults
            )
            append(matches)
        }

        return out
    }
}
