import Foundation

/// Journey execution shares the event database and its writer.
enum CustomerStoreSchema {
    static let stateVersion = "device-customer-state-v1"
    static let owner = "authority_scope TEXT NOT NULL, user_id TEXT NOT NULL"
    static let key = "authority_scope,user_id"
    static let journeyKey = "authority_scope,user_id,journey_id,leg_generation"
    static let journeyIdentity = "journey_id TEXT NOT NULL, leg_generation INTEGER NOT NULL CHECK(leg_generation >= 0)"
    static let scopeReference = "FOREIGN KEY(authority_scope,user_id) REFERENCES customer_scopes(authority_scope,user_id)"
    static let journeyReference = "FOREIGN KEY(\(journeyKey)) REFERENCES journeys(\(journeyKey)) ON DELETE CASCADE"

    static let tables: [(String, String)] = [
        ("customer_store_metadata", """
        id INTEGER PRIMARY KEY CHECK(id=1), state_version TEXT NOT NULL,
        next_capture_sequence INTEGER NOT NULL CHECK(typeof(next_capture_sequence)='integer' AND next_capture_sequence > 0),
        cutover_sequence INTEGER NOT NULL CHECK(cutover_sequence >= 0),
        legacy_cleanup_pending INTEGER NOT NULL CHECK(legacy_cleanup_pending IN (0,1))
        """),
        ("customer_scopes", """
        \(owner), execution_epoch INTEGER NOT NULL CHECK(execution_epoch >= 0),
        execution_revoked INTEGER NOT NULL CHECK(execution_revoked IN (0,1)),
        opened_state_version TEXT NOT NULL, PRIMARY KEY(\(key))
        """),
        ("journey_execution_snapshots", """
        \(owner), snapshot_id TEXT NOT NULL, delivery_json BLOB NOT NULL,
        assignments_json BLOB NOT NULL, customer_json BLOB NOT NULL,
        PRIMARY KEY(\(key),snapshot_id), \(scopeReference)
        """),
        ("journeys", """
        \(owner), \(journeyIdentity), experience_id TEXT NOT NULL, version_id TEXT NOT NULL,
        leg_id TEXT NOT NULL, descriptor_sha256 TEXT NOT NULL, policy_hash TEXT NOT NULL,
        snapshot_id TEXT NOT NULL, frequency_json BLOB NOT NULL, started_at INTEGER NOT NULL,
        is_enrollment INTEGER NOT NULL CHECK(is_enrollment IN (0,1)), started_event_id TEXT NOT NULL,
        completed_event_id TEXT NOT NULL, step_id TEXT NOT NULL,
        cursor_revision INTEGER NOT NULL CHECK(cursor_revision >= 0),
        status TEXT NOT NULL CHECK(status IN ('executing','waiting','awaiting_native_result','awaiting_presentation')),
        context_json BLOB NOT NULL, outputs_json BLOB NOT NULL, native_snapshot_json BLOB,
        authored_close_outcome TEXT, PRIMARY KEY(\(journeyKey)), UNIQUE(\(key),experience_id),
        \(scopeReference), FOREIGN KEY(\(key),snapshot_id)
        REFERENCES journey_execution_snapshots(\(key),snapshot_id)
        """),
        ("journey_cursors", """
        \(owner), \(journeyIdentity), input_event_id TEXT, evaluation_at INTEGER, initial_lag_ms INTEGER,
        responses_changed INTEGER NOT NULL CHECK(responses_changed IN (0,1)), last_consumed_at INTEGER,
        last_consumed_event_id TEXT, presentation_source_event_id TEXT, presentation_source_json BLOB,
        next_presentation_batch_sequence INTEGER NOT NULL CHECK(next_presentation_batch_sequence >= 0),
        next_presentation_emission_sequence INTEGER NOT NULL CHECK(next_presentation_emission_sequence >= 0),
        PRIMARY KEY(\(journeyKey)), \(journeyReference),
        FOREIGN KEY(authority_scope,user_id,input_event_id) REFERENCES events(scope,user_id,id),
        FOREIGN KEY(authority_scope,user_id,presentation_source_event_id) REFERENCES events(scope,user_id,id)
        """),
        ("journey_waits", """
        \(owner), \(journeyIdentity), wait_revision INTEGER NOT NULL CHECK(wait_revision >= 0),
        step_id TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('event','response','delay','time_window')),
        started_at INTEGER NOT NULL, deadline_at INTEGER, query_after_at INTEGER, query_after_event_id TEXT,
        PRIMARY KEY(\(journeyKey)), \(journeyReference)
        """),
        ("journey_frequency", """
        \(owner), experience_id TEXT NOT NULL, last_started_at INTEGER NOT NULL,
        ever_started INTEGER NOT NULL CHECK(ever_started IN (0,1)), PRIMARY KEY(\(key),experience_id), \(scopeReference)
        """),
        ("journey_arm_receipts", """
        \(owner), arm_key TEXT NOT NULL, reference_json BLOB NOT NULL, binding_json BLOB NOT NULL,
        entry_kind TEXT NOT NULL CHECK(entry_kind IN ('event','segment','app_foregrounded')),
        foreground_session_id TEXT, highest_generation INTEGER CHECK(highest_generation >= 0),
        state TEXT NOT NULL CHECK(state IN ('consumed','completed')), report_event_id TEXT,
        PRIMARY KEY(\(key),arm_key), \(scopeReference)
        """),
        ("journey_event_applications", """
        \(owner), event_id TEXT NOT NULL, target_key TEXT NOT NULL, journey_id TEXT, leg_generation INTEGER,
        cursor_revision INTEGER, decision TEXT NOT NULL CHECK(decision IN ('applied','declined','obsolete')),
        applied_at INTEGER NOT NULL, PRIMARY KEY(\(key),event_id,target_key), \(scopeReference),
        CHECK((journey_id IS NULL) = (leg_generation IS NULL)),
        FOREIGN KEY(authority_scope,user_id,event_id) REFERENCES events(scope,user_id,id)
        """),
        ("journey_effects", """
        \(owner), \(journeyIdentity), effect_id TEXT NOT NULL, step_id TEXT NOT NULL, kind TEXT NOT NULL,
        state TEXT NOT NULL CHECK(state IN ('claimed','awaiting_result','applied','rejected')),
        context_json BLOB, placement_id TEXT, result_event_id TEXT, settled_at INTEGER,
        PRIMARY KEY(\(key),effect_id), \(scopeReference),
        FOREIGN KEY(authority_scope,user_id,result_event_id) REFERENCES events(scope,user_id,id)
        """),
        ("journey_experiment_selections", """
        \(owner), \(journeyIdentity), experiment_id TEXT NOT NULL, variant_id TEXT NOT NULL,
        is_holdout INTEGER NOT NULL CHECK(is_holdout IN (0,1)),
        kind TEXT NOT NULL CHECK(kind IN ('assigned','fallback')), event_id TEXT NOT NULL,
        selected_at INTEGER NOT NULL, presentation_screen_id TEXT, shown_at INTEGER,
        PRIMARY KEY(\(journeyKey),experiment_id), \(journeyReference)
        """),
        ("journey_conversion_watches", """
        \(owner), journey_id TEXT NOT NULL, experience_id TEXT NOT NULL, version_id TEXT NOT NULL,
        policy_hash TEXT NOT NULL, goal_json BLOB NOT NULL, entry_context_json BLOB NOT NULL,
        started_at INTEGER NOT NULL, basis_event_id TEXT, basis_at INTEGER, expires_at INTEGER,
        conversion_event_id TEXT, conversion_at INTEGER, server_revision INTEGER, leg_completed_at INTEGER,
        retain_until INTEGER NOT NULL, PRIMARY KEY(\(key),journey_id), \(scopeReference)
        """),
        ("journey_response_saves", """
        \(owner), journey_id TEXT NOT NULL, form_name TEXT NOT NULL, experience_id TEXT NOT NULL,
        version_id TEXT NOT NULL, sequence INTEGER NOT NULL CHECK(typeof(sequence)='integer' AND sequence BETWEEN 0 AND 9007199254740991),
        pending_sequence INTEGER CHECK(pending_sequence IS NULL OR (typeof(pending_sequence)='integer' AND pending_sequence > 0 AND pending_sequence <= sequence)),
        pending_answers_json BLOB, display_sequence INTEGER CHECK(display_sequence IS NULL OR (typeof(display_sequence)='integer' AND display_sequence > 0 AND display_sequence <= sequence)),
        saving INTEGER NOT NULL CHECK(saving IN (0,1)), saved INTEGER NOT NULL CHECK(saved IN (0,1)),
        save_error TEXT NOT NULL, attempts INTEGER NOT NULL CHECK(attempts >= 0), observed_at INTEGER,
        next_attempt_at INTEGER, unknown_form_since INTEGER, last_code TEXT,
        PRIMARY KEY(\(key),journey_id,form_name), \(scopeReference),
        CHECK((pending_sequence IS NULL) = (pending_answers_json IS NULL)),
        CHECK((observed_at IS NULL) = (next_attempt_at IS NULL)),
        CHECK((observed_at IS NULL) = (last_code IS NULL)),
        CHECK(display_sequence IS NOT NULL OR (saving=0 AND saved=0 AND save_error=''))
        """),
        ("journey_release_pins", """
        \(owner), \(journeyIdentity), object_sha256 TEXT NOT NULL,
        kind TEXT NOT NULL CHECK(kind IN ('descriptor','artifact')), relative_path TEXT NOT NULL,
        size_bytes INTEGER NOT NULL CHECK(size_bytes >= 0),
        PRIMARY KEY(\(journeyKey),object_sha256,kind), \(journeyReference)
        """),
        ("journey_pending_work", """
        \(owner), work_key TEXT NOT NULL, kind TEXT NOT NULL, journey_id TEXT, leg_generation INTEGER,
        expected_cursor_revision INTEGER, input_event_id TEXT, target_key TEXT,
        state TEXT NOT NULL CHECK(state IN ('pending','failed','not_yet')),
        attempts INTEGER NOT NULL CHECK(attempts >= 0), observed_at INTEGER NOT NULL,
        next_attempt_at INTEGER NOT NULL, last_error TEXT, PRIMARY KEY(\(key),work_key), \(scopeReference),
        CHECK((journey_id IS NULL) = (leg_generation IS NULL)),
        FOREIGN KEY(authority_scope,user_id,input_event_id) REFERENCES events(scope,user_id,id)
        """),
    ]

