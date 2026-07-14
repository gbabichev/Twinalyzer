/*

 EnhancedScanCache.swift
 Twinalyzer

 Disk-backed cache for Vision feature prints and completed exhaustive scans.

 */

import Foundation
import SQLite3
@preconcurrency import Vision

nonisolated struct CachedImageDescriptor: Sendable, Hashable {
    let path: String
    let fileSize: Int64
    let modificationTimeBits: Int64

    var versionKey: String {
        "\(path)\u{1f}\(fileSize)\u{1f}\(modificationTimeBits)"
    }

    init?(url: URL) {
        let standardizedURL = url.standardizedFileURL
        guard let values = try? standardizedURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]), values.isRegularFile == true else {
            return nil
        }

        path = standardizedURL.path
        fileSize = Int64(values.fileSize ?? 0)
        let timestamp = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        modificationTimeBits = Int64(bitPattern: timestamp.bitPattern)
    }
}

nonisolated enum EnhancedScanCacheError: Error, CustomStringConvertible {
    case open(String)
    case sqlite(String)
    case invalidFeatureArchive(String)

    var description: String {
        switch self {
        case .open(let message), .sqlite(let message): return message
        case .invalidFeatureArchive(let path): return "Invalid cached Vision feature for \(path)"
        }
    }
}

