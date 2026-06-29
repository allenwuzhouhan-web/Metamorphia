import Foundation
import SQLite3
import Accelerate

/// The persistent Retrace index: SQLite (WAL) + FTS5 + optional sqlite-vec.
///
/// Lives at `~/Library/Application Support/Metamorphia/retrace/retrace.db`.
/// Raw SQLite3 C API to mirror `ElementDatabase`; all mutations serialise on a
/// single dispatch queue. ``items.body`` holds plaintext UTF-8: the FTS5
/// external-content pattern requires a searchable shadow copy, and the DB
/// file itself is protected by TCC under Application Support. A future
/// SQLCipher swap-in is tracked in the plan.
public final class RetraceIndex: @unchecked Sendable {

    // MARK: - Shared

    private static var _shared: RetraceIndex?

    /// Configure the shared instance. Call once at app startup from Bootstrap.
    /// Subsequent calls are ignored. Safe to call before any UI is visible.
    @discardableResult
    public static func configureShared(directory: URL, filename: String = "retrace.db") -> RetraceIndex {
        if let existing = _shared { return existing }
        let instance = RetraceIndex(directory: directory, filename: filename)
        _shared = instance
        return instance
    }

    /// Returns the configured shared instance or `nil` if no one called
    /// ``configureShared(directory:filename:)`` yet. Call sites that read
    /// during early bootstrap can fall back silently.
    public static var shared: RetraceIndex? { _shared }

    // MARK: - Open connection

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.metamorphia.retrace.db", qos: .utility)
    public let vecAvailable: Bool

    public let dbPath: String

    public init(directory: URL, filename: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(filename).path
        self.dbPath = path

        if sqlite3_open(path, &db) != SQLITE_OK {
            print("[Retrace] Failed to open \(path); recreating")
            try? FileManager.default.removeItem(atPath: path)
            sqlite3_open(path, &db)
        }

        Self.configurePragmas(db: db)

        // Try to load sqlite-vec if present. It's a loadable extension — not
        // bundled by default. If unavailable, we fall back to Accelerate brute
        // force in ``nearest(to:candidates:limit:)``.
        self.vecAvailable = Self.tryLoadVecExtension(db: db)
        if vecAvailable {
            print("[Retrace] sqlite-vec loaded successfully")
        } else {
            print("[Retrace] sqlite-vec not available — using Accelerate fallback")
        }

        queue.sync {
            RetraceSchema.createTables(db: db, vecAvailable: vecAvailable)
        }
    }

    deinit {
        sqlite3_close(db)
    }