    static let indexes: [(String, String)] = [
        ("idx_events_scope_name_time", "events(scope,user_id,name,timestamp,id)"),
        ("idx_events_scope_time", "events(scope,user_id,timestamp,id)"),
        ("idx_events_measurement", "events(scope,user_id,measurement_state,capture_sequence)"),
        ("idx_events_journey_role", "events(scope,user_id,journey_id,leg_generation,event_role)"),
        ("idx_journey_waits_deadline", "journey_waits(authority_scope,user_id,deadline_at)"),
        ("idx_journey_pending_work_due", "journey_pending_work(next_attempt_at,authority_scope,user_id,journey_id)"),
        ("idx_journey_watches_expiry", "journey_conversion_watches(authority_scope,user_id,expires_at,basis_at)"),
        ("idx_journey_effect_results", "journey_effects(authority_scope,user_id,result_event_id)"),
    ]

    static let eventColumns = [
        "capture_scope TEXT NOT NULL DEFAULT 'legacy-unknown'", "authority_scope TEXT",
        "scope TEXT NOT NULL DEFAULT 'legacy-unknown'", "capture_sequence INTEGER NOT NULL DEFAULT 0 CHECK(typeof(capture_sequence)='integer' AND capture_sequence >= 0)",
        "accepted_at INTEGER NOT NULL DEFAULT 0",
        "journey_plan_state TEXT NOT NULL DEFAULT 'pending' CHECK(journey_plan_state IN ('pending','planned','done','retired'))",
        "measurement_state TEXT NOT NULL DEFAULT 'pending' CHECK(measurement_state IN ('pending','done'))",
        "input_kind TEXT NOT NULL DEFAULT 'event' CHECK(input_kind IN ('event','response_change'))",
        "journey_id TEXT", "leg_generation INTEGER", "event_role TEXT", "session_id TEXT",
    ]

