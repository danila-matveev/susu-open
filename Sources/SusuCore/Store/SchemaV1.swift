import GRDB

/// Migration "v1": the whole schema of spec 5.2, so parallel tasks never fight over it.
/// Every table has `updated_at` (bumped by an AFTER UPDATE trigger) and `deleted_at`.
/// Never run VACUUM on this database: the FTS5 indexes are keyed by implicit rowid.
enum SchemaV1 {
    static func migrate(_ db: Database) throws {
        let now = "strftime('%Y-%m-%dT%H:%M:%fZ','now')"
        let sync = "updated_at TEXT NOT NULL DEFAULT (\(now)), deleted_at TEXT"

        try db.execute(sql: """
            CREATE TABLE dictation (
                id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL DEFAULT 'dictation',
                created_at TEXT NOT NULL,
                duration_ms INTEGER,
                mode TEXT,
                status TEXT NOT NULL,
                app_name TEXT, bundle_id TEXT, window_title TEXT, url TEXT,
                style_id TEXT,
                stt_provider TEXT, stt_model TEXT, editor_model TEXT,
                fallback_used INTEGER NOT NULL DEFAULT 0,
                raw_text TEXT, final_text TEXT, edited_text TEXT,
                language TEXT,
                latency_ms INTEGER,
                audio_path TEXT,
                cost_usd REAL,
                source TEXT NOT NULL DEFAULT 'susu', source_id TEXT,
                \(sync)
            );
            CREATE INDEX dictation_created_at ON dictation(created_at);
            CREATE INDEX dictation_bundle_id ON dictation(bundle_id);
            CREATE UNIQUE INDEX dictation_source ON dictation(source, source_id) WHERE source_id IS NOT NULL;

            CREATE TABLE agent_request (
                dictation_id TEXT PRIMARY KEY NOT NULL REFERENCES dictation(id),
                context_json TEXT, skill TEXT, model TEXT, steps_json TEXT, card_json TEXT,
                status TEXT NOT NULL DEFAULT 'answered',
                result_json TEXT, undo_json TEXT,
                latency_card_ms INTEGER, cost_usd REAL,
                source TEXT NOT NULL DEFAULT 'voice',
                \(sync)
            );

            CREATE TABLE dictionary_entry (
                id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                phrase TEXT NOT NULL,
                replacement TEXT,
                starred INTEGER NOT NULL DEFAULT 0,
                origin TEXT NOT NULL DEFAULT 'manual',
                use_count INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                source TEXT, source_id TEXT,
                \(sync)
            );
            CREATE UNIQUE INDEX dictionary_entry_source ON dictionary_entry(source, source_id) WHERE source_id IS NOT NULL;

            CREATE TABLE style (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                prompt TEXT NOT NULL DEFAULT '',
                cleanup_level TEXT NOT NULL DEFAULT 'normal',
                voice_commands INTEGER NOT NULL DEFAULT 0,
                is_default INTEGER NOT NULL DEFAULT 0,
                sort INTEGER NOT NULL DEFAULT 0,
                \(sync)
            );
            CREATE TABLE style_rule (
                id TEXT PRIMARY KEY NOT NULL,
                style_id TEXT NOT NULL REFERENCES style(id),
                kind TEXT NOT NULL,
                pattern TEXT NOT NULL,
                priority INTEGER NOT NULL DEFAULT 0,
                \(sync)
            );
            CREATE INDEX style_rule_style ON style_rule(style_id);

            CREATE TABLE call (
                id TEXT PRIMARY KEY NOT NULL,
                started_at TEXT NOT NULL, ended_at TEXT,
                title TEXT, app_bundle_id TEXT, calendar_event_id TEXT,
                participants_json TEXT, language_mode TEXT,
                status TEXT NOT NULL DEFAULT 'recording',
                audio_path TEXT, notes TEXT, summary_json TEXT,
                stt_provider TEXT, summary_model TEXT, cost_usd REAL,
                source TEXT NOT NULL DEFAULT 'susu', source_id TEXT,
                \(sync)
            );
            CREATE INDEX call_started_at ON call(started_at);
            CREATE UNIQUE INDEX call_source ON call(source, source_id) WHERE source_id IS NOT NULL;

            CREATE TABLE call_segment (
                id TEXT PRIMARY KEY NOT NULL,
                call_id TEXT NOT NULL REFERENCES call(id),
                channel TEXT NOT NULL,
                speaker_key TEXT,
                start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
                text TEXT NOT NULL,
                pass TEXT NOT NULL DEFAULT 'final',
                dropped_echo INTEGER NOT NULL DEFAULT 0,
                \(sync)
            );
            CREATE INDEX call_segment_call ON call_segment(call_id, start_ms);

            CREATE TABLE call_speaker (
                call_id TEXT NOT NULL REFERENCES call(id),
                speaker_key TEXT NOT NULL,
                display_name TEXT, email TEXT, confidence REAL,
                \(sync),
                PRIMARY KEY (call_id, speaker_key)
            );

            CREATE TABLE task_item (
                id TEXT PRIMARY KEY NOT NULL,
                call_id TEXT REFERENCES call(id),
                text TEXT NOT NULL,
                assignee TEXT, due TEXT, quote TEXT, quote_ms INTEGER,
                done INTEGER NOT NULL DEFAULT 0,
                sent_to TEXT, sent_ref TEXT,
                \(sync)
            );
            CREATE INDEX task_item_call ON task_item(call_id);

            CREATE TABLE note (
                id TEXT PRIMARY KEY NOT NULL,
                created_at TEXT NOT NULL,
                title TEXT, text TEXT,
                tags_json TEXT, audio_path TEXT,
                origin TEXT NOT NULL DEFAULT 'manual',
                source TEXT, source_id TEXT,
                \(sync)
            );
            CREATE UNIQUE INDEX note_source ON note(source, source_id) WHERE source_id IS NOT NULL;

            CREATE TABLE memory_fact (
                id TEXT PRIMARY KEY NOT NULL,
                text TEXT NOT NULL,
                origin TEXT NOT NULL DEFAULT 'manual',
                created_at TEXT NOT NULL,
                \(sync)
            );

            CREATE TABLE spend (
                id TEXT PRIMARY KEY NOT NULL,
                at TEXT NOT NULL,
                task TEXT NOT NULL,
                provider TEXT, model TEXT,
                audio_seconds REAL, tokens_in INTEGER, tokens_out INTEGER,
                cost_usd REAL NOT NULL DEFAULT 0,
                \(sync)
            );
            CREATE INDEX spend_at ON spend(at);

            CREATE TABLE import_run (
                id TEXT PRIMARY KEY NOT NULL,
                at TEXT NOT NULL,
                source TEXT NOT NULL,
                dry_run INTEGER NOT NULL DEFAULT 0,
                report_json TEXT,
                \(sync)
            );
            """)

        // updated_at: bumped on any update unless the writer set it explicitly (sync will do that).
        let tables = ["dictation", "agent_request", "dictionary_entry", "style", "style_rule", "call",
                      "call_segment", "call_speaker", "task_item", "note", "memory_fact", "spend", "import_run"]
        for t in tables {
            try db.execute(sql: """
                CREATE TRIGGER \(t)_touch AFTER UPDATE ON \(t)
                WHEN NEW.updated_at IS OLD.updated_at
                BEGIN
                    UPDATE \(t) SET updated_at = \(now) WHERE rowid = NEW.rowid;
                END;
                """)
        }

        try createFTS(db, table: "dictation", columns: ["raw_text", "final_text", "edited_text"])
        try createFTS(db, table: "call_segment", columns: ["text"])
        try createFTS(db, table: "note", columns: ["title", "text"])
    }

