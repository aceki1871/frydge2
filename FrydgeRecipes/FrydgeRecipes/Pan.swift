import Foundation
import CloudKit

struct Pan: Identifiable, Codable {
    var id: String
    var name: String

    // Initialize from CKRecord (CloudKit)
    init(record: CKRecord) {
        self.id = record.recordID.recordName
        self.name = record["name"] as? String ?? "Unnamed Pan"
    }

    // Initialize with properties
    init(name: String) {
        self.id = UUID().uuidString
        self.name = name
    }

    // Convert to CKRecord for saving to CloudKit
    func toCKRecord() -> CKRecord {
        let record = CKRecord(recordType: "Pan", recordID: CKRecord.ID(recordName: id))
        record["name"] = name as CKRecordValue
        return record
    }

    // Map pan names to SF Symbols
    func symbolName() -> String {
        switch name.lowercased() {
        case "frying pan": return "frying.pan"
        case "saucepan": return "pot"
        case "wok": return "wok"
        case "baking tray": return "rectangle.and.pencil.and.ellipsis"
        default: return "circle"
        }
    }
}
