using BobLauncher;

namespace Snippets {
    public class Database {
        private Sqlite.Database db;
        private HashTable<string, SnippetMetadata> snippet_cache;

        private Sqlite.Statement insert_or_replace_stmt;
        private Sqlite.Statement delete_stmt;
        private Sqlite.Statement get_snippet_stmt;
        private Sqlite.Statement load_all_metadata_stmt;
        private Sqlite.Statement update_usage_stmt;
        private Sqlite.Statement check_exists_stmt;

        public class SnippetMetadata {
            public string key;
            public string mime_type;
            public string description;
            public string preview;
            public int64 created_at;
            public int64 last_used;
            public uint usage_count;

            public SnippetMetadata(string key, string mime_type, string? description, string preview,
                                  int64 created_at, int64 last_used, uint usage_count) {
                this.key = key;
                this.mime_type = mime_type;
                this.description = description ?? "";
                this.preview = preview;
                this.created_at = created_at;
                this.last_used = last_used;
                this.usage_count = usage_count;
            }
        }

        public class SnippetContent {
            public uint8[] data;
            public string mime_type;

            public SnippetContent(uint8[] data, string mime_type) {
                this.data = data;
                this.mime_type = mime_type;
            }
        }

        private const string[] setup_statements = {
            """
            CREATE TABLE IF NOT EXISTS snippets (
                key TEXT PRIMARY KEY,
                content BLOB NOT NULL,
                mime_type TEXT NOT NULL,
                description TEXT,
                preview TEXT,
                created_at INTEGER NOT NULL,
                last_used INTEGER NOT NULL,
                usage_count INTEGER DEFAULT 0
            );
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_last_used ON snippets (last_used DESC);
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_usage_count ON snippets (usage_count DESC);
            """
        };

        public Database(Object source) {
            this.db = DatabaseUtils.open_database(BOB_LAUNCHER_APP_ID, "snippets-plugin");
            DatabaseUtils.setup_database(db, setup_statements);
            this.snippet_cache = new HashTable<string, SnippetMetadata>(str_hash, str_equal);
            prepare_statements();
            load_all_metadata();
        }

        public void cleanup() {
            finalize_database();
        }

        private void finalize_database() {
            db = null;
            insert_or_replace_stmt = null;
            delete_stmt = null;
            get_snippet_stmt = null;
            load_all_metadata_stmt = null;
            update_usage_stmt = null;
            check_exists_stmt = null;
            snippet_cache.remove_all();
        }

        private void prepare_statements() {
            insert_or_replace_stmt = DatabaseUtils.prepare_statement(db, """
                INSERT OR REPLACE INTO snippets (key, content, mime_type, description, preview, created_at, last_used, usage_count)
                VALUES (?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT usage_count FROM snippets WHERE key = ?), 0));
            """);

            delete_stmt = DatabaseUtils.prepare_statement(db, """
                DELETE FROM snippets WHERE key = ?;
            """);

            get_snippet_stmt = DatabaseUtils.prepare_statement(db, """
                SELECT content, mime_type FROM snippets WHERE key = ?;
            """);

            load_all_metadata_stmt = DatabaseUtils.prepare_statement(db, """
                SELECT key, mime_type, description, preview, created_at, last_used, usage_count
                FROM snippets
                ORDER BY last_used DESC;
            """);

            update_usage_stmt = DatabaseUtils.prepare_statement(db, """
                UPDATE snippets
                SET last_used = ?, usage_count = usage_count + 1
                WHERE key = ?;
            """);

            check_exists_stmt = DatabaseUtils.prepare_statement(db, """
                SELECT 1 FROM snippets WHERE key = ? LIMIT 1;
            """);
        }

        private void load_all_metadata() {
            snippet_cache.remove_all();
            load_all_metadata_stmt.reset();

            while (load_all_metadata_stmt.step() == Sqlite.ROW) {
                string key = load_all_metadata_stmt.column_text(0);
                string mime_type = load_all_metadata_stmt.column_text(1);
                string description = load_all_metadata_stmt.column_text(2);
                string preview = load_all_metadata_stmt.column_text(3);
                int64 created_at = load_all_metadata_stmt.column_int64(4);
                int64 last_used = load_all_metadata_stmt.column_int64(5);
                uint usage_count = (uint)load_all_metadata_stmt.column_int(6);

                var metadata = new SnippetMetadata(key, mime_type, description, preview,
                                                  created_at, last_used, usage_count);
                snippet_cache[key] = metadata;
            }

            load_all_metadata_stmt.reset();
        }