    /// External-content FTS5 index kept in sync by triggers.
    private static func createFTS(_ db: Database, table: String, columns: [String]) throws {
        let fts = "\(table)_fts"
        let cols = columns.joined(separator: ", ")
        let newVals = columns.map { "NEW.\($0)" }.joined(separator: ", ")
        let oldVals = columns.map { "OLD.\($0)" }.joined(separator: ", ")
        try db.execute(sql: """
            CREATE VIRTUAL TABLE \(fts) USING fts5(
                \(cols), content='\(table)', content_rowid='rowid',
                tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER \(table)_fts_ai AFTER INSERT ON \(table) BEGIN
                INSERT INTO \(fts)(rowid, \(cols)) VALUES (NEW.rowid, \(newVals));
            END;
            CREATE TRIGGER \(table)_fts_ad AFTER DELETE ON \(table) BEGIN
                INSERT INTO \(fts)(\(fts), rowid, \(cols)) VALUES ('delete', OLD.rowid, \(oldVals));
            END;
            CREATE TRIGGER \(table)_fts_au AFTER UPDATE OF \(cols) ON \(table) BEGIN
                INSERT INTO \(fts)(\(fts), rowid, \(cols)) VALUES ('delete', OLD.rowid, \(oldVals));
                INSERT INTO \(fts)(rowid, \(cols)) VALUES (NEW.rowid, \(newVals));
            END;
            """)
    }
}
