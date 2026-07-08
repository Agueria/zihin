import CloudKit
import Foundation
import GRDB

/// CloudKit private DB sync (spec §8, Faz 3). Offline-first: sync olmadan her şey çalışır.
/// v1.0: metadata + embedding + feature print (~2KB/kayıt). Asset'ler v1.1 (CKAsset).
/// readerHTML sync EDİLMEZ (CKRecord 1MB limiti); assetPath cihaza özeldir.
final class CloudKitSyncService: @unchecked Sendable {
    static let shared = CloudKitSyncService()

    private let container = CKContainer(identifier: "iCloud.app.zihin")
    private var db: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: "zihinZone",
                                         ownerName: CKCurrentUserDefaultName)
    private let repo = ItemRepository()
    private let pool = DatabaseManager.shared.dbPool
    // Spec düzeltmesi: token App Group UserDefaults'ta (extension da görebilsin)
    private let defaults = UserDefaults(suiteName: DatabaseManager.appGroupID)
    private let tokenKey = "ck.serverChangeToken"

    /// Tek giriş: hesap uygunsa bootstrap + push + pull.
    func sync() async {
        guard (try? await container.accountStatus()) == .available else { return }
        _ = try? await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)],
                                            deleting: [])
        await pushDirty()
        await pullChanges()
    }

    // MARK: Push
    func pushDirty() async {
        let dirty: [Item] = (try? await pool.read { d in
            try Item.filter(Column("dirty") == true).fetchAll(d)
        }) ?? []
        guard !dirty.isEmpty else { return }

        // CKModifyRecords operasyon limiti için parçala
        var index = 0
        while index < dirty.count {
            let chunk = Array(dirty[index..<min(index + 200, dirty.count)])
            index += 200
            let records = chunk.map(recordFromItem)
            guard let result = try? await db.modifyRecords(
                saving: records, deleting: [], savePolicy: .changedKeys) else { continue }
            for (recordID, res) in result.saveResults {
                guard case .success(let record) = res else { continue }
                let sys = Self.encodeSystemFields(record)
                let recordName = recordID.recordName
                try? await pool.write { d in
                    try Item.filter(key: recordName).updateAll(d,
                        Column("dirty").set(to: false),
                        Column("ckSystemFields").set(to: sys))
                }
            }
        }
    }

    // MARK: Pull (change token ile artımlı)
    func pullChanges() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            config.previousServerChangeToken = loadToken()
            let op = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: config])

            op.recordWasChangedBlock = { [weak self] _, result in
                if case .success(let record) = result { self?.applyRemote(record) }
            }
            op.recordWithIDWasDeletedBlock = { [weak self] recordID, _ in
                _ = try? self?.pool.write { d in
                    try Item.deleteOne(d, key: recordID.recordName)
                }
            }
            op.recordZoneChangeTokensUpdatedBlock = { [weak self] _, token, _ in
                self?.saveToken(token)
            }
            op.recordZoneFetchResultBlock = { [weak self] _, result in
                if case .success(let (token, _, _)) = result { self?.saveToken(token) }
            }
            let once = Once()
            op.fetchRecordZoneChangesResultBlock = { _ in once.run { c.resume() } }
            op.qualityOfService = .utility
            self.db.add(op)
        }
    }

    // MARK: Item <-> CKRecord
    private func recordFromItem(_ item: Item) -> CKRecord {
        let recordID = CKRecord.ID(recordName: item.id, zoneID: zoneID)
        let record: CKRecord
        if let data = item.ckSystemFields,
           let decoded = Self.decodeSystemFields(data) {
            record = decoded
        } else {
            record = CKRecord(recordType: "Item", recordID: recordID)
        }
        record["type"] = item.type.rawValue
        record["status"] = item.status.rawValue
        record["createdAt"] = item.createdAt
        record["updatedAt"] = item.updatedAt
        record["title"] = item.title
        record["url"] = item.url
        record["textContent"] = item.textContent
        record["summary"] = item.summary
        record["ocrText"] = item.ocrText
        record["transcript"] = item.transcript
        record["frameText"] = item.frameText
        record["dominantColors"] = item.dominantColors
        record["durationSec"] = item.durationSec
        record["siteName"] = item.siteName
        record["lang"] = item.lang
        record["isPinned"] = item.isPinned ? 1 : 0
        record["forgotten"] = item.forgotten ? 1 : 0
        record["embedding"] = item.embedding
        record["featurePrint"] = item.featurePrint
        return record
    }

    private func applyRemote(_ record: CKRecord) {
        let id = record.recordID.recordName
        let remoteUpdated = (record["updatedAt"] as? Date) ?? .distantPast
        let local = try? repo.item(id: id)
        if let local, local.updatedAt >= remoteUpdated { return }   // LWW

        var item = local ?? Item(type: .note)
        item.id = id
        item.type = ItemType(rawValue: record["type"] as? String ?? "note") ?? .note
        item.status = ItemStatus(rawValue: record["status"] as? String ?? "ready") ?? .ready
        item.createdAt = record["createdAt"] as? Date ?? Date()
        item.updatedAt = remoteUpdated
        item.title = record["title"] as? String
        item.url = record["url"] as? String
        item.textContent = record["textContent"] as? String
        item.summary = record["summary"] as? String
        item.ocrText = record["ocrText"] as? String
        item.transcript = record["transcript"] as? String
        item.frameText = record["frameText"] as? String
        item.dominantColors = record["dominantColors"] as? String
        item.durationSec = record["durationSec"] as? Double
        item.siteName = record["siteName"] as? String
        item.lang = record["lang"] as? String
        item.isPinned = (record["isPinned"] as? Int ?? 0) == 1
        item.forgotten = (record["forgotten"] as? Int ?? 0) == 1
        item.embedding = record["embedding"] as? Data
        item.featurePrint = record["featurePrint"] as? Data
        item.ckSystemFields = Self.encodeSystemFields(record)
        item.dirty = false
        try? pool.write { d in try item.save(d) }
    }

    // MARK: systemFields & token
    private static func encodeSystemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }
    private static func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
    private func saveToken(_ token: CKServerChangeToken?) {
        guard let token,
              let data = try? NSKeyedArchiver.archivedData(
                withRootObject: token, requiringSecureCoding: true) else { return }
        defaults?.set(data, forKey: tokenKey)
    }
    private func loadToken() -> CKServerChangeToken? {
        guard let data = defaults?.data(forKey: tokenKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: CKServerChangeToken.self, from: data)
    }
}
