import Foundation
import SQLite3

/// SQL schema for Retrace. One unified `items` table across every modality,
/// an FTS5 external-content virtual table joined by rowid for full-text search,
/// and a plain `items_vec` BLOB table for embeddings (with an optional
/// sqlite-vec-backed index when the extension is available at runtime).
///
/// The `items_vec` table holds 768-dim float32 embeddings as raw BLOBs. When
/// the sqlite-vec extension loads, queries use the `vec0` virtual table
/// `items_vec_index` for ANN; otherwise ``RetraceIndex`` performs a prefiltered
/// brute-force cosine scan using Accelerate.
enum RetraceSchema {

    static let userVersion: Int32 = 1

    // MARK: - Create

    static func createTables(db: OpaquePointer?, vecAvailable: Bool) {
        let statements: [String] = [
            // ------------------------------------------------------------------
            // items — one row per searchable record across all modalities.
            // ------------------------------------------------------------------
            """
            CREATE TABLE IF NOT EXISTS items (
                rowid            INTEGER PRIMARY KEY AUTOINCREMENT,
                id               BLOB NOT NULL UNIQUE,
                kind             INTEGER NOT NULL,
                ts               REAL NOT NULL,
                session_id       BLOB,
                app_bundle_id    TEXT,
                doc_path         TEXT,
                url              TEXT,
                place_hash       TEXT,
                title            TEXT,
                body             BLOB NOT NULL,
                body_bytes       INTEGER NOT NULL,
                summary          TEXT,
                confidence       REAL NOT NULL DEFAULT 1.0,
                content_hash     INTEGER NOT NULL,
                tap_count        INTEGER NOT NULL DEFAULT 0,
                tap_count_decayed REAL NOT NULL DEFAULT 0.0,
                last_tapped_at   REAL,
                source_meta      TEXT,
                created_at       REAL NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_items_ts ON items(ts);",
            "CREATE INDEX IF NOT EXISTS idx_items_session ON items(session_id, ts);",
            "CREATE INDEX IF NOT EXISTS idx_items_app ON items(app_bundle_id, ts);",
            "CREATE INDEX IF NOT EXISTS idx_items_kind_ts ON items(kind, ts);",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_items_hash_screen ON items(content_hash) WHERE kind = 0;",

            // ------------------------------------------------------------------
            // items_fts — FTS5 external-content virtual table.
            // Triggers keep it in sync with items.
            // ------------------------------------------------------------------
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
                title, body, url, doc_path,
                content='items',
                content_rowid='rowid',
                tokenize="unicode61 remove_diacritics 2"
            );
            """,
            """
            CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
                INSERT INTO items_fts(rowid, title, body, url, doc_path)
                VALUES (new.rowid, new.title, CAST(new.body AS TEXT), new.url, new.doc_path);
            END;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
                INSERT INTO items_fts(items_fts, rowid, title, body, url, doc_path)
                VALUES('delete', old.rowid, old.title, CAST(old.body AS TEXT), old.url, old.doc_path);
            END;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE ON items BEGIN
                INSERT INTO items_fts(items_fts, rowid, title, body, url, doc_path)
                VALUES('delete', old.rowid, old.title, CAST(old.body AS TEXT), old.url, old.doc_path);
                INSERT INTO items_fts(rowid, title, body, url, doc_path)
                VALUES (new.rowid, new.title, CAST(new.body AS TEXT), new.url, new.doc_path);
            END;
            """,

            // ------------------------------------------------------------------
            // items_vec — raw vector BLOBs (always present, used by the fallback
            // brute-force path). If sqlite-vec is loaded, we additionally create
            // an `items_vec_index` vec0 virtual table that mirrors the same rows
            // for fast ANN.
            // ------------------------------------------------------------------
            """
            CREATE TABLE IF NOT EXISTS items_vec (
                rowid      INTEGER PRIMARY KEY,
                embedding  BLOB NOT NULL,
                dim        INTEGER NOT NULL DEFAULT 768,
                FOREIGN KEY(rowid) REFERENCES items(rowid) ON DELETE CASCADE
            );
            """,

            // ------------------------------------------------------------------
            // item_entities — canonical entity links per item.
            // ------------------------------------------------------------------
            """
            CREATE TABLE IF NOT EXISTS item_entities (
                item_rowid   INTEGER NOT NULL,
                canonical    TEXT NOT NULL,
                entity_type  INTEGER NOT NULL,
                weight       REAL NOT NULL DEFAULT 1.0,
                PRIMARY KEY (item_rowid, canonical),
                FOREIGN KEY (item_rowid) REFERENCES items(rowid) ON DELETE CASCADE
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_item_entities_canonical ON item_entities(canonical, item_rowid);",

            // ------------------------------------------------------------------
            // item_taps — user feedback loop.
            // ------------------------------------------------------------------
            """
            CREATE TABLE IF NOT EXISTS item_taps (
                item_rowid INTEGER NOT NULL,
                query_hash BLOB NOT NULL,
                tapped_at  REAL NOT NULL,
                FOREIGN KEY (item_rowid) REFERENCES items(rowid) ON DELETE CASCADE
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_item_taps_rowid ON item_taps(item_rowid);",

            // ------------------------------------------------------------------
            // sessions — SessionSegmenter rollups, enriched with entity tops.
            // ------------------------------------------------------------------
            """
            CREATE TABLE IF NOT EXISTS sessions (
                id                BLOB PRIMARY KEY,
                started_at        REAL NOT NULL,
                ended_at          REAL NOT NULL,
                app_bundle_id     TEXT,
                doc_hint          TEXT,
                cadence_tier      INTEGER NOT NULL,
                place_hash        TEXT,
                top_entities_json TEXT
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_sessions_ended ON sessions(ended_at);",

            // ------------------------------------------------------------------
            // file_state — FileHarvest incremental watermarks.
            // ------------------------------------------------------------------
            """
            CREATE TABLE IF NOT EXISTS file_state (
                path          TEXT PRIMARY KEY,
                mtime         REAL NOT NULL,
                size          INTEGER NOT NULL,
                content_hash  INTEGER NOT NULL,
                indexed_at    REAL NOT NULL,
                item_rowid    INTEGER
            );
            """,

            // ------------------------------------------------------------------
            // archive_state — per-source ingestion watermarks (Messages, Mail).
            // ------------------------------------------------------------------
            """
            CREATE TABLE IF NOT EXISTS archive_state (
                source_key  TEXT PRIMARY KEY,
                watermark   TEXT NOT NULL,
                updated_at  REAL NOT NULL
            );
            """,
        ]

        for sql in statements {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                if let err {
                    print("[RetraceSchema] DDL failed: \(String(cString: err))")
                    sqlite3_free(err)
                }
            }
        }

        if vecAvailable {
            // sqlite-vec extension is loaded — create the ANN index. Safe to
            // re-run; CREATE VIRTUAL TABLE IF NOT EXISTS is idempotent.
            let vecSQL = """
            CREATE VIRTUAL TABLE IF NOT EXISTS items_vec_index USING vec0(
                embedding float[768]
            );
            """
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, vecSQL, nil, nil, &err) != SQLITE_OK {
                if let err {
                    print("[RetraceSchema] vec0 DDL failed: \(String(cString: err))")
                    sqlite3_free(err)
                }
            }
        }

        // Record schema version for future migrations.
        sqlite3_exec(db, "PRAGMA user_version = \(userVersion)", nil, nil, nil)
    }
}