        private string generate_preview(uint8[] data, string mime_type) {
            if (mime_type.has_prefix("text/")) {
                string text = (string)data;
                if (text.length > 100) {
                    return text.substring(0, 100) + "...";
                }
                return text;
            } else if (mime_type.has_prefix("image/")) {
                return "[Image]";
            } else {
                size_t size = data.length;
                if (size < 1024) {
                    return "[Binary: %zu B]".printf(size);
                } else if (size < 1024 * 1024) {
                    return "[Binary: %.1f KB]".printf(size / 1024.0);
                } else {
                    return "[Binary: %.1f MB]".printf(size / (1024.0 * 1024.0));
                }
            }
        }

        public bool insert_snippet(string key, uint8[] data, string mime_type, string? description = null) {
            int64 now = GLib.get_real_time();
            string preview = generate_preview(data, mime_type);

            insert_or_replace_stmt.reset();
            insert_or_replace_stmt.clear_bindings();

            insert_or_replace_stmt.bind_text(1, key);

            insert_or_replace_stmt.bind_blob(2, data, data.length);

            insert_or_replace_stmt.bind_text(3, mime_type);
            insert_or_replace_stmt.bind_text(4, description ?? "");
            insert_or_replace_stmt.bind_text(5, preview);
            insert_or_replace_stmt.bind_int64(6, now);
            insert_or_replace_stmt.bind_int64(7, now);
            insert_or_replace_stmt.bind_text(8, key); // for the COALESCE subquery

            if (insert_or_replace_stmt.step() != Sqlite.DONE) {
                warning("Failed to insert snippet: %s", db.errmsg());
                insert_or_replace_stmt.reset();
                return false;
            }

            insert_or_replace_stmt.reset();

            // Update cache
            var metadata = new SnippetMetadata(key, mime_type, description, preview, now, now, 0);
            snippet_cache[key] = metadata;

            return true;
        }

        public bool delete_snippet(string key) {
            delete_stmt.reset();
            delete_stmt.clear_bindings();
            delete_stmt.bind_text(1, key);

            if (delete_stmt.step() != Sqlite.DONE) {
                warning("Failed to delete snippet: %s", db.errmsg());
                delete_stmt.reset();
                return false;
            }

            delete_stmt.reset();
            snippet_cache.remove(key);
            return true;
        }

        public SnippetContent? get_snippet(string key) {
            get_snippet_stmt.reset();
            get_snippet_stmt.clear_bindings();
            get_snippet_stmt.bind_text(1, key);

            if (get_snippet_stmt.step() == Sqlite.ROW) {
                void* blob_data = get_snippet_stmt.column_blob(0);
                int blob_size = get_snippet_stmt.column_bytes(0);
                uint8[] blob_copy = new uint8[blob_size];
                Memory.copy(blob_copy, (uint8[])blob_data, blob_size);

                string mime_type = get_snippet_stmt.column_text(1);

                get_snippet_stmt.reset();

                update_usage(key);

                return new SnippetContent(blob_copy, mime_type);
            }

            get_snippet_stmt.reset();
            return null;
        }

        private void update_usage(string key) {
            int64 now = GLib.get_real_time();

            update_usage_stmt.reset();
            update_usage_stmt.clear_bindings();
            update_usage_stmt.bind_int64(1, now);
            update_usage_stmt.bind_text(2, key);

            if (update_usage_stmt.step() != Sqlite.DONE) {
                warning("Failed to update usage stats: %s", db.errmsg());
            }
            update_usage_stmt.reset();

            // Update cache
            var metadata = snippet_cache[key];
            if (metadata != null) {
                metadata.last_used = now;
                metadata.usage_count++;
            }
        }

        public bool exists(string key) {
            return snippet_cache.contains(key);
        }

        public SnippetMetadata? get_metadata(string key) {
            return snippet_cache[key];
        }

        public HashTable<string, SnippetMetadata> get_all_metadata() {
            return snippet_cache;
        }

        public GenericArray<SnippetMetadata> search_snippets(string query) {
            var results = new GenericArray<SnippetMetadata>();
            string lower_query = query.down();

            snippet_cache.foreach((key, metadata) => {
                if (key.down().contains(lower_query) ||
                    metadata.description.down().contains(lower_query) ||
                    metadata.preview.down().contains(lower_query)) {
                    results.add(metadata);
                }
            });

            // Sort by relevance (key match first, then by last_used)
            results.sort_with_data((a, b) => {
                bool a_key_match = a.key.down().contains(lower_query);
                bool b_key_match = b.key.down().contains(lower_query);

                if (a_key_match && !b_key_match) return -1;
                if (!a_key_match && b_key_match) return 1;

                // Both match or neither match, sort by last_used
                return (int)(b.last_used - a.last_used);
            });

            return results;
        }
    }
}