    static var installSQL: String {
        tables.map { "CREATE TABLE \($0.0) (\($0.1));" }.joined(separator: "\n") + """
        INSERT INTO customer_store_metadata VALUES(1,'legacy',1,0,0);
        """
    }

    static let eventSequenceSQL = """
    UPDATE customer_store_metadata SET next_capture_sequence = MAX(1,(SELECT COALESCE(MAX(capture_sequence),0)+1 FROM events)) WHERE id=1;
    CREATE UNIQUE INDEX idx_events_capture_sequence ON events(capture_sequence) WHERE capture_sequence > 0;
    CREATE TRIGGER journey_effect_result_identity BEFORE UPDATE OF result_event_id ON journey_effects
    WHEN OLD.result_event_id IS NOT NULL AND NEW.result_event_id IS NOT OLD.result_event_id BEGIN
      SELECT RAISE(ABORT,'Effect result identity is immutable');
    END;
    CREATE TRIGGER events_allocate_capture_sequence AFTER INSERT ON events BEGIN
      SELECT CASE WHEN (SELECT COUNT(*) FROM customer_store_metadata WHERE id=1)=0
        OR (SELECT next_capture_sequence FROM customer_store_metadata WHERE id=1)>=9223372036854775807
        THEN RAISE(ABORT,'Capture sequence is unavailable') END;
      UPDATE events SET capture_sequence=(SELECT next_capture_sequence FROM customer_store_metadata WHERE id=1) WHERE id=NEW.id;
      UPDATE customer_store_metadata SET next_capture_sequence=next_capture_sequence+1 WHERE id=1;
    END;
    """

    static let historySQL = """
    ALTER TABLE event_history_metadata RENAME TO legacy_event_history_metadata;
    CREATE TABLE event_history_metadata (
      scope TEXT NOT NULL, user_id TEXT NOT NULL, coverage_start_ms INTEGER NOT NULL,
      PRIMARY KEY(scope,user_id)
    );
    -- Transitional coverage for the existing global history API and pruning path. Layer 3 removes this row and those callers.
    INSERT INTO event_history_metadata SELECT 'legacy-global','',coverage_start_ms FROM legacy_event_history_metadata;
    DROP TABLE legacy_event_history_metadata;
    """
}
