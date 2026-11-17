import Foundation
import CloudKit

struct RecipePan: Identifiable, Codable {
    let id: UUID
    var name: String

    init(name: String) {
        self.id = UUID()
        self.name = name
    }

    init(record: CKRecord) {
        self.id = UUID()
        self.name = record["name"] as? String ?? "Unknown Pan"
    }

    static func fetchReferences(_ refs: [CKRecord.Reference]) async throws -> [RecipePan] {
        var fetchedPans: [RecipePan] = []
        let container = CKContainer(identifier: "iCloud.com.Clark-Online.Recipe")
        let publicDatabase = container.publicCloudDatabase

        for ref in refs {
            let record = try await publicDatabase.record(for: ref.recordID)
            let pan = RecipePan(record: record)
            fetchedPans.append(pan)
        }
        return fetchedPans
    }

    func toCKReference() -> CKRecord.Reference {
        return CKRecord.Reference(recordID: CKRecord.ID(recordName: self.id.uuidString), action: .none)
    }
}