    private static func configurePragmas(db: OpaquePointer?) {
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA auto_vacuum=INCREMENTAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA mmap_size=268435456", nil, nil, nil)   // 256 MB
        sqlite3_exec(db, "PRAGMA cache_size=-64000", nil, nil, nil)      // 64 MB
        sqlite3_exec(db, "PRAGMA temp_store=MEMORY", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys=ON", nil, nil, nil)
    }

    /// Check whether sqlite-vec was statically linked into this binary.
    ///
    /// macOS's system SQLite disables dynamic extension loading, so sqlite-vec
    /// is integrated by static-linking the amalgamation source into the
    /// module. When present, a `vec_version()` SQL function becomes available
    /// and we can create `vec0` virtual tables. When absent, ``nearest(...)``
    /// falls back to an Accelerate brute-force cosine over the `items_vec`
    /// BLOB column. The fallback is fast enough for corpora under ~200k
    /// vectors when pre-filtered by timestamp + app.
    private static func tryLoadVecExtension(db: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT vec_version()", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // MARK: - Inserts

    /// Insert an item. Returns the assigned rowid, or `nil` if the insert
    /// collided with a dedup constraint (screen-frame content_hash unique).
    @discardableResult
    public func insert(_ item: IndexedItem) -> Int64? {
        queue.sync {
            let sql = """
            INSERT INTO items
              (id, kind, ts, session_id, app_bundle_id, doc_path, url, place_hash,
               title, body, body_bytes, confidence, content_hash, source_meta, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }

            bindUUID(stmt, 1, item.id)
            sqlite3_bind_int(stmt, 2, Int32(item.kind.rawValue))
            sqlite3_bind_double(stmt, 3, item.timestamp.timeIntervalSince1970)
            if let sid = item.sessionID { bindUUID(stmt, 4, sid) } else { sqlite3_bind_null(stmt, 4) }
            bindTextOrNull(stmt, 5, item.appBundleID)
            bindTextOrNull(stmt, 6, item.docPath)
            bindTextOrNull(stmt, 7, item.url)
            bindTextOrNull(stmt, 8, item.placeHash)
            bindTextOrNull(stmt, 9, item.title)

            let bodyData = item.body.data(using: .utf8) ?? Data()
            _ = bodyData.withUnsafeBytes { raw -> Int32 in
                if let base = raw.baseAddress, raw.count > 0 {
                    return sqlite3_bind_blob(stmt, 10, base, Int32(raw.count), SQLITE_TRANSIENT)
                } else {
                    return sqlite3_bind_zeroblob(stmt, 10, 0)
                }
            }
            sqlite3_bind_int64(stmt, 11, Int64(bodyData.count))
            sqlite3_bind_double(stmt, 12, item.confidence)
            // SQLite bind_int64 expects signed; bitPattern reinterprets bits.
            sqlite3_bind_int64(stmt, 13, Int64(bitPattern: item.contentHash))

            if let meta = item.sourceMeta,
               let json = try? JSONSerialization.data(withJSONObject: meta) {
                let s = String(data: json, encoding: .utf8)
                bindTextOrNull(stmt, 14, s)
            } else {
                sqlite3_bind_null(stmt, 14)
            }
            sqlite3_bind_double(stmt, 15, Date().timeIntervalSince1970)

            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE {
                return sqlite3_last_insert_rowid(db)
            }
            if rc == SQLITE_CONSTRAINT {
                // Dedup hit on content_hash for screen frames — expected.
                return nil
            }
            return nil
        }
    }

    /// Insert an embedding vector for an item. Must have dimension 768.
    public func upsertEmbedding(rowid: Int64, vector: [Float]) {
        guard vector.count == 768 else { return }
        queue.sync {
            // Always write to items_vec for the fallback path.
            let sql = """
            INSERT INTO items_vec (rowid, embedding, dim)
            VALUES (?, ?, 768)
            ON CONFLICT(rowid) DO UPDATE SET embedding = excluded.embedding
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int64(stmt, 1, rowid)
            vector.withUnsafeBufferPointer { buf in
                if let base = buf.baseAddress {
                    sqlite3_bind_blob(stmt, 2, base, Int32(buf.count * MemoryLayout<Float>.size), SQLITE_TRANSIENT)
                }
            }
            sqlite3_step(stmt)

            // Also write to items_vec_index if sqlite-vec is loaded.
            if vecAvailable {
                let vecSQL = "INSERT OR REPLACE INTO items_vec_index (rowid, embedding) VALUES (?, ?)"
                var vstmt: OpaquePointer?
                defer { sqlite3_finalize(vstmt) }
                if sqlite3_prepare_v2(db, vecSQL, -1, &vstmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(vstmt, 1, rowid)
                    vector.withUnsafeBufferPointer { buf in
                        if let base = buf.baseAddress {
                            sqlite3_bind_blob(vstmt, 2, base, Int32(buf.count * MemoryLayout<Float>.size), SQLITE_TRANSIENT)
                        }
                    }
                    sqlite3_step(vstmt)
                }
            }
        }
    }

    /// Return all rowids tagged with a given canonical entity. Used by
    /// ``QueryRank`` when ranking by entity match.
    public func rowidsForEntity(canonical: String) -> [Int64] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT item_rowid FROM item_entities WHERE canonical = ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            bindText(stmt, 1, canonical.lowercased())
            var rowids: [Int64] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rowids.append(sqlite3_column_int64(stmt, 0))
            }
            return rowids
        }
    }

    /// Link an entity to an item. Multiple entities per item are allowed; a
    /// second call for the same (item, canonical) updates the weight.
    public func linkEntity(rowid: Int64, canonical: String, entityTypeRaw: Int, weight: Double = 1.0) {
        queue.sync {
            let sql = """
            INSERT INTO item_entities (item_rowid, canonical, entity_type, weight)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(item_rowid, canonical) DO UPDATE SET
                weight = MAX(item_entities.weight, excluded.weight)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int64(stmt, 1, rowid)
            bindText(stmt, 2, canonical.lowercased())
            sqlite3_bind_int(stmt, 3, Int32(entityTypeRaw))
            sqlite3_bind_double(stmt, 4, weight)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Deletes

    public func deleteItem(rowid: Int64) {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(db, "DELETE FROM items WHERE rowid = ?", -1, &stmt, nil)
            sqlite3_bind_int64(stmt, 1, rowid)
            sqlite3_step(stmt)
            // ON DELETE CASCADE takes items_vec + item_entities + item_taps.
            if vecAvailable {
                var vstmt: OpaquePointer?
                defer { sqlite3_finalize(vstmt) }
                sqlite3_prepare_v2(db, "DELETE FROM items_vec_index WHERE rowid = ?", -1, &vstmt, nil)
                sqlite3_bind_int64(vstmt, 1, rowid)
                sqlite3_step(vstmt)
            }
        }
    }

    /// Delete all items tagged with `canonical`. Returns the number of rows
    /// removed. Used by "forget an entity" in Settings.
    @discardableResult
    public func deleteItemsWithEntity(canonical: String) -> Int {
        queue.sync {
            var rowids: [Int64] = []
            let sql = "SELECT item_rowid FROM item_entities WHERE canonical = ?"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindText(stmt, 1, canonical.lowercased())
                while sqlite3_step(stmt) == SQLITE_ROW {
                    rowids.append(sqlite3_column_int64(stmt, 0))
                }
            }
            sqlite3_finalize(stmt)

            guard !rowids.isEmpty else { return 0 }

            sqlite3_exec(db, "BEGIN", nil, nil, nil)
            for rowid in rowids {
                var dstmt: OpaquePointer?
                sqlite3_prepare_v2(db, "DELETE FROM items WHERE rowid = ?", -1, &dstmt, nil)
                sqlite3_bind_int64(dstmt, 1, rowid)
                sqlite3_step(dstmt)
                sqlite3_finalize(dstmt)
                if vecAvailable {
                    var vstmt: OpaquePointer?
                    sqlite3_prepare_v2(db, "DELETE FROM items_vec_index WHERE rowid = ?", -1, &vstmt, nil)
                    sqlite3_bind_int64(vstmt, 1, rowid)
                    sqlite3_step(vstmt)
                    sqlite3_finalize(vstmt)
                }
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)

            return rowids.count
        }
    }

    /// Delete items older than `cutoff`. Respects tombstone semantics via a
    /// simple range delete — vacuum on schedule to reclaim space.
    @discardableResult
    public func pruneOlderThan(_ cutoff: Date) -> Int {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "DELETE FROM items WHERE ts < ?", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
            sqlite3_step(stmt)
            return Int(sqlite3_changes(db))
        }
    }

    public func clearAll() {
        queue.sync {
            sqlite3_exec(db, "DELETE FROM items", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM items_vec", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM item_entities", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM item_taps", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM sessions", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM file_state", nil, nil, nil)
            if vecAvailable {
                sqlite3_exec(db, "DELETE FROM items_vec_index", nil, nil, nil)
            }
            sqlite3_exec(db, "VACUUM", nil, nil, nil)
        }
    }

    // MARK: - Reads

    public func fetchItem(rowid: Int64) -> IndexedItem? {
        queue.sync { fetchItemUnsafe(rowid: rowid) }
    }

    private func fetchItemUnsafe(rowid: Int64) -> IndexedItem? {
        let sql = """
        SELECT id, kind, ts, session_id, app_bundle_id, doc_path, url, place_hash,
               title, body, body_bytes, confidence, content_hash, source_meta
          FROM items WHERE rowid = ?
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(stmt, 1, rowid)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readItemRow(stmt)
    }

    /// Candidate items in a time range + optional app filter. Used as the
    /// pre-filter before vector/BM25 ranking. Returns up to `limit` rowids
    /// newest-first.
    public func candidateRowids(
        from: Date,
        to: Date,
        apps: Set<String>? = nil,
        kinds: Set<ItemKind>? = nil,
        limit: Int = 5000
    ) -> [Int64] {
        queue.sync {
            var sql = "SELECT rowid FROM items WHERE ts >= ? AND ts <= ?"
            var binds: [(Int32) -> Void] = []
            binds.append { [from] i in sqlite3_bind_double(nil, i, from.timeIntervalSince1970) }  // replaced below
            // Build the SQL with placeholders; binds populated below in a second pass.
            var params: [Any] = [from.timeIntervalSince1970, to.timeIntervalSince1970]

            if let apps, !apps.isEmpty {
                let placeholders = apps.map { _ in "?" }.joined(separator: ",")
                sql += " AND app_bundle_id IN (\(placeholders))"
                params.append(contentsOf: apps.map { $0 as Any })
            }
            if let kinds, !kinds.isEmpty {
                let placeholders = kinds.map { _ in "?" }.joined(separator: ",")
                sql += " AND kind IN (\(placeholders))"
                params.append(contentsOf: kinds.map { Int32($0.rawValue) as Any })
            }
            sql += " ORDER BY ts DESC LIMIT \(Int32(limit))"

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

            for (index, value) in params.enumerated() {
                let i = Int32(index + 1)
                if let d = value as? Double { sqlite3_bind_double(stmt, i, d) }
                else if let s = value as? String { bindText(stmt, i, s) }
                else if let v = value as? Int32 { sqlite3_bind_int(stmt, i, v) }
            }

            var rowids: [Int64] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rowids.append(sqlite3_column_int64(stmt, 0))
            }
            _ = binds  // keep compiler happy
            return rowids
        }
    }

    /// FTS5 MATCH search. Returns `(rowid, bm25Score)` tuples. Use `*` suffix
    /// for prefix matches. Callers should pre-escape special FTS5 characters.
    public func ftsSearch(_ query: String, rowids: [Int64]? = nil, limit: Int = 200) -> [(Int64, Double)] {
        queue.sync {
            let q = sanitizeFTS(query)
            guard !q.isEmpty else { return [] }

            var sql: String
            if let rowids, !rowids.isEmpty {
                let placeholders = rowids.map { _ in "?" }.joined(separator: ",")
                sql = """
                SELECT items_fts.rowid, bm25(items_fts)
                  FROM items_fts
                 WHERE items_fts MATCH ? AND items_fts.rowid IN (\(placeholders))
                 ORDER BY bm25(items_fts) LIMIT \(Int32(limit))
                """
            } else {
                sql = """
                SELECT items_fts.rowid, bm25(items_fts)
                  FROM items_fts
                 WHERE items_fts MATCH ?
                 ORDER BY bm25(items_fts) LIMIT \(Int32(limit))
                """
            }

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            bindText(stmt, 1, q)
            if let rowids {
                for (i, r) in rowids.enumerated() {
                    sqlite3_bind_int64(stmt, Int32(i + 2), r)
                }
            }
            var results: [(Int64, Double)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let rowid = sqlite3_column_int64(stmt, 0)
                let bm = sqlite3_column_double(stmt, 1)
                // FTS5 returns negative BM25 (lower = better). Normalize:
                // convert to a positive "score" via -bm25.
                results.append((rowid, -bm))
            }
            return results
        }
    }

    /// Nearest neighbours by cosine similarity. If sqlite-vec is available,
    /// uses the `items_vec_index` ANN. Otherwise scans the provided candidate
    /// rowids (or all rows) via Accelerate `vDSP_dotpr`. Returns
    /// `(rowid, similarity)` tuples in descending similarity order.
    public func nearest(to query: [Float], candidates: [Int64]? = nil, limit: Int = 200) -> [(Int64, Double)] {
        guard query.count == 768 else { return [] }
        let qNorm = l2Normalize(query)

        if vecAvailable, candidates == nil || (candidates?.count ?? 0) > 10_000 {
            return queue.sync { vecNearest(qNorm, limit: limit, filterRowids: candidates) }
        }

        return queue.sync { bruteNearest(qNorm, limit: limit, filterRowids: candidates) }
    }

    private func vecNearest(_ q: [Float], limit: Int, filterRowids: [Int64]?) -> [(Int64, Double)] {
        let data = q.withUnsafeBufferPointer { buf -> Data in
            Data(bytes: buf.baseAddress!, count: buf.count * MemoryLayout<Float>.size)
        }

        var sql = """
        SELECT rowid, distance
          FROM items_vec_index
         WHERE embedding MATCH ?
         ORDER BY distance
         LIMIT \(Int32(limit))
        """
        if let filterRowids, !filterRowids.isEmpty {
            let placeholders = filterRowids.map { _ in "?" }.joined(separator: ",")
            sql = """
            SELECT rowid, distance
              FROM items_vec_index
             WHERE embedding MATCH ? AND rowid IN (\(placeholders))
             ORDER BY distance
             LIMIT \(Int32(limit))
            """
        }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                sqlite3_bind_blob(stmt, 1, base, Int32(raw.count), SQLITE_TRANSIENT)
            }
        }
        if let filterRowids {
            for (i, r) in filterRowids.enumerated() {
                sqlite3_bind_int64(stmt, Int32(i + 2), r)
            }
        }

        var results: [(Int64, Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(stmt, 0)
            // vec0 distance is L2 by default; since vectors are L2-normalized,
            // cosine_similarity = 1 - L2^2 / 2.
            let dist = sqlite3_column_double(stmt, 1)
            let cosine = max(0.0, 1.0 - dist * dist / 2.0)
            results.append((rowid, cosine))
        }
        return results
    }

    private func bruteNearest(_ q: [Float], limit: Int, filterRowids: [Int64]?) -> [(Int64, Double)] {
        // No candidate set means no pre-filtered window: scanning and
        // materializing every stored embedding would pull the whole table
        // (hundreds of MB at scale) through the serial queue for one query.
        // An empty candidate window also semantically means "no results".
        guard let filterRowids, !filterRowids.isEmpty else { return [] }

        let placeholders = filterRowids.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT rowid, embedding FROM items_vec WHERE rowid IN (\(placeholders))"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        for (i, r) in filterRowids.enumerated() {
            sqlite3_bind_int64(stmt, Int32(i + 1), r)
        }

        var scored: [(Int64, Double)] = []
        scored.reserveCapacity(min(limit * 4, 4096))

        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(stmt, 0)
            let byteCount = Int(sqlite3_column_bytes(stmt, 1))
            guard byteCount == 768 * MemoryLayout<Float>.size,
                  let raw = sqlite3_column_blob(stmt, 1) else { continue }

            // vDSP_dotpr for a 768-d dot product; assumes both sides are
            // L2-normalized, so dot == cosine similarity.
            var sim: Float = 0
            let vPtr = raw.bindMemory(to: Float.self, capacity: 768)
            q.withUnsafeBufferPointer { qb in
                vDSP_dotpr(qb.baseAddress!, 1, vPtr, 1, &sim, 768)
            }
            scored.append((rowid, Double(sim)))
        }

        // Top-N partial sort.
        scored.sort { $0.1 > $1.1 }
        if scored.count > limit { scored.removeLast(scored.count - limit) }
        return scored
    }

    // MARK: - Sessions

    public func upsertSession(
        id: UUID,
        startedAt: Date,
        endedAt: Date,
        appBundleID: String?,
        docHint: String?,
        cadenceTierRaw: Int,
        placeHash: String?,
        topEntitiesJSON: String?
    ) {
        queue.sync {
            let sql = """
            INSERT INTO sessions (id, started_at, ended_at, app_bundle_id, doc_hint, cadence_tier, place_hash, top_entities_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                ended_at = excluded.ended_at,
                doc_hint = COALESCE(excluded.doc_hint, doc_hint),
                top_entities_json = COALESCE(excluded.top_entities_json, top_entities_json)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            bindUUID(stmt, 1, id)
            sqlite3_bind_double(stmt, 2, startedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, endedAt.timeIntervalSince1970)
            bindTextOrNull(stmt, 4, appBundleID)
            bindTextOrNull(stmt, 5, docHint)
            sqlite3_bind_int(stmt, 6, Int32(cadenceTierRaw))
            bindTextOrNull(stmt, 7, placeHash)
            bindTextOrNull(stmt, 8, topEntitiesJSON)
            sqlite3_step(stmt)
        }
    }

    public func itemsInSession(_ sessionID: UUID, limit: Int = 200) -> [IndexedItem] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT rowid FROM items WHERE session_id = ? ORDER BY ts DESC LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            bindUUID(stmt, 1, sessionID)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var rowids: [Int64] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rowids.append(sqlite3_column_int64(stmt, 0))
            }
            return rowids.compactMap { fetchItemUnsafe(rowid: $0) }
        }
    }

    // MARK: - Feedback

    public func recordTap(rowid: Int64, queryHash: UInt64) {
        queue.sync {
            let now = Date().timeIntervalSince1970

            var s1: OpaquePointer?
            defer { sqlite3_finalize(s1) }
            sqlite3_prepare_v2(db,
                """
                UPDATE items SET tap_count = tap_count + 1, last_tapped_at = ? WHERE rowid = ?
                """, -1, &s1, nil)
            sqlite3_bind_double(s1, 1, now)
            sqlite3_bind_int64(s1, 2, rowid)
            sqlite3_step(s1)

            var s2: OpaquePointer?
            defer { sqlite3_finalize(s2) }
            sqlite3_prepare_v2(db, "INSERT INTO item_taps (item_rowid, query_hash, tapped_at) VALUES (?, ?, ?)", -1, &s2, nil)
            sqlite3_bind_int64(s2, 1, rowid)
            var q = queryHash
            withUnsafeBytes(of: &q) { raw in
                if let base = raw.baseAddress {
                    sqlite3_bind_blob(s2, 2, base, Int32(raw.count), SQLITE_TRANSIENT)
                }
            }
            sqlite3_bind_double(s2, 3, now)
            sqlite3_step(s2)
        }
    }

    // MARK: - File / archive state

    public func fileStateHash(forPath path: String) -> (mtime: Double, size: Int64, contentHash: UInt64)? {
        queue.sync {
            let sql = "SELECT mtime, size, content_hash FROM file_state WHERE path = ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            bindText(stmt, 1, path)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let m = sqlite3_column_double(stmt, 0)
            let s = sqlite3_column_int64(stmt, 1)
            let h = UInt64(bitPattern: sqlite3_column_int64(stmt, 2))
            return (m, s, h)
        }
    }

    public func upsertFileState(path: String, mtime: Double, size: Int64, contentHash: UInt64, itemRowid: Int64?) {
        queue.sync {
            let sql = """
            INSERT INTO file_state (path, mtime, size, content_hash, indexed_at, item_rowid)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                mtime = excluded.mtime,
                size = excluded.size,
                content_hash = excluded.content_hash,
                indexed_at = excluded.indexed_at,
                item_rowid = excluded.item_rowid
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            bindText(stmt, 1, path)
            sqlite3_bind_double(stmt, 2, mtime)
            sqlite3_bind_int64(stmt, 3, size)
            sqlite3_bind_int64(stmt, 4, Int64(bitPattern: contentHash))
            sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
            if let rowid = itemRowid {
                sqlite3_bind_int64(stmt, 6, rowid)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            sqlite3_step(stmt)
        }
    }

    public func archiveWatermark(for sourceKey: String) -> String? {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT watermark FROM archive_state WHERE source_key = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
            bindText(stmt, 1, sourceKey)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return getString(stmt, 0)
        }
    }

    public func setArchiveWatermark(_ watermark: String, for sourceKey: String) {
        queue.sync {
            let sql = """
            INSERT INTO archive_state (source_key, watermark, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(source_key) DO UPDATE SET watermark = excluded.watermark, updated_at = excluded.updated_at
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            bindText(stmt, 1, sourceKey)
            bindText(stmt, 2, watermark)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Maintenance

    public func vacuumIncremental() {
        queue.sync {
            sqlite3_exec(db, "PRAGMA incremental_vacuum", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA optimize", nil, nil, nil)
        }
    }

    public struct Stats: Sendable {
        public let totalItems: Int
        public let itemsByKind: [ItemKind: Int]
        public let totalEmbeddings: Int
        public let totalEntities: Int
        public let totalSessions: Int
        public let dbSizeBytes: Int64
    }

    public func stats() -> Stats {
        queue.sync {
            var byKind: [ItemKind: Int] = [:]
            var total = 0
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT kind, COUNT(*) FROM items GROUP BY kind", -1, &stmt, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let k = Int(sqlite3_column_int(stmt, 0))
                let c = Int(sqlite3_column_int(stmt, 1))
                if let kind = ItemKind(rawValue: k) { byKind[kind] = c }
                total += c
            }
            sqlite3_finalize(stmt)

            let emb = scalar("SELECT COUNT(*) FROM items_vec")
            let ent = scalar("SELECT COUNT(*) FROM item_entities")
            let ses = scalar("SELECT COUNT(*) FROM sessions")
            let size = (try? FileManager.default.attributesOfItem(atPath: dbPath)[.size] as? NSNumber)?.int64Value ?? 0
            return Stats(totalItems: total, itemsByKind: byKind,
                         totalEmbeddings: emb, totalEntities: ent,
                         totalSessions: ses, dbSizeBytes: size)
        }
    }

    // MARK: - Helpers

    private func scalar(_ sql: String) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func readItemRow(_ stmt: OpaquePointer?) -> IndexedItem? {
        guard let stmt else { return nil }
        guard let idData = readBlob(stmt, 0), idData.count == 16 else { return nil }
        let id = uuidFromData(idData)
        let kindRaw = Int(sqlite3_column_int(stmt, 1))
        guard let kind = ItemKind(rawValue: kindRaw) else { return nil }
        let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))

        var sessionID: UUID?
        if sqlite3_column_type(stmt, 3) != SQLITE_NULL,
           let sidData = readBlob(stmt, 3), sidData.count == 16 {
            sessionID = uuidFromData(sidData)
        }

        let appBundleID = getString(stmt, 4)
        let docPath = getString(stmt, 5)
        let url = getString(stmt, 6)
        let placeHash = getString(stmt, 7)
        let title = getString(stmt, 8)

        let bodyData = readBlob(stmt, 9) ?? Data()
        let body = String(data: bodyData, encoding: .utf8) ?? ""

        let confidence = sqlite3_column_double(stmt, 11)
        let contentHash = UInt64(bitPattern: sqlite3_column_int64(stmt, 12))

        var meta: [String: String]?
        if let metaStr = getString(stmt, 13),
           let data = metaStr.data(using: .utf8),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
            meta = parsed
        }

        return IndexedItem(
            id: id, kind: kind, timestamp: ts, sessionID: sessionID,
            appBundleID: appBundleID, docPath: docPath, url: url,
            placeHash: placeHash, title: title, body: body,
            confidence: confidence, contentHash: contentHash, sourceMeta: meta
        )
    }

    private func readBlob(_ stmt: OpaquePointer?, _ index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        let byteCount = Int(sqlite3_column_bytes(stmt, index))
        guard byteCount > 0, let raw = sqlite3_column_blob(stmt, index) else { return nil }
        return Data(bytes: raw, count: byteCount)
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        value.withCString { sqlite3_bind_text(stmt, index, $0, -1, SQLITE_TRANSIENT) }
    }

    private func bindTextOrNull(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let v = value { bindText(stmt, index, v) } else { sqlite3_bind_null(stmt, index) }
    }

    private func bindUUID(_ stmt: OpaquePointer?, _ index: Int32, _ uuid: UUID) {
        var tuple = uuid.uuid
        withUnsafeBytes(of: &tuple) { raw in
            if let base = raw.baseAddress {
                sqlite3_bind_blob(stmt, index, base, Int32(raw.count), SQLITE_TRANSIENT)
            }
        }
    }

    private func uuidFromData(_ data: Data) -> UUID {
        var bytes: uuid_t = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        withUnsafeMutableBytes(of: &bytes) { out in
            data.prefix(16).withUnsafeBytes { src in
                if let dst = out.baseAddress, let s = src.baseAddress {
                    dst.copyMemory(from: s, byteCount: min(16, data.count))
                }
            }
        }
        return UUID(uuid: bytes)
    }

    private func getString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    private func l2Normalize(_ v: [Float]) -> [Float] {
        var result = v
        var norm: Float = 0
        result.withUnsafeBufferPointer { buf in
            vDSP_svesq(buf.baseAddress!, 1, &norm, vDSP_Length(buf.count))
        }
        norm = sqrt(norm)
        guard norm > 1e-8 else { return result }
        var inv = 1.0 / norm
        result.withUnsafeMutableBufferPointer { buf in
            vDSP_vsmul(buf.baseAddress!, 1, &inv, buf.baseAddress!, 1, vDSP_Length(buf.count))
        }
        return result
    }

    private func sanitizeFTS(_ raw: String) -> String {
        // Keep simple: strip SQLite FTS5 special tokens and enclose in quotes.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

// SQLITE_TRANSIENT — tell SQLite to make its own copy of bound blobs/text.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
