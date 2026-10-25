import Foundation

/// The database contract. The app is the only process that creates or
/// changes the schema; the CLI checks `PRAGMA user_version` and refuses to
/// write to a version it doesn't know. See docs/database.md.
public enum Schema {

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

    /// Migration SQL, in order: index 0 takes version 0 to 1, and so on.
    public static let migrations = [v1]
    public static var currentVersion: Int { migrations.count }

    /// Brings the database up to the newest schema. Before changing a
    /// database that already has data, it writes a full copy with VACUUM
    /// INTO to `backups/` next to it, after checking there's room. If there
    /// isn't, it stops before changing anything.
    public static func migrate(
        _ db: Database,
        migrations: [String] = migrations,
        freeSpace: (String) -> Int64? = Schema.freeSpace,
        progress: (MigrationStep) -> Void = { _ in }
    ) throws {
        let target = migrations.count
        let version = try db.userVersion
        if version > target {
            throw DatabaseError(message:
                "The database is schema version \(version), but this app only knows up to \(target). Update irudd-voice.")
        }
        guard version < target else { return }

        if version > 0 {
            let folder = ((db.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("backups")
            let size = Self.sizeOnDisk(db.path)
            let needed = size * 2 + 50_000_000
            if let free = freeSpace(folder.isEmpty ? db.path : (db.path as NSString).deletingLastPathComponent),
               free < needed {
                throw DatabaseError(message: """
                    Updating the database needs \(needed / 1_000_000) MB free for a backup first, but only \
                    \(free / 1_000_000) MB is free. Nothing was changed. Free up some space and start the app again.
                    """)
            }
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let stamp = Timestamps.string(Date()).replacingOccurrences(of: ":", with: "-")
            let backup = (folder as NSString).appendingPathComponent("voice-v\(version)-\(stamp).sqlite")
            progress(.backingUp(path: backup, bytes: size))
            try db.query("VACUUM INTO ?", [.text(backup)])
        }

        try db.transaction {
            for next in version..<target {
                progress(.migrating(from: next, to: next + 1))
                try db.execute(migrations[next])
                try db.execute("PRAGMA user_version = \(next + 1)")
            }
        }
    }

    public enum MigrationStep: Equatable {
        case backingUp(path: String, bytes: Int64)
        case migrating(from: Int, to: Int)
    }

    public static func freeSpace(_ folder: String) -> Int64? {
        let url = URL(fileURLWithPath: folder)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func sizeOnDisk(_ path: String) -> Int64 {
        [path, path + "-wal"].reduce(0) { total, file in
            total + ((try? FileManager.default.attributesOfItem(atPath: file)[.size] as? NSNumber)?.int64Value ?? 0)
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
