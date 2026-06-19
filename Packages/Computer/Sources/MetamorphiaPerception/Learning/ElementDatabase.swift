import Foundation
import SQLite3

/// SQLite's `SQLITE_TRANSIENT` sentinel destructor. Tells SQLite to make its
/// own private copy of the bound text immediately, so an autoreleased / temporary
/// C string (e.g. `(value as NSString).utf8String`) staying valid past the bind
/// call is not required. Passing `nil` (SQLITE_STATIC) instead would be a
/// use-after-free because the NSString backing the pointer can be released before
/// `sqlite3_step` runs.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Persistent SQLite database for learned element identities, corrections, workflows, and app profiles.
/// Raw SQLite3 C API, WAL mode, M-series optimizations, DispatchQueue serialization.
///
/// The on-disk location and filename are provided by the host via
/// `PerceptionRuntime.bootstrap(_:)`. `ElementDatabase.shared` reads
/// `PerceptionRuntime.host` on first access and crashes if bootstrap has not run.
public final class ElementDatabase: @unchecked Sendable {
    public static let shared: ElementDatabase = {
        let host = PerceptionRuntime.host
        return ElementDatabase(directory: host.applicationSupportDir, filename: host.databaseFilename)
    }()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.computer.elementdb", qos: .utility)

    /// Open (or create) a database at `directory/filename`. The directory is created
    /// if missing. Used by `.shared` via `PerceptionRuntime.host`; also available to
    /// tests and hosts that want to own a second, isolated database instance.
    public init(directory: URL, filename: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbPath = directory.appendingPathComponent(filename).path

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("[ElementDB] Failed to open at \(dbPath), recreating")
            try? FileManager.default.removeItem(atPath: dbPath)
            if sqlite3_open(dbPath, &db) != SQLITE_OK {
                print("[ElementDB] Fatal: cannot create database at \(dbPath)")
                return
            }
        }

