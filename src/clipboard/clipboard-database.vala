using BobLauncher;

namespace Clipboard {
    public class Database {
        private Sqlite.Database db;

        private Sqlite.Statement insert_ui_stmt;
        private Sqlite.Statement select_statement;
        private Sqlite.Statement insert_content_stmt;
        private Sqlite.Statement case_sensitive_search_stmt;
        private Sqlite.Statement case_insensitive_search_stmt;
        private Sqlite.Statement latest_stmt;
        private Sqlite.Statement all_items;
        private Sqlite.Statement update_timestamp_stmt;

        public void update_timestamp(uint item_hash, int64 timestamp) {
            update_timestamp_stmt.reset();
            update_timestamp_stmt.clear_bindings();
            update_timestamp_stmt.bind_int64(1, timestamp);
            update_timestamp_stmt.bind_int64(2, item_hash);

            if (update_timestamp_stmt.step() != Sqlite.DONE) {
                warning("Failed to update timestamp: %s", db.errmsg());
            }
            update_timestamp_stmt.reset();
        }

        public int64 get_oldest_timestamp() {
            var stmt = DatabaseUtils.prepare_statement(db, """
                SELECT timestamp FROM clipboard_items
                ORDER BY timestamp ASC
                LIMIT 1;
            """);

            if (stmt.step() == Sqlite.ROW) {
                int64 oldest = stmt.column_int64(0);
                stmt.reset();
                return oldest;
            }
            stmt.reset();
            return GLib.get_real_time();
        }

        public int64 calculate_timestamp_offset() {
            return get_oldest_timestamp();
        }


        public GLib.HashTable<Bytes, GenericArray<string>> get_content(uint item_hash) {
            var content_map = new GLib.HashTable<Bytes, GenericArray<string>>(direct_hash, direct_equal);
            select_statement.reset();
            select_statement.bind_int64(1, item_hash);

            while (select_statement.step() == Sqlite.ROW) {
                void* blob_data = select_statement.column_blob(0);
                int blob_size = select_statement.column_bytes(0);
                uint8[] blob_copy = new uint8[blob_size];
                Memory.copy(blob_copy, (uint8[])blob_data, blob_size);
                var bytes = new Bytes(blob_copy);

                string mime_types_string = select_statement.column_text(1);
                var mime_types = listify_string(mime_types_string);
                content_map[bytes] = mime_types;
            }
            return content_map;
        }

        private static GenericArray<string> listify_string(string input) {
            var result = new GenericArray<string>();

            try {
                var parser = new Json.Parser();
                parser.load_from_data(input);

                var root = parser.get_root();
                if (root.get_node_type() != Json.NodeType.ARRAY) {
                    warning("Input is not a JSON array");
                    return result;
                }

                var array = root.get_array();
                array.foreach_element((array, index, element_node) => {
                    if (element_node.get_node_type() == Json.NodeType.VALUE) {
                        string mime_type = element_node.get_string();
                        result.add(mime_type);
                    }
                });
            } catch (Error e) {
                warning("Error parsing JSON: %s", e.message);
            }

            return result;
        }

