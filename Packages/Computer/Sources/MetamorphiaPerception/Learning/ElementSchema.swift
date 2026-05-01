import Foundation
import SQLite3

/// DDL for the element learning database. All schema creation and migration lives here.
public enum ElementSchema {

    /// Current schema version. Increment when adding migrations.
    public static let currentVersion = 1

    /// Create all tables if they don't exist. Safe to call multiple times.
    public static func createTables(db: OpaquePointer?, queue: DispatchQueue) {
        queue.sync {
            guard let db = db else { return }

            // Schema version tracking
            exec(db, """
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY
            )
            """)
            exec(db, "INSERT OR IGNORE INTO schema_version (version) VALUES (\(currentVersion))")

            // Known elements with learned identities
            exec(db, """
            CREATE TABLE IF NOT EXISTS elements (
                hash TEXT PRIMARY KEY,
                app_bundle_id TEXT,
                role TEXT NOT NULL,
                label TEXT NOT NULL,
                custom_label TEXT,
                structural_signature TEXT,
                visual_hash TEXT,
                confidence REAL DEFAULT 0.5,
                times_seen INTEGER DEFAULT 1,
                times_correct INTEGER DEFAULT 0,
                times_wrong INTEGER DEFAULT 0,
                first_seen REAL NOT NULL,
                last_seen REAL NOT NULL,
                last_confirmed REAL,
                is_universal INTEGER DEFAULT 0,
                behavior TEXT,
                metadata_json TEXT
            )
            """)
            exec(db, "CREATE INDEX IF NOT EXISTS idx_elements_app ON elements(app_bundle_id)")
            exec(db, "CREATE INDEX IF NOT EXISTS idx_elements_label ON elements(label)")
            exec(db, "CREATE INDEX IF NOT EXISTS idx_elements_sig ON elements(structural_signature)")
            exec(db, "CREATE INDEX IF NOT EXISTS idx_elements_visual ON elements(visual_hash)")

            // Cross-app pattern recognition
            exec(db, """
            CREATE TABLE IF NOT EXISTS patterns (
                id TEXT PRIMARY KEY,
                signature TEXT NOT NULL,
                meaning TEXT NOT NULL,
                confidence REAL DEFAULT 0.5,
                apps_seen_in TEXT,
                times_confirmed INTEGER DEFAULT 0,
                created_at REAL NOT NULL
            )
            """)
            exec(db, "CREATE INDEX IF NOT EXISTS idx_patterns_sig ON patterns(signature)")
            exec(db, "CREATE INDEX IF NOT EXISTS idx_patterns_meaning ON patterns(meaning)")

            // User corrections — when agent selects wrong element
            exec(db, """
            CREATE TABLE IF NOT EXISTS corrections (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                element_hash TEXT,
                expected_label TEXT,
                actual_label TEXT NOT NULL,
                app_bundle_id TEXT,
                window_context TEXT,
                intended_action TEXT,
                selected_signature TEXT,
                correct_signature TEXT,
                timestamp REAL NOT NULL
            )
            """)
            exec(db, "CREATE INDEX IF NOT EXISTS idx_corrections_element ON corrections(element_hash)")
            exec(db, "CREATE INDEX IF NOT EXISTS idx_corrections_app ON corrections(app_bundle_id)")

            // Recorded workflows — replayable task sequences
            exec(db, """
            CREATE TABLE IF NOT EXISTS workflows (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                app_bundle_id TEXT,
                steps_json TEXT NOT NULL,
                times_replayed INTEGER DEFAULT 0,
                success_count INTEGER DEFAULT 0,
                created_at REAL NOT NULL,
                last_replayed REAL
            )
            """)
            exec(db, "CREATE INDEX IF NOT EXISTS idx_workflows_app ON workflows(app_bundle_id)")

            // Failure log — expected vs actual screen state
            exec(db, """
            CREATE TABLE IF NOT EXISTS failures (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                workflow_id TEXT,
                step_index INTEGER,
                expected_state_json TEXT,
                actual_state_json TEXT,
                element_ref TEXT,
                action_attempted TEXT,
                error_description TEXT,
                app_bundle_id TEXT,
                timestamp REAL NOT NULL,
                FOREIGN KEY (workflow_id) REFERENCES workflows(id)
            )
            """)
            exec(db, "CREATE INDEX IF NOT EXISTS idx_failures_workflow ON failures(workflow_id)")
            exec(db, "CREATE INDEX IF NOT EXISTS idx_failures_app ON failures(app_bundle_id)")

            // App profiles — per-app UI characteristics
            exec(db, """
            CREATE TABLE IF NOT EXISTS app_profiles (
                bundle_id TEXT PRIMARY KEY,
                app_name TEXT NOT NULL,
                app_version TEXT,
                needs_ocr INTEGER DEFAULT 0,
                ax_coverage_pct REAL,
                element_count_avg INTEGER,
                interactive_count_avg INTEGER,
                structural_hash TEXT,
                role_distribution_json TEXT,
                toolbar_signature TEXT,
                menu_bar_items_json TEXT,
                custom_roles_json TEXT,
                element_aliases_json TEXT,
                last_profiled REAL NOT NULL,
                profiled_by TEXT DEFAULT 'auto',
                profile_version INTEGER DEFAULT 1
            )
            """)
        }
    }

    // MARK: - Helpers

    private static func exec(_ db: OpaquePointer, _ sql: String) {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let msg = error.map { String(cString: $0) } ?? "unknown"
            print("[ElementSchema] SQL error: \(msg)")
            sqlite3_free(error)
        }
    }
}
