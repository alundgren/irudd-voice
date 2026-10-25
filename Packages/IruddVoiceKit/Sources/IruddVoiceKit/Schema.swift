import Foundation

/// The database contract. The app is the only process that creates or
/// changes the schema; the CLI checks `PRAGMA user_version` and refuses to
/// write to a version it doesn't know. See docs/database.md.
public enum Schema {
    public static let currentVersion = 1

    public static var defaultPath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("irudd-voice/voice.sqlite").path
    }

    /// Opens the database at `path`, creating the folder and migrating to
    /// the current version. Refuses a database from a newer app.
    public static func open(path: String = defaultPath) throws -> Database {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let db = try Database(path: path)
        try migrate(db)
        return db
    }

    public static func migrate(_ db: Database) throws {
        try db.transaction {
            let version = try db.userVersion
            if version > currentVersion {
                throw DatabaseError(message:
                    "The database is schema version \(version), but this app only knows up to \(currentVersion). Update irudd-voice.")
            }
            if version < 1 {
                try db.execute(v1)
                try db.execute("PRAGMA user_version = 1")
            }
        }
    }

    /// Every table later work needs, so the CLI and app agree from day one.
    static let v1 = """
    CREATE TABLE chunks (
        id INTEGER PRIMARY KEY,
        uuid TEXT NOT NULL UNIQUE,
        status TEXT NOT NULL CHECK (status IN ('pending', 'transcribed', 'error', 'discarded')),
        error TEXT,
        started_at TEXT NOT NULL,
        signal_at TEXT NOT NULL,
        ended_at TEXT NOT NULL,
        local_day TEXT NOT NULL,
        utc_offset_minutes INTEGER NOT NULL,
        duration_ms INTEGER NOT NULL,
        start_reason TEXT NOT NULL,
        end_reason TEXT NOT NULL,
        mic_uid TEXT NOT NULL,
        mic_name TEXT,
        mic_model_uid TEXT,
        audio BLOB NOT NULL,
        audio_format TEXT NOT NULL,
        audio_sample_rate INTEGER NOT NULL,
        audio_bytes INTEGER NOT NULL,
        target_app_bundle_id TEXT,
        target_app_name TEXT,
        raw_text TEXT,
        recognizer TEXT,
        transcribed_at TEXT,
        cleaned_text TEXT,
        cleanup_model_id TEXT,
        cleanup_status TEXT,
        cleanup_ms INTEGER,
        pasted_text TEXT,
        paste_status TEXT,
        pasted_at TEXT,
        schema_version INTEGER NOT NULL,
        app_version TEXT NOT NULL,
        prompt_version TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );
    CREATE INDEX chunks_status ON chunks (status);
    CREATE INDEX chunks_local_day ON chunks (local_day);

    CREATE TABLE labels (
        id INTEGER PRIMARY KEY,
        chunk_id INTEGER NOT NULL REFERENCES chunks (id) ON DELETE CASCADE,
        text TEXT,
        status TEXT NOT NULL CHECK (status IN ('accepted', 'rejected')),
        reject_reason TEXT,
        teacher TEXT NOT NULL,
        teacher_model TEXT,
        teacher_prompt_version TEXT NOT NULL,
        cost_usd REAL,
        input_tokens INTEGER,
        output_tokens INTEGER,
        frozen INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
    );
    CREATE INDEX labels_chunk ON labels (chunk_id);

    CREATE TABLE dataset_days (
        local_day TEXT PRIMARY KEY,
        split TEXT NOT NULL CHECK (split IN ('train', 'selection', 'test')),
        assigned_at TEXT NOT NULL
    );

    CREATE TABLE models (
        id TEXT PRIMARY KEY,
        base_repo TEXT NOT NULL,
        base_revision TEXT NOT NULL,
        manifest_json TEXT NOT NULL,
        prompt_version TEXT,
        dataset_hash TEXT,
        trained_chunks INTEGER,
        trained_at TEXT,
        eval_report_json TEXT,
        created_at TEXT NOT NULL
    );

    CREATE TABLE active_model (
        slot INTEGER PRIMARY KEY CHECK (slot = 1),
        model_id TEXT REFERENCES models (id),
        previous_model_id TEXT REFERENCES models (id),
        changed_at TEXT NOT NULL
    );

    CREATE TABLE events (
        id INTEGER PRIMARY KEY,
        at TEXT NOT NULL,
        level TEXT NOT NULL CHECK (level IN ('info', 'warning', 'error')),
        category TEXT NOT NULL,
        message TEXT NOT NULL,
        chunk_id INTEGER REFERENCES chunks (id) ON DELETE SET NULL
    );
    CREATE INDEX events_at ON events (at);

    CREATE TABLE app_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );
    """
}