        private const string[] setup_statements = {
            """
            CREATE TABLE IF NOT EXISTS clipboard_items (
                item_hash INTEGER PRIMARY KEY,
                top_mime TEXT,
                title TEXT NOT NULL,
                timestamp INTEGER NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS clipboard_content (
                content_hash INTEGER PRIMARY KEY,
                item_hash INTEGER NOT NULL,
                content BLOB NOT NULL,
                mime_types TEXT NOT NULL,
                FOREIGN KEY (item_hash) REFERENCES clipboard_items(item_hash)
            );
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_timestamp ON clipboard_items (timestamp DESC);
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_item_hash ON clipboard_content (item_hash);
            """,
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts USING fts5(
                title,
                top_mime UNINDEXED,
                timestamp UNINDEXED,
                content='clipboard_items',
                content_rowid='item_hash',
                tokenize='unicode61'
            );
            """,
            """
            CREATE TRIGGER IF NOT EXISTS clipboard_ai AFTER INSERT ON clipboard_items BEGIN
                INSERT INTO clipboard_fts(rowid, title, top_mime, timestamp)
                VALUES (new.item_hash, new.title, new.top_mime, new.timestamp);
            END;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS clipboard_au AFTER UPDATE ON clipboard_items BEGIN
                UPDATE clipboard_fts SET
                    title = new.title,
                    top_mime = new.top_mime,
                    timestamp = new.timestamp
                WHERE rowid = old.item_hash;
            END;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS clipboard_ad AFTER DELETE ON clipboard_items BEGIN
                DELETE FROM clipboard_fts WHERE rowid = old.item_hash;
            END;
            """
        };

        public Database(Object source) {
            this.db = DatabaseUtils.open_database(source);
            DatabaseUtils.setup_database(db, setup_statements);
            prepare_statements();
        }

        public void cleanup() {
            finalize_database();
        }

        private void finalize_database() {
            db = null;
            insert_ui_stmt = null;
            select_statement = null;
            insert_content_stmt = null;
            case_sensitive_search_stmt = null;
            case_insensitive_search_stmt = null;
            latest_stmt = null;
            all_items = null;
            update_timestamp_stmt = null;
        }

        private void prepare_statements() {
            select_statement = DatabaseUtils.prepare_statement(db, "SELECT content, mime_types FROM clipboard_content WHERE item_hash = ?;");

            insert_ui_stmt = DatabaseUtils.prepare_statement(db, """
                INSERT OR REPLACE INTO clipboard_items (item_hash, top_mime, title, timestamp)
                VALUES (?, ?, ?, ?);
            """);

            insert_content_stmt = DatabaseUtils.prepare_statement(db, """
                INSERT OR REPLACE INTO clipboard_content (content_hash, content, mime_types, item_hash)
                VALUES (?, ?, ?, ?);
            """);

            case_insensitive_search_stmt = DatabaseUtils.prepare_statement(db, """
                SELECT ci.item_hash, ci.timestamp, ci.top_mime, ci.title
                FROM clipboard_fts
                JOIN clipboard_items ci ON clipboard_fts.rowid = ci.item_hash
                WHERE clipboard_fts MATCH ?
                ORDER BY ci.timestamp DESC
                LIMIT 50;
            """);

            case_sensitive_search_stmt = DatabaseUtils.prepare_statement(db, """
                SELECT ci.item_hash, ci.timestamp, ci.top_mime, ci.title
                FROM clipboard_fts
                JOIN clipboard_items ci ON clipboard_fts.rowid = ci.item_hash
                WHERE clipboard_fts MATCH ?
                AND ci.title GLOB ?
                ORDER BY ci.timestamp DESC
                LIMIT 50;
            """);

            all_items = DatabaseUtils.prepare_statement(db, """
                SELECT ci.item_hash, ci.timestamp, ci.top_mime, ci.title
                FROM clipboard_items ci
                ORDER BY ci.timestamp DESC
            """);

            update_timestamp_stmt = DatabaseUtils.prepare_statement(db, """
                UPDATE clipboard_items
                SET timestamp = ?
                WHERE item_hash = ?;
            """);
        }

        private bool check_if_content_exists(uint item_hash) {
            var check_stmt = DatabaseUtils.prepare_statement(db, """
                SELECT 1 FROM clipboard_items WHERE item_hash = ? LIMIT 1;
            """);

            check_stmt.bind_int64(1, item_hash);
            bool exists = check_stmt.step() == Sqlite.ROW;
            check_stmt.reset();
            return exists;
        }

        public void insert_item(GLib.HashTable<Bytes, GLib.GenericArray<string>> content, uint hash,
                              string mime_type, string title) {
            int64 timestamp = GLib.get_real_time();
            bool content_exists = check_if_content_exists(hash);

            // Insert all content first
            content.foreach((content, mime_types) => insert_content(hash, content, mime_types));

            // Update or insert the item
            if (content_exists) {
                update_timestamp_stmt.reset();
                update_timestamp_stmt.clear_bindings();
                update_timestamp_stmt.bind_int64(1, timestamp);
                update_timestamp_stmt.bind_int64(2, hash);

                if (update_timestamp_stmt.step() != Sqlite.DONE) {
                    warning("Failed to update timestamp: %s", db.errmsg());
                }
                update_timestamp_stmt.reset();
            } else {
                insert_ui_item(hash, mime_type, title, timestamp);
            }
        }


        private string stringify_list(GenericArray<string> list) {
            var builder = new Json.Builder();
            builder.begin_array();
            foreach (var item in list) {
                builder.add_string_value(item);
            }
            builder.end_array();
            var generator = new Json.Generator();
            var node = builder.get_root();
            generator.set_root(node);
            return generator.to_data(null);
        }

        private void insert_content(uint item_hash, Bytes content, GenericArray<string> mime_types) {
            insert_content_stmt.reset();
            insert_content_stmt.clear_bindings();

            var content_hash = content.hash();

            insert_content_stmt.bind_int64(1, content_hash);

            unowned uint8[] data = content.get_data();
            insert_content_stmt.bind_blob(2, data, data.length);

            string mime_types_json = stringify_list(mime_types);
            insert_content_stmt.bind_text(3, mime_types_json);
            insert_content_stmt.bind_int64(4, item_hash);

            if (insert_content_stmt.step() != Sqlite.DONE) {
                warning("Failed to insert content: %s", db.errmsg());
            }
            insert_content_stmt.reset();
        }

        private void insert_ui_item(uint hash, string top_mime, string title, int64 timestamp) {
            insert_ui_stmt.reset();
            insert_ui_stmt.clear_bindings();

            insert_ui_stmt.bind_int64(1, hash);
            insert_ui_stmt.bind_text(2, top_mime);
            insert_ui_stmt.bind_text(3, title);
            insert_ui_stmt.bind_int64(4, timestamp);

            if (insert_ui_stmt.step() != Sqlite.DONE) {
                warning("Failed to insert UI item: %s", db.errmsg());
            }
            insert_ui_stmt.reset();
        }

        public bool delete_item(uint item_hash) {
            string delete_query = "DELETE FROM clipboard_items WHERE item_hash = ?;";
            Sqlite.Statement delete_stmt = DatabaseUtils.prepare_statement(db, delete_query);

            delete_stmt.bind_int64(1, item_hash);

            if (delete_stmt.step() != Sqlite.DONE) {
                warning("Failed to delete clipboard item: %s", db.errmsg());
                return false;
            }
            delete_stmt.reset();
            return true;
        }

        public unowned Sqlite.Statement get_latest_stmt(int max_recent_entries) {
            latest_stmt = DatabaseUtils.prepare_statement(db, """
                SELECT ci.item_hash, ci.timestamp, ci.top_mime, ci.title
                FROM clipboard_items ci
                ORDER BY ci.timestamp DESC
                LIMIT ?1;
            """);
            latest_stmt.bind_int(1, max_recent_entries);
            return latest_stmt;
        }

        public unowned Sqlite.Statement get_all_items() {
            return all_items;
        }

        public unowned Sqlite.Statement get_case_sensitive_search_stmt() {
            return case_sensitive_search_stmt;
        }

        public unowned Sqlite.Statement get_case_insensitive_search_stmt() {
            return case_insensitive_search_stmt;
        }
    }
}