/// A scan owns this object from one background task. SQLite is opened in full-mutex mode as
/// an additional safeguard, but calls are intentionally synchronous to keep ordering explicit.
nonisolated final class EnhancedScanCache: @unchecked Sendable {
    struct ReusableScan: Sendable {
        let id: Int64
        let minimumThreshold: Double
    }

    struct ReusableCoverage: Sendable {
        let scanID: Int64
        let reusablePaths: Set<String>
    }

    struct StoredMatch: Sendable {
        let reference: String
        let similar: String
        let similarity: Double
    }

    private var db: OpaquePointer?
    private var matchInsertStatement: OpaquePointer?
    private var matchTransactionOpen = false
    private var pendingMatchCount = 0

    static func databaseURL() throws -> URL {
        let fileManager = FileManager.default
        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return baseURL
            .appendingPathComponent("Twinalyzer", isDirectory: true)
            .appendingPathComponent("EnhancedScanCache.sqlite3")
    }

    static func cacheSizeInBytes() throws -> Int64 {
        let fileManager = FileManager.default
        return try cacheFileURLs().reduce(into: Int64(0)) { total, url in
            guard fileManager.fileExists(atPath: url.path) else { return }
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values.fileSize ?? 0)
        }
    }

    /// Removes the database and SQLite sidecar files. The caller must ensure no scan is active.
    static func resetDatabase() throws {
        let fileManager = FileManager.default
        for url in try cacheFileURLs() where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private static func cacheFileURLs() throws -> [URL] {
        let databaseURL = try databaseURL()
        return ["", "-wal", "-shm", "-journal"].map { suffix in
            URL(fileURLWithPath: databaseURL.path + suffix)
        }
    }

    init(databaseURL providedDatabaseURL: URL? = nil) throws {
        let fileManager = FileManager.default
        let databaseURL: URL
        if let providedDatabaseURL {
            databaseURL = providedDatabaseURL
            try fileManager.createDirectory(
                at: providedDatabaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } else {
            databaseURL = try Self.databaseURL()
            let directory = databaseURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            if let db { sqlite3_close(db) }
            self.db = nil
            throw EnhancedScanCacheError.open("Unable to open enhanced scan cache: \(message)")
        }

        sqlite3_busy_timeout(db, 30_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA temp_store=FILE")
        try createSchema()
        try execute("DELETE FROM scans WHERE completed = 0")
    }

    deinit {
        if matchTransactionOpen { try? execute("ROLLBACK") }
        if let matchInsertStatement { sqlite3_finalize(matchInsertStatement) }
        if let db { sqlite3_close(db) }
    }

    func cachedFeature(
        for descriptor: CachedImageDescriptor,
        revision: Int
    ) throws -> VNFeaturePrintObservation? {
        let sql = """
            SELECT feature_archive
            FROM features
            WHERE path = ? AND file_size = ? AND modification_time_bits = ? AND vision_revision = ?
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(descriptor.path, to: 1, in: statement)
        sqlite3_bind_int64(statement, 2, descriptor.fileSize)
        sqlite3_bind_int64(statement, 3, descriptor.modificationTimeBits)
        sqlite3_bind_int(statement, 4, Int32(revision))

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        let data = Data(bytes: bytes, count: count)
        do {
            return try NSKeyedUnarchiver.unarchivedObject(
                ofClass: VNFeaturePrintObservation.self,
                from: data
            )
        } catch {
            // A cache is disposable. Remove an incompatible archive and regenerate it.
            try? removeFeature(atPath: descriptor.path)
            return nil
        }
    }

    func hasCachedFeature(
        for descriptor: CachedImageDescriptor,
        revision: Int
    ) throws -> Bool {
        let statement = try prepare("""
            SELECT 1 FROM features
            WHERE path = ? AND file_size = ? AND modification_time_bits = ? AND vision_revision = ?
            LIMIT 1
            """)
        defer { sqlite3_finalize(statement) }
        bind(descriptor.path, to: 1, in: statement)
        sqlite3_bind_int64(statement, 2, descriptor.fileSize)
        sqlite3_bind_int64(statement, 3, descriptor.modificationTimeBits)
        sqlite3_bind_int(statement, 4, Int32(revision))
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func storeFeature(
        _ observation: VNFeaturePrintObservation,
        for descriptor: CachedImageDescriptor,
        revision: Int
    ) throws {
        let archive = try NSKeyedArchiver.archivedData(
            withRootObject: observation,
            requiringSecureCoding: true
        )
        let sql = """
            INSERT INTO features(
                path, file_size, modification_time_bits, vision_revision,
                element_type, element_count, feature_archive, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                file_size = excluded.file_size,
                modification_time_bits = excluded.modification_time_bits,
                vision_revision = excluded.vision_revision,
                element_type = excluded.element_type,
                element_count = excluded.element_count,
                feature_archive = excluded.feature_archive,
                updated_at = excluded.updated_at
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(descriptor.path, to: 1, in: statement)
        sqlite3_bind_int64(statement, 2, descriptor.fileSize)
        sqlite3_bind_int64(statement, 3, descriptor.modificationTimeBits)
        sqlite3_bind_int(statement, 4, Int32(revision))
        sqlite3_bind_int(statement, 5, Int32(observation.elementType.rawValue))
        sqlite3_bind_int64(statement, 6, Int64(observation.elementCount))
        bind(archive, to: 7, in: statement)
        sqlite3_bind_double(statement, 8, Date().timeIntervalSince1970)
        try stepDone(statement)
    }

    func loadFeatureBlock(
        _ descriptors: ArraySlice<CachedImageDescriptor>,
        revision: Int
    ) throws -> [(descriptor: CachedImageDescriptor, observation: VNFeaturePrintObservation)] {
        var block: [(CachedImageDescriptor, VNFeaturePrintObservation)] = []
        block.reserveCapacity(descriptors.count)
        for descriptor in descriptors {
            guard let observation = try cachedFeature(for: descriptor, revision: revision) else {
                throw EnhancedScanCacheError.invalidFeatureArchive(descriptor.path)
            }
            block.append((descriptor, observation))
        }
        return block
    }

    func reusableScan(
        signature: String,
        requestedThreshold: Double,
        revision: Int
    ) throws -> ReusableScan? {
        // A completed scan at a lower threshold contains every match needed by a higher threshold.
        let sql = """
            SELECT id, minimum_threshold
            FROM scans
            WHERE image_set_signature = ? AND vision_revision = ? AND completed = 1
              AND minimum_threshold <= ?
            ORDER BY minimum_threshold DESC
            LIMIT 1
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(signature, to: 1, in: statement)
        sqlite3_bind_int(statement, 2, Int32(revision))
        sqlite3_bind_double(statement, 3, requestedThreshold + 1e-12)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return ReusableScan(
            id: sqlite3_column_int64(statement, 0),
            minimumThreshold: sqlite3_column_double(statement, 1)
        )
    }

    /// Stages the current, versioned image set in a temporary table. This supports efficient
    /// overlap queries without constructing enormous SQL IN clauses.
    func prepareCurrentImageSet(_ descriptors: [CachedImageDescriptor]) throws {
        try execute("""
            CREATE TEMP TABLE IF NOT EXISTS current_images(
                path TEXT PRIMARY KEY,
                version_key TEXT NOT NULL
            ) WITHOUT ROWID
            """)
        try execute("DELETE FROM current_images")
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("INSERT INTO current_images(path, version_key) VALUES(?, ?)")
            defer { sqlite3_finalize(statement) }
            for descriptor in descriptors {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(descriptor.path, to: 1, in: statement)
                bind(descriptor.versionKey, to: 2, in: statement)
                try stepDone(statement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Backfills membership for exact-match scans created by older cache schema versions.
    func recordCurrentImageSet(for scanID: Int64) throws {
        let statement = try prepare("""
            INSERT OR REPLACE INTO scan_images(scan_id, path, version_key)
            SELECT ?, path, version_key FROM current_images
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, scanID)
        try stepDone(statement)
    }

    /// Chooses the completed scan that covers the largest unchanged subset of the current set.
    /// Only scans performed at an equal or lower threshold can prove coverage at the requested
    /// threshold.
    func bestReusableCoverage(
        requestedThreshold: Double,
        revision: Int
    ) throws -> ReusableCoverage? {
        let statement = try prepare("""
            SELECT s.id, COUNT(*) AS overlap_count
            FROM scans s
            JOIN scan_images si ON si.scan_id = s.id
            JOIN current_images ci
              ON ci.path = si.path AND ci.version_key = si.version_key
            WHERE s.vision_revision = ? AND s.completed = 1
              AND s.minimum_threshold <= ?
            GROUP BY s.id
            HAVING overlap_count >= 2
            ORDER BY overlap_count DESC, s.minimum_threshold DESC, s.created_at DESC
            LIMIT 1
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(revision))
        sqlite3_bind_double(statement, 2, requestedThreshold + 1e-12)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let scanID = sqlite3_column_int64(statement, 0)

        let pathsStatement = try prepare("""
            SELECT ci.path
            FROM current_images ci
            JOIN scan_images si
              ON si.path = ci.path AND si.version_key = ci.version_key
            WHERE si.scan_id = ?
            """)
        defer { sqlite3_finalize(pathsStatement) }
        sqlite3_bind_int64(pathsStatement, 1, scanID)
        var paths = Set<String>()
        while sqlite3_step(pathsStatement) == SQLITE_ROW {
            if let text = sqlite3_column_text(pathsStatement, 0) {
                paths.insert(String(cString: text))
            }
        }
        return ReusableCoverage(scanID: scanID, reusablePaths: paths)
    }

    func beginScan(signature: String, threshold: Double, revision: Int) throws -> Int64 {
        let delete = try prepare("""
            DELETE FROM scans
            WHERE image_set_signature = ? AND minimum_threshold = ? AND vision_revision = ?
            """)
        bind(signature, to: 1, in: delete)
        sqlite3_bind_double(delete, 2, threshold)
        sqlite3_bind_int(delete, 3, Int32(revision))
        try stepDone(delete)
        sqlite3_finalize(delete)

        let insert = try prepare("""
            INSERT INTO scans(image_set_signature, minimum_threshold, vision_revision, completed, created_at)
            VALUES(?, ?, ?, 0, ?)
            """)
        defer { sqlite3_finalize(insert) }
        bind(signature, to: 1, in: insert)
        sqlite3_bind_double(insert, 2, threshold)
        sqlite3_bind_int(insert, 3, Int32(revision))
        sqlite3_bind_double(insert, 4, Date().timeIntervalSince1970)
        try stepDone(insert)
        let scanID = sqlite3_last_insert_rowid(db)

        // current_images was populated immediately before this call.
        try recordCurrentImageSet(for: scanID)
        return scanID
    }

    func beginWritingMatches(scanID: Int64) throws {
        precondition(!matchTransactionOpen)
        try execute("BEGIN IMMEDIATE")
        matchTransactionOpen = true
        pendingMatchCount = 0
        matchInsertStatement = try prepare("""
            INSERT OR REPLACE INTO matches(scan_id, reference_path, similar_path, similarity)
            VALUES(?, ?, ?, ?)
            """)
        sqlite3_bind_int64(matchInsertStatement, 1, scanID)
    }

    func appendMatch(scanID: Int64, reference: String, similar: String, similarity: Double) throws {
        guard let statement = matchInsertStatement, matchTransactionOpen else {
            throw EnhancedScanCacheError.sqlite("Match transaction is not open")
        }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_int64(statement, 1, scanID)
        bind(reference, to: 2, in: statement)
        bind(similar, to: 3, in: statement)
        sqlite3_bind_double(statement, 4, similarity)
        try stepDone(statement)
        pendingMatchCount += 1

        // Keep the WAL bounded during scans that produce very large result sets.
        if pendingMatchCount >= 10_000 {
            try execute("COMMIT")
            try execute("BEGIN IMMEDIATE")
            pendingMatchCount = 0
        }
    }

    /// Copies qualifying matches whose two endpoints are both covered by the prior scan.
    @discardableResult
    func copyReusableMatches(
        from sourceScanID: Int64,
        to destinationScanID: Int64,
        threshold: Double
    ) throws -> Int {
        guard matchTransactionOpen else {
            throw EnhancedScanCacheError.sqlite("Match transaction is not open")
        }
        let statement = try prepare("""
            INSERT OR REPLACE INTO matches(scan_id, reference_path, similar_path, similarity)
            SELECT ?, m.reference_path, m.similar_path, m.similarity
            FROM matches m
            JOIN current_images reference_image ON reference_image.path = m.reference_path
            JOIN scan_images source_reference
              ON source_reference.scan_id = m.scan_id
             AND source_reference.path = m.reference_path
             AND source_reference.version_key = reference_image.version_key
            JOIN current_images similar_image ON similar_image.path = m.similar_path
            JOIN scan_images source_similar
              ON source_similar.scan_id = m.scan_id
             AND source_similar.path = m.similar_path
             AND source_similar.version_key = similar_image.version_key
            WHERE m.scan_id = ? AND m.similarity >= ?
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, destinationScanID)
        sqlite3_bind_int64(statement, 2, sourceScanID)
        sqlite3_bind_double(statement, 3, threshold)
        try stepDone(statement)
        let copiedCount = Int(sqlite3_changes(db))

        // The bulk copy may be large. Commit it before starting incremental inserts so the WAL
        // does not hold the entire derived scan in one transaction.
        try execute("COMMIT")
        try execute("BEGIN IMMEDIATE")
        pendingMatchCount = 0
        return copiedCount
    }

    func finishWritingMatches(scanID: Int64) throws {
        if let matchInsertStatement {
            sqlite3_finalize(matchInsertStatement)
            self.matchInsertStatement = nil
        }
        if matchTransactionOpen {
            try execute("COMMIT")
            matchTransactionOpen = false
        }
        let statement = try prepare("UPDATE scans SET completed = 1 WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, scanID)
        try stepDone(statement)
    }

    func abandonScan(scanID: Int64) {
        if let matchInsertStatement {
            sqlite3_finalize(matchInsertStatement)
            self.matchInsertStatement = nil
        }
        if matchTransactionOpen {
            try? execute("ROLLBACK")
            matchTransactionOpen = false
        }
        if let statement = try? prepare("DELETE FROM scans WHERE id = ?") {
            sqlite3_bind_int64(statement, 1, scanID)
            _ = sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }

    func loadMatches(scanID: Int64, threshold: Double) throws -> [StoredMatch] {
        var matches: [StoredMatch] = []
        try forEachMatch(scanID: scanID, threshold: threshold) { matches.append($0) }
        return matches
    }

    func forEachMatch(
        scanID: Int64,
        threshold: Double,
        _ body: (StoredMatch) throws -> Void
    ) throws {
        let statement = try prepare("""
            SELECT reference_path, similar_path, similarity
            FROM matches
            WHERE scan_id = ? AND similarity >= ?
            ORDER BY similarity DESC
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, scanID)
        sqlite3_bind_double(statement, 2, threshold)

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let referenceText = sqlite3_column_text(statement, 0),
                  let similarText = sqlite3_column_text(statement, 1) else { continue }
            try body(StoredMatch(
                reference: String(cString: referenceText),
                similar: String(cString: similarText),
                similarity: sqlite3_column_double(statement, 2)
            ))
        }
    }

    // MARK: - SQLite plumbing

    private func createSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS features(
                path TEXT PRIMARY KEY,
                file_size INTEGER NOT NULL,
                modification_time_bits INTEGER NOT NULL,
                vision_revision INTEGER NOT NULL,
                element_type INTEGER NOT NULL,
                element_count INTEGER NOT NULL,
                feature_archive BLOB NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS scans(
                id INTEGER PRIMARY KEY,
                image_set_signature TEXT NOT NULL,
                minimum_threshold REAL NOT NULL,
                vision_revision INTEGER NOT NULL,
                completed INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            )
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS scans_lookup
            ON scans(image_set_signature, vision_revision, completed, minimum_threshold)
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS scan_images(
                scan_id INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
                path TEXT NOT NULL,
                version_key TEXT NOT NULL,
                PRIMARY KEY(scan_id, path)
            ) WITHOUT ROWID
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS scan_images_version_lookup
            ON scan_images(path, version_key, scan_id)
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS matches(
                scan_id INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
                reference_path TEXT NOT NULL,
                similar_path TEXT NOT NULL,
                similarity REAL NOT NULL,
                PRIMARY KEY(scan_id, reference_path, similar_path)
            ) WITHOUT ROWID
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS matches_similarity
            ON matches(scan_id, similarity DESC)
            """)
    }

    private func removeFeature(atPath path: String) throws {
        let statement = try prepare("DELETE FROM features WHERE path = ?")
        defer { sqlite3_finalize(statement) }
        bind(path, to: 1, in: statement)
        try stepDone(statement)
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? currentErrorMessage
            sqlite3_free(errorMessage)
            throw EnhancedScanCacheError.sqlite(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw EnhancedScanCacheError.sqlite(currentErrorMessage)
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw EnhancedScanCacheError.sqlite(currentErrorMessage)
        }
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer?) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func bind(_ value: Data, to index: Int32, in statement: OpaquePointer?) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
        }
    }

    private var currentErrorMessage: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
    }
}