        configurePragmas()
        ElementSchema.createTables(db: db, queue: queue)
    }

    /// For testing: create an in-memory database.
    public init(inMemory: Bool) {
        if inMemory {
            if sqlite3_open(":memory:", &db) != SQLITE_OK {
                print("[ElementDB] Fatal: cannot create in-memory database")
                return
            }
            configurePragmas()
            ElementSchema.createTables(db: db, queue: queue)
        }
    }

    private func configurePragmas() {
        queue.sync {
            sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA auto_vacuum=INCREMENTAL", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA mmap_size=268435456", nil, nil, nil)      // 256MB
            sqlite3_exec(db, "PRAGMA cache_size=-64000", nil, nil, nil)         // 64MB
            sqlite3_exec(db, "PRAGMA temp_store=MEMORY", nil, nil, nil)
        }
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Elements

    /// Insert or update a known element identity.
    public func upsertElement(
        hash: String,
        appBundleID: String?,
        role: String,
        label: String,
        customLabel: String? = nil,
        structuralSignature: String? = nil,
        visualHash: String? = nil,
        confidence: Float = 0.5,
        behavior: String? = nil,
        metadataJSON: String? = nil
    ) {
        queue.sync {
            let sql = """
            INSERT INTO elements (hash, app_bundle_id, role, label, custom_label, structural_signature, visual_hash, confidence, times_seen, first_seen, last_seen, behavior, metadata_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)
            ON CONFLICT(hash) DO UPDATE SET
                times_seen = times_seen + 1,
                last_seen = ?,
                confidence = CASE WHEN ? > confidence THEN ? ELSE confidence END,
                custom_label = COALESCE(?, custom_label),
                structural_signature = COALESCE(?, structural_signature),
                visual_hash = COALESCE(?, visual_hash)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

            let now = Date().timeIntervalSince1970
            bindText(stmt, 1, hash)
            bindTextOrNull(stmt, 2, appBundleID)
            bindText(stmt, 3, role)
            bindText(stmt, 4, label)
            bindTextOrNull(stmt, 5, customLabel)
            bindTextOrNull(stmt, 6, structuralSignature)
            bindTextOrNull(stmt, 7, visualHash)
            sqlite3_bind_double(stmt, 8, Double(confidence))
            sqlite3_bind_double(stmt, 9, now)
            sqlite3_bind_double(stmt, 10, now)
            bindTextOrNull(stmt, 11, behavior)
            bindTextOrNull(stmt, 12, metadataJSON)
            // ON CONFLICT params
            sqlite3_bind_double(stmt, 13, now)
            sqlite3_bind_double(stmt, 14, Double(confidence))
            sqlite3_bind_double(stmt, 15, Double(confidence))
            bindTextOrNull(stmt, 16, customLabel)
            bindTextOrNull(stmt, 17, structuralSignature)
            bindTextOrNull(stmt, 18, visualHash)

            sqlite3_step(stmt)
        }
    }

    /// Record a correct match — increase confidence.
    public func recordCorrectMatch(hash: String) {
        queue.sync {
            let sql = """
            UPDATE elements SET
                times_correct = times_correct + 1,
                confidence = confidence + (1.0 - confidence) * 0.1,
                last_seen = ?,
                last_confirmed = ?
            WHERE hash = ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            let now = Date().timeIntervalSince1970
            sqlite3_bind_double(stmt, 1, now)
            sqlite3_bind_double(stmt, 2, now)
            bindText(stmt, 3, hash)
            sqlite3_step(stmt)
        }
    }

    /// Record a wrong match — decrease confidence.
    public func recordWrongMatch(hash: String) {
        queue.sync {
            let sql = """
            UPDATE elements SET
                times_wrong = times_wrong + 1,
                confidence = confidence * 0.8,
                last_seen = ?
            WHERE hash = ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            bindText(stmt, 2, hash)
            sqlite3_step(stmt)
        }
    }

    /// Look up an element by hash.
    public func getElement(hash: String) -> ElementRecord? {
        queue.sync {
            let sql = "SELECT * FROM elements WHERE hash = ? LIMIT 1"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            bindText(stmt, 1, hash)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return readElementRow(stmt)
        }
    }

    /// Find elements matching a structural signature, optionally filtered by app.
    public func findBySignature(_ signature: String, appBundleID: String? = nil) -> [ElementRecord] {
        queue.sync {
            let sql: String
            if let _ = appBundleID {
                sql = "SELECT * FROM elements WHERE structural_signature = ? AND (app_bundle_id = ? OR is_universal = 1) ORDER BY confidence DESC LIMIT 10"
            } else {
                sql = "SELECT * FROM elements WHERE structural_signature = ? ORDER BY confidence DESC LIMIT 10"
            }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            bindText(stmt, 1, signature)
            if let bundleID = appBundleID {
                bindText(stmt, 2, bundleID)
            }
            var results: [ElementRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(readElementRow(stmt))
            }
            return results
        }
    }

    /// Find elements by app bundle ID.
    public func findByApp(_ bundleID: String, limit: Int = 100) -> [ElementRecord] {
        queue.sync {
            let sql = "SELECT * FROM elements WHERE app_bundle_id = ? ORDER BY last_seen DESC LIMIT ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            bindText(stmt, 1, bundleID)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var results: [ElementRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(readElementRow(stmt))
            }
            return results
        }
    }

    /// Promote an element to universal (works across all apps).
    public func setUniversal(hash: String, isUniversal: Bool) {
        queue.sync {
            let sql = "UPDATE elements SET is_universal = ? WHERE hash = ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int(stmt, 1, isUniversal ? 1 : 0)
            bindText(stmt, 2, hash)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Corrections

    /// Record a user correction.
    public func insertCorrection(
        elementHash: String?,
        expectedLabel: String?,
        actualLabel: String,
        appBundleID: String?,
        windowContext: String?,
        intendedAction: String?,
        selectedSignature: String?,
        correctSignature: String?
    ) {
        queue.sync {
            let sql = """
            INSERT INTO corrections (element_hash, expected_label, actual_label, app_bundle_id, window_context, intended_action, selected_signature, correct_signature, timestamp)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            bindTextOrNull(stmt, 1, elementHash)
            bindTextOrNull(stmt, 2, expectedLabel)
            bindText(stmt, 3, actualLabel)
            bindTextOrNull(stmt, 4, appBundleID)
            bindTextOrNull(stmt, 5, windowContext)
            bindTextOrNull(stmt, 6, intendedAction)
            bindTextOrNull(stmt, 7, selectedSignature)
            bindTextOrNull(stmt, 8, correctSignature)
            sqlite3_bind_double(stmt, 9, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    /// Get recent corrections for an app (for confusion pattern extraction).
    public func recentCorrections(appBundleID: String?, limit: Int = 100) -> [CorrectionRecord] {
        queue.sync {
            let sql: String
            if appBundleID != nil {
                sql = "SELECT * FROM corrections WHERE app_bundle_id = ? ORDER BY timestamp DESC LIMIT ?"
            } else {
                sql = "SELECT * FROM corrections ORDER BY timestamp DESC LIMIT ?"
            }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var paramIndex: Int32 = 1
            if let bundleID = appBundleID {
                bindText(stmt, paramIndex, bundleID)
                paramIndex += 1
            }
            sqlite3_bind_int(stmt, paramIndex, Int32(limit))
            var results: [CorrectionRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(readCorrectionRow(stmt))
            }
            return results
        }
    }

    // MARK: - Patterns

    /// Insert or update a cross-app pattern.
    public func upsertPattern(id: String, signature: String, meaning: String, confidence: Float, appsSeen: [String]) {
        queue.sync {
            let appsJSON = (try? JSONSerialization.data(withJSONObject: appsSeen)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let sql = """
            INSERT INTO patterns (id, signature, meaning, confidence, apps_seen_in, times_confirmed, created_at)
            VALUES (?, ?, ?, ?, ?, 1, ?)
            ON CONFLICT(id) DO UPDATE SET
                confidence = ?,
                apps_seen_in = ?,
                times_confirmed = times_confirmed + 1
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            bindText(stmt, 1, id)
            bindText(stmt, 2, signature)
            bindText(stmt, 3, meaning)
            sqlite3_bind_double(stmt, 4, Double(confidence))
            bindText(stmt, 5, appsJSON)
            sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
            sqlite3_bind_double(stmt, 7, Double(confidence))
            bindText(stmt, 8, appsJSON)
            sqlite3_step(stmt)
        }
    }

    /// Find patterns by signature.
    public func findPatterns(signature: String) -> [PatternRecord] {
        queue.sync {
            let sql = "SELECT * FROM patterns WHERE signature = ? ORDER BY confidence DESC"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            bindText(stmt, 1, signature)
            var results: [PatternRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(readPatternRow(stmt))
            }
            return results
        }
    }

    // MARK: - Workflows

    /// Save a recorded workflow.
    public func saveWorkflow(id: String, name: String, appBundleID: String?, stepsJSON: String) {
        queue.sync {
            let sql = """
            INSERT INTO workflows (id, name, app_bundle_id, steps_json, created_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                steps_json = ?,
                name = ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            let now = Date().timeIntervalSince1970
            bindText(stmt, 1, id)
            bindText(stmt, 2, name)
            bindTextOrNull(stmt, 3, appBundleID)
            bindText(stmt, 4, stepsJSON)
            sqlite3_bind_double(stmt, 5, now)
            bindText(stmt, 6, stepsJSON)
            bindText(stmt, 7, name)
            sqlite3_step(stmt)
        }
    }

    /// Get a workflow by ID.
    public func getWorkflow(id: String) -> WorkflowRecord? {
        queue.sync {
            let sql = "SELECT * FROM workflows WHERE id = ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            bindText(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return readWorkflowRow(stmt)
        }
    }

    /// List workflows, optionally filtered by app.
    public func listWorkflows(appBundleID: String? = nil, limit: Int = 50) -> [WorkflowRecord] {
        queue.sync {
            let sql: String
            if appBundleID != nil {
                sql = "SELECT * FROM workflows WHERE app_bundle_id = ? ORDER BY created_at DESC LIMIT ?"
            } else {
                sql = "SELECT * FROM workflows ORDER BY created_at DESC LIMIT ?"
            }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var paramIndex: Int32 = 1
            if let bundleID = appBundleID {
                bindText(stmt, paramIndex, bundleID)
                paramIndex += 1
            }
            sqlite3_bind_int(stmt, paramIndex, Int32(limit))
            var results: [WorkflowRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(readWorkflowRow(stmt))
            }
            return results
        }
    }

    /// Record a workflow replay.
    public func recordReplay(workflowID: String, success: Bool) {
        queue.sync {
            let sql = """
            UPDATE workflows SET
                times_replayed = times_replayed + 1,
                success_count = success_count + ?,
                last_replayed = ?
            WHERE id = ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int(stmt, 1, success ? 1 : 0)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            bindText(stmt, 3, workflowID)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Failures

    /// Log a failure event.
    public func logFailure(
        workflowID: String?,
        stepIndex: Int?,
        expectedStateJSON: String?,
        actualStateJSON: String?,
        elementRef: String?,
        actionAttempted: String?,
        errorDescription: String?,
        appBundleID: String?
    ) {
        queue.sync {
            let sql = """
            INSERT INTO failures (workflow_id, step_index, expected_state_json, actual_state_json, element_ref, action_attempted, error_description, app_bundle_id, timestamp)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            bindTextOrNull(stmt, 1, workflowID)
            if let step = stepIndex { sqlite3_bind_int(stmt, 2, Int32(step)) } else { sqlite3_bind_null(stmt, 2) }
            bindTextOrNull(stmt, 3, expectedStateJSON)
            bindTextOrNull(stmt, 4, actualStateJSON)
            bindTextOrNull(stmt, 5, elementRef)
            bindTextOrNull(stmt, 6, actionAttempted)
            bindTextOrNull(stmt, 7, errorDescription)
            bindTextOrNull(stmt, 8, appBundleID)
            sqlite3_bind_double(stmt, 9, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    /// Get recent failures, optionally filtered by app.
    public func recentFailures(appBundleID: String? = nil, limit: Int = 50) -> [FailureRecord] {
        queue.sync {
            let sql: String
            if appBundleID != nil {
                sql = "SELECT * FROM failures WHERE app_bundle_id = ? ORDER BY timestamp DESC LIMIT ?"
            } else {
                sql = "SELECT * FROM failures ORDER BY timestamp DESC LIMIT ?"
            }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var paramIndex: Int32 = 1
            if let bundleID = appBundleID {
                bindText(stmt, paramIndex, bundleID)
                paramIndex += 1
            }
            sqlite3_bind_int(stmt, paramIndex, Int32(limit))
            var results: [FailureRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(readFailureRow(stmt))
            }
            return results
        }
    }

    // MARK: - App Profiles

    /// Save or update an app profile.
    public func saveAppProfile(_ profile: AppProfileRecord) {
        queue.sync {
            let sql = """
            INSERT INTO app_profiles (bundle_id, app_name, app_version, needs_ocr, ax_coverage_pct, element_count_avg, interactive_count_avg, structural_hash, role_distribution_json, toolbar_signature, menu_bar_items_json, custom_roles_json, element_aliases_json, last_profiled, profiled_by, profile_version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(bundle_id) DO UPDATE SET
                app_name = ?, app_version = ?, needs_ocr = ?, ax_coverage_pct = ?,
                element_count_avg = ?, interactive_count_avg = ?,
                structural_hash = ?, role_distribution_json = ?,
                toolbar_signature = ?, menu_bar_items_json = ?,
                custom_roles_json = COALESCE(?, custom_roles_json),
                element_aliases_json = COALESCE(?, element_aliases_json),
                last_profiled = ?, profile_version = profile_version + 1
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

            let now = Date().timeIntervalSince1970
            // INSERT values
            bindText(stmt, 1, profile.bundleID)
            bindText(stmt, 2, profile.appName)
            bindTextOrNull(stmt, 3, profile.appVersion)
            sqlite3_bind_int(stmt, 4, profile.needsOCR ? 1 : 0)
            sqlite3_bind_double(stmt, 5, Double(profile.axCoveragePct ?? 0))
            sqlite3_bind_int(stmt, 6, Int32(profile.elementCountAvg ?? 0))
            sqlite3_bind_int(stmt, 7, Int32(profile.interactiveCountAvg ?? 0))
            bindTextOrNull(stmt, 8, profile.structuralHash)
            bindTextOrNull(stmt, 9, profile.roleDistributionJSON)
            bindTextOrNull(stmt, 10, profile.toolbarSignature)
            bindTextOrNull(stmt, 11, profile.menuBarItemsJSON)
            bindTextOrNull(stmt, 12, profile.customRolesJSON)
            bindTextOrNull(stmt, 13, profile.elementAliasesJSON)
            sqlite3_bind_double(stmt, 14, now)
            bindText(stmt, 15, profile.profiledBy)
            sqlite3_bind_int(stmt, 16, Int32(profile.profileVersion))
            // ON CONFLICT values
            bindText(stmt, 17, profile.appName)
            bindTextOrNull(stmt, 18, profile.appVersion)
            sqlite3_bind_int(stmt, 19, profile.needsOCR ? 1 : 0)
            sqlite3_bind_double(stmt, 20, Double(profile.axCoveragePct ?? 0))
            sqlite3_bind_int(stmt, 21, Int32(profile.elementCountAvg ?? 0))
            sqlite3_bind_int(stmt, 22, Int32(profile.interactiveCountAvg ?? 0))
            bindTextOrNull(stmt, 23, profile.structuralHash)
            bindTextOrNull(stmt, 24, profile.roleDistributionJSON)
            bindTextOrNull(stmt, 25, profile.toolbarSignature)
            bindTextOrNull(stmt, 26, profile.menuBarItemsJSON)
            bindTextOrNull(stmt, 27, profile.customRolesJSON)
            bindTextOrNull(stmt, 28, profile.elementAliasesJSON)
            sqlite3_bind_double(stmt, 29, now)

            sqlite3_step(stmt)
        }
    }

    /// Get an app profile by bundle ID.
    public func getAppProfile(bundleID: String) -> AppProfileRecord? {
        queue.sync {
            let sql = "SELECT * FROM app_profiles WHERE bundle_id = ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            bindText(stmt, 1, bundleID)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return readAppProfileRow(stmt)
        }
    }

    // MARK: - Stats

    /// Get database statistics for the `computer db stats` command.
    public func stats() -> DatabaseStats {
        queue.sync {
            DatabaseStats(
                elementCount: countRows("elements"),
                patternCount: countRows("patterns"),
                correctionCount: countRows("corrections"),
                workflowCount: countRows("workflows"),
                failureCount: countRows("failures"),
                appProfileCount: countRows("app_profiles")
            )
        }
    }

    private func countRows(_ table: String) -> Int {
        let sql = "SELECT COUNT(*) FROM \(table)"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Reduce confidence for all elements of an app (used by DriftDetector).
    public func reduceConfidence(appBundleID: String, factor: Float) {
        queue.sync {
            let sql = "UPDATE elements SET confidence = confidence * ? WHERE app_bundle_id = ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_double(stmt, 1, Double(factor))
            bindText(stmt, 2, appBundleID)
            sqlite3_step(stmt)
        }
    }

    // MARK: - SQLite Helpers

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        // SQLITE_TRANSIENT (not nil/SQLITE_STATIC): the autoreleased C string from
        // `(value as NSString).utf8String` is transient — SQLite must copy it now,
        // otherwise `sqlite3_step` later reads freed memory.
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
    }

    private func bindTextOrNull(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let v = value {
            sqlite3_bind_text(stmt, index, (v as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func getString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    // MARK: - Row Readers

    private func readElementRow(_ stmt: OpaquePointer?) -> ElementRecord {
        ElementRecord(
            hash: getString(stmt, 0) ?? "",
            appBundleID: getString(stmt, 1),
            role: getString(stmt, 2) ?? "",
            label: getString(stmt, 3) ?? "",
            customLabel: getString(stmt, 4),
            structuralSignature: getString(stmt, 5),
            visualHash: getString(stmt, 6),
            confidence: Float(sqlite3_column_double(stmt, 7)),
            timesSeen: Int(sqlite3_column_int(stmt, 8)),
            timesCorrect: Int(sqlite3_column_int(stmt, 9)),
            timesWrong: Int(sqlite3_column_int(stmt, 10)),
            firstSeen: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11)),
            lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12)),
            lastConfirmed: sqlite3_column_type(stmt, 13) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13)) : nil,
            isUniversal: sqlite3_column_int(stmt, 14) != 0,
            behavior: getString(stmt, 15),
            metadataJSON: getString(stmt, 16)
        )
    }

    private func readCorrectionRow(_ stmt: OpaquePointer?) -> CorrectionRecord {
        CorrectionRecord(
            id: Int(sqlite3_column_int(stmt, 0)),
            elementHash: getString(stmt, 1),
            expectedLabel: getString(stmt, 2),
            actualLabel: getString(stmt, 3) ?? "",
            appBundleID: getString(stmt, 4),
            windowContext: getString(stmt, 5),
            intendedAction: getString(stmt, 6),
            selectedSignature: getString(stmt, 7),
            correctSignature: getString(stmt, 8),
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
        )
    }

    private func readPatternRow(_ stmt: OpaquePointer?) -> PatternRecord {
        PatternRecord(
            id: getString(stmt, 0) ?? "",
            signature: getString(stmt, 1) ?? "",
            meaning: getString(stmt, 2) ?? "",
            confidence: Float(sqlite3_column_double(stmt, 3)),
            appsSeenIn: getString(stmt, 4),
            timesConfirmed: Int(sqlite3_column_int(stmt, 5)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
        )
    }

    private func readWorkflowRow(_ stmt: OpaquePointer?) -> WorkflowRecord {
        WorkflowRecord(
            id: getString(stmt, 0) ?? "",
            name: getString(stmt, 1) ?? "",
            appBundleID: getString(stmt, 2),
            stepsJSON: getString(stmt, 3) ?? "[]",
            timesReplayed: Int(sqlite3_column_int(stmt, 4)),
            successCount: Int(sqlite3_column_int(stmt, 5)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
            lastReplayed: sqlite3_column_type(stmt, 7) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)) : nil
        )
    }

    private func readFailureRow(_ stmt: OpaquePointer?) -> FailureRecord {
        FailureRecord(
            id: Int(sqlite3_column_int(stmt, 0)),
            workflowID: getString(stmt, 1),
            stepIndex: sqlite3_column_type(stmt, 2) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 2)) : nil,
            expectedStateJSON: getString(stmt, 3),
            actualStateJSON: getString(stmt, 4),
            elementRef: getString(stmt, 5),
            actionAttempted: getString(stmt, 6),
            errorDescription: getString(stmt, 7),
            appBundleID: getString(stmt, 8),
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
        )
    }

    private func readAppProfileRow(_ stmt: OpaquePointer?) -> AppProfileRecord {
        AppProfileRecord(
            bundleID: getString(stmt, 0) ?? "",
            appName: getString(stmt, 1) ?? "",
            appVersion: getString(stmt, 2),
            needsOCR: sqlite3_column_int(stmt, 3) != 0,
            axCoveragePct: sqlite3_column_type(stmt, 4) != SQLITE_NULL ? Float(sqlite3_column_double(stmt, 4)) : nil,
            elementCountAvg: sqlite3_column_type(stmt, 5) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 5)) : nil,
            interactiveCountAvg: sqlite3_column_type(stmt, 6) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 6)) : nil,
            structuralHash: getString(stmt, 7),
            roleDistributionJSON: getString(stmt, 8),
            toolbarSignature: getString(stmt, 9),
            menuBarItemsJSON: getString(stmt, 10),
            customRolesJSON: getString(stmt, 11),
            elementAliasesJSON: getString(stmt, 12),
            lastProfiled: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13)),
            profiledBy: getString(stmt, 14) ?? "auto",
            profileVersion: Int(sqlite3_column_int(stmt, 15))
        )
    }
}

// MARK: - Record Types

public struct ElementRecord: Sendable {
    public let hash: String
    public let appBundleID: String?
    public let role: String
    public let label: String
    public let customLabel: String?
    public let structuralSignature: String?
    public let visualHash: String?
    public let confidence: Float
    public let timesSeen: Int
    public let timesCorrect: Int
    public let timesWrong: Int
    public let firstSeen: Date
    public let lastSeen: Date
    public let lastConfirmed: Date?
    public let isUniversal: Bool
    public let behavior: String?
    public let metadataJSON: String?

    public init(hash: String, appBundleID: String?, role: String, label: String, customLabel: String?, structuralSignature: String?, visualHash: String?, confidence: Float, timesSeen: Int, timesCorrect: Int, timesWrong: Int, firstSeen: Date, lastSeen: Date, lastConfirmed: Date?, isUniversal: Bool, behavior: String?, metadataJSON: String?) {
        self.hash = hash; self.appBundleID = appBundleID; self.role = role; self.label = label
        self.customLabel = customLabel; self.structuralSignature = structuralSignature
        self.visualHash = visualHash; self.confidence = confidence; self.timesSeen = timesSeen
        self.timesCorrect = timesCorrect; self.timesWrong = timesWrong
        self.firstSeen = firstSeen; self.lastSeen = lastSeen; self.lastConfirmed = lastConfirmed
        self.isUniversal = isUniversal; self.behavior = behavior; self.metadataJSON = metadataJSON
    }
}

public struct CorrectionRecord: Sendable {
    public let id: Int
    public let elementHash: String?
    public let expectedLabel: String?
    public let actualLabel: String
    public let appBundleID: String?
    public let windowContext: String?
    public let intendedAction: String?
    public let selectedSignature: String?
    public let correctSignature: String?
    public let timestamp: Date

    public init(id: Int, elementHash: String?, expectedLabel: String?, actualLabel: String, appBundleID: String?, windowContext: String?, intendedAction: String?, selectedSignature: String?, correctSignature: String?, timestamp: Date) {
        self.id = id; self.elementHash = elementHash; self.expectedLabel = expectedLabel
        self.actualLabel = actualLabel; self.appBundleID = appBundleID
        self.windowContext = windowContext; self.intendedAction = intendedAction
        self.selectedSignature = selectedSignature; self.correctSignature = correctSignature
        self.timestamp = timestamp
    }
}

public struct PatternRecord: Sendable {
    public let id: String
    public let signature: String
    public let meaning: String
    public let confidence: Float
    public let appsSeenIn: String?
    public let timesConfirmed: Int
    public let createdAt: Date

    public init(id: String, signature: String, meaning: String, confidence: Float, appsSeenIn: String?, timesConfirmed: Int, createdAt: Date) {
        self.id = id; self.signature = signature; self.meaning = meaning
        self.confidence = confidence; self.appsSeenIn = appsSeenIn
        self.timesConfirmed = timesConfirmed; self.createdAt = createdAt
    }
}

public struct WorkflowRecord: Sendable {
    public let id: String
    public let name: String
    public let appBundleID: String?
    public let stepsJSON: String
    public let timesReplayed: Int
    public let successCount: Int
    public let createdAt: Date
    public let lastReplayed: Date?

    public init(id: String, name: String, appBundleID: String?, stepsJSON: String, timesReplayed: Int, successCount: Int, createdAt: Date, lastReplayed: Date?) {
        self.id = id; self.name = name; self.appBundleID = appBundleID
        self.stepsJSON = stepsJSON; self.timesReplayed = timesReplayed
        self.successCount = successCount; self.createdAt = createdAt; self.lastReplayed = lastReplayed
    }
}

public struct FailureRecord: Sendable {
    public let id: Int
    public let workflowID: String?
    public let stepIndex: Int?
    public let expectedStateJSON: String?
    public let actualStateJSON: String?
    public let elementRef: String?
    public let actionAttempted: String?
    public let errorDescription: String?
    public let appBundleID: String?
    public let timestamp: Date

    public init(id: Int, workflowID: String?, stepIndex: Int?, expectedStateJSON: String?, actualStateJSON: String?, elementRef: String?, actionAttempted: String?, errorDescription: String?, appBundleID: String?, timestamp: Date) {
        self.id = id; self.workflowID = workflowID; self.stepIndex = stepIndex
        self.expectedStateJSON = expectedStateJSON; self.actualStateJSON = actualStateJSON
        self.elementRef = elementRef; self.actionAttempted = actionAttempted
        self.errorDescription = errorDescription; self.appBundleID = appBundleID; self.timestamp = timestamp
    }
}

public struct AppProfileRecord: Sendable {
    public let bundleID: String
    public let appName: String
    public let appVersion: String?
    public let needsOCR: Bool
    public let axCoveragePct: Float?
    public let elementCountAvg: Int?
    public let interactiveCountAvg: Int?
    public let structuralHash: String?
    public let roleDistributionJSON: String?
    public let toolbarSignature: String?
    public let menuBarItemsJSON: String?
    public let customRolesJSON: String?
    public let elementAliasesJSON: String?
    public let lastProfiled: Date
    public let profiledBy: String
    public let profileVersion: Int

    public init(bundleID: String, appName: String, appVersion: String?, needsOCR: Bool, axCoveragePct: Float?, elementCountAvg: Int?, interactiveCountAvg: Int?, structuralHash: String?, roleDistributionJSON: String?, toolbarSignature: String?, menuBarItemsJSON: String?, customRolesJSON: String?, elementAliasesJSON: String?, lastProfiled: Date, profiledBy: String, profileVersion: Int) {
        self.bundleID = bundleID; self.appName = appName; self.appVersion = appVersion
        self.needsOCR = needsOCR; self.axCoveragePct = axCoveragePct
        self.elementCountAvg = elementCountAvg; self.interactiveCountAvg = interactiveCountAvg
        self.structuralHash = structuralHash; self.roleDistributionJSON = roleDistributionJSON
        self.toolbarSignature = toolbarSignature; self.menuBarItemsJSON = menuBarItemsJSON
        self.customRolesJSON = customRolesJSON; self.elementAliasesJSON = elementAliasesJSON
        self.lastProfiled = lastProfiled; self.profiledBy = profiledBy; self.profileVersion = profileVersion
    }
}

public struct DatabaseStats: Sendable {
    public let elementCount: Int
    public let patternCount: Int
    public let correctionCount: Int
    public let workflowCount: Int
    public let failureCount: Int
    public let appProfileCount: Int

    public init(elementCount: Int, patternCount: Int, correctionCount: Int, workflowCount: Int, failureCount: Int, appProfileCount: Int) {
        self.elementCount = elementCount; self.patternCount = patternCount
        self.correctionCount = correctionCount; self.workflowCount = workflowCount
        self.failureCount = failureCount; self.appProfileCount = appProfileCount
    }
}
