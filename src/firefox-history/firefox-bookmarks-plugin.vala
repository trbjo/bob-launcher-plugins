[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.FirefoxHistoryPlugin);
}

namespace BobLauncher {
    public class FirefoxHistoryPlugin : SearchBase {
        construct {
            icon_name = "firefox";
        }

        private const string[] setup_statements = {
            """
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA cache_size = -10000;
            PRAGMA temp_store = MEMORY;
            PRAGMA mmap_size = 30000000000;
            """,
            """
            CREATE VIEW IF NOT EXISTS combined_view AS
            SELECT A.title, B.url, 'bookmark' as source, B.last_visit_date
            FROM moz_bookmarks AS A
            JOIN moz_places AS B ON(A.fk = B.id)
            UNION ALL
            SELECT title, url, 'history' as source, last_visit_date
            FROM moz_places
            WHERE frecency > 0;
            """,
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS fts_view USING fts5(
                title, url, source, last_visit_date, priority
            );
            """,
            """
            INSERT OR REPLACE INTO fts_view(title, url, source, last_visit_date, priority)
            SELECT title, url, source, last_visit_date,
                   CASE WHEN source = 'bookmark' THEN 1 ELSE 2 END as priority
            FROM combined_view;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS update_fts_bookmark AFTER INSERT ON moz_bookmarks
            BEGIN
                INSERT INTO fts_view(title, url, source, last_visit_date, priority)
                SELECT NEW.title, B.url, 'bookmark', B.last_visit_date, 1
                FROM moz_places B WHERE B.id = NEW.fk;
            END;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS update_fts_history AFTER INSERT ON moz_places
            BEGIN
                INSERT INTO fts_view(title, url, source, last_visit_date, priority)
                VALUES (NEW.title, NEW.url, 'history', NEW.last_visit_date, 2);
            END;
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_cover_all ON moz_places (title, url, frecency, last_visit_date);
            """
        };

        public enum FirefoxItemType {
            BOOKMARK,
            HISTORY
        }

        private Sqlite.Database[] shard_dbs;
        private Sqlite.Statement[] prepared_stmts;
        private uint num_shards;

        protected override bool activate(Cancellable current_cancellable) {
            num_shards = (uint)GLib.get_num_processors();
            base.shard_count = num_shards;

            shard_dbs = new Sqlite.Database[num_shards];
            prepared_stmts = new Sqlite.Statement[num_shards];

            init_databases();

            for (uint i = 0; i < num_shards; i++) {
                DatabaseUtils.setup_database(shard_dbs[i], setup_statements);
                prepare_statement(i);
            }

            debug("Firefox bookmarks initialized with %u shards", num_shards);
            return true;
        }

        protected override void deactivate() {
            finalize_databases();
        }

        private void finalize_databases() {
            for (uint i = 0; i < num_shards; i++) {
                if (shard_dbs[i] != null) {
                    // First attempt to commit any pending transactions
                    if (shard_dbs[i].get_autocommit() == 0) {
                        int result = shard_dbs[i].exec("COMMIT;");
                        if (result != Sqlite.OK) {
                            warning("Failed to commit transactions for shard %u: %s", i, shard_dbs[i].errmsg());
                        }
                    }

                    // Reset all prepared statements
                    unowned Sqlite.Statement? stmt = null;
                    while ((stmt = shard_dbs[i].next_stmt(stmt)) != null) {
                        stmt.reset();
                        stmt.clear_bindings();
                    }

                    // Skip changing journal mode to avoid I/O errors
                    // Just close the database directly
                    shard_dbs[i] = null;
                }
            }
            // Ensure arrays are cleared to prevent memory leaks
            shard_dbs = null;
            prepared_stmts = null;
        }

        ~FirefoxHistoryPlugin() {
            finalize_databases();
        }

        private void prepare_statement(uint shard_id) {
            string query = """
                SELECT title, url, source, last_visit_date
                FROM fts_view
                WHERE fts_view MATCH ?
            """;

            prepared_stmts[shard_id] = DatabaseUtils.prepare_statement(shard_dbs[shard_id], query);

            // Additional debugging information
            debug("Prepared search statement for shard %u", shard_id);
        }

        private string get_shard_db_path(uint shard_id) {
            // Get base database path from DatabaseUtils
            string base_path = DatabaseUtils.get_database_path(this);
            string dir_path = Path.get_dirname(base_path);
            string file_name = Path.get_basename(base_path);

            // Insert shard identifier before extension
            string name_without_ext = file_name.substring(0, file_name.last_index_of("."));
            string extension = file_name.substring(file_name.last_index_of("."));

            return Path.build_filename(dir_path, "%s.shard%u%s".printf(name_without_ext, shard_id, extension));
        }

        private uint get_shard_for_url(string url) {
            // Simple hash function for distributing URLs across shards
            uint hash = (uint)url.hash();
            return hash % num_shards;
        }

        private void init_databases() {
            string places_path = search_places();

            try {
                // First, copy the original places database and open it
                Sqlite.Database orig_db;
                string temp_db_path = DatabaseUtils.get_database_path(this) + ".original";
                File places_file = File.new_for_path(places_path);
                File temp_db_file = File.new_for_path(temp_db_path);

                // Delete existing files if they exist
                cleanup_old_databases();

                // Create directory if it doesn't exist
                File dir = File.new_for_path(Path.get_dirname(temp_db_path));
                if (!dir.query_exists()) {
                    dir.make_directory_with_parents();
                }

                // Copy Firefox places.sqlite to our temp file
                places_file.copy(temp_db_file, FileCopyFlags.OVERWRITE);
                int rc = Sqlite.Database.open_v2(temp_db_path, out orig_db,
                                              Sqlite.OPEN_READONLY, null);
                if (rc != Sqlite.OK) {
                    error("Failed to open original database: %d", rc);
                }

                // Create shard databases
                for (uint i = 0; i < num_shards; i++) {
                    uint k = i;
                    string shard_path = get_shard_db_path(k);

                    // Create the directory structure if needed
                    File shard_dir = File.new_for_path(Path.get_dirname(shard_path));
                    if (!shard_dir.query_exists()) {
                        shard_dir.make_directory_with_parents();
                    }

                    // Open the database using DatabaseUtils helper for consistency
                    rc = Sqlite.Database.open_v2(shard_path, out shard_dbs[k],
                                             Sqlite.OPEN_READWRITE | Sqlite.OPEN_CREATE, null);
                    if (rc != Sqlite.OK) {
                        error("Failed to create shard database %u: %d", k, rc);
                    }

                    // Set plugin identifier
                    DatabaseUtils.set_plugin_identifier(shard_dbs[k],
                          "%s.shard%u".printf(this.get_type().name(), k));

                    // Setup database hooks for debugging
                    shard_dbs[k].rollback_hook(() => {
                        // debug("Transaction rolled back for shard database %u", k);
                        message("ok");
                    });

                    shard_dbs[k].commit_hook(() => {
                        // debug("Transaction committed for shard database %u", k);
                        return 0; // Return 0 to allow the commit to proceed
                    });

                    // shard_dbs[k].update_hook((type, db_name, table_name, rowid) => {
                        // debug("Update in shard %u, table: %s, row: %lld", k, table_name, rowid);
                    // });

                    // Create initial schema
                    string[] schema_statements = {
                        "PRAGMA journal_mode = WAL;",
                        "PRAGMA synchronous = NORMAL;",
                        "PRAGMA cache_size = -10000;",
                        "PRAGMA temp_store = MEMORY;",
                        """
                        CREATE TABLE IF NOT EXISTS moz_places (
                            id INTEGER PRIMARY KEY,
                            url TEXT NOT NULL,
                            title TEXT,
                            frecency INTEGER DEFAULT 0,
                            last_visit_date INTEGER
                        );
                        """,
                        """
                        CREATE TABLE IF NOT EXISTS moz_bookmarks (
                            id INTEGER PRIMARY KEY,
                            fk INTEGER,
                            title TEXT
                        );
                        """
                    };

                    // Use DatabaseUtils to set up the database
                    DatabaseUtils.setup_database(shard_dbs[k], schema_statements);
                }

                // Distribute data across shards
                distribute_data(orig_db);

                // Add hostname function to each shard
                for (uint i = 0; i < num_shards; i++) {
                    rc = shard_dbs[i].create_function("hostname", 1, Sqlite.UTF8, null,
                        (context, values) => {
                            string url = values[0].to_text();
                            string[] parts = url.split("/");
                            if (parts.length > 2) {
                                context.result_text(parts[2]);
                            } else {
                                context.result_text("Unknown");
                            }
                        },
                        null, null
                    );

                    if (rc != Sqlite.OK) {
                        error("Failed to create hostname function for shard %u: %d, %s",
                              i, rc, shard_dbs[i].errmsg());
                    }
                }

                unowned Sqlite.Statement? stmt = null;
                while ((stmt = orig_db.next_stmt(stmt)) != null) {
                    stmt.reset();
                    stmt.clear_bindings();
                }

                // Just set to null to release it, skip journal mode changes
                orig_db = null;

            } catch (Error e) {
                error("Error initializing databases: %s", e.message);
            }
        }

        private void cleanup_old_databases() {
            string temp_db_path = DatabaseUtils.get_database_path(this) + ".original";

            delete_database_with_associated_files(temp_db_path);

            for (uint i = 0; i < num_shards; i++) {
                string shard_path = get_shard_db_path(i);
                delete_database_with_associated_files(shard_path);
            }
        }

        private void delete_database_with_associated_files(string db_path) {
            try {
                // Delete main database file if it exists
                File db_file = File.new_for_path(db_path);
                if (db_file.query_exists()) {
                    db_file.delete();
                }

                // Delete associated WAL/SHM files
                string[] extensions = {"-wal", "-shm", "-journal"};
                foreach (string ext in extensions) {
                    File aux_file = File.new_for_path(db_path + ext);
                    if (aux_file.query_exists()) {
                        aux_file.delete();
                    }
                }
            } catch (Error e) {
                warning("Error deleting database files at %s: %s", db_path, e.message);
            }
        }

        private void distribute_data(Sqlite.Database orig_db) {
            // Prepare statements for inserting into shard databases
            Sqlite.Statement[] place_insert_stmts = new Sqlite.Statement[num_shards];
            Sqlite.Statement[] bookmark_insert_stmts = new Sqlite.Statement[num_shards];

            for (uint i = 0; i < num_shards; i++) {
                int rc = shard_dbs[i].prepare_v2(
                    "INSERT INTO moz_places (id, url, title, frecency, last_visit_date) " +
                    "VALUES (?, ?, ?, ?, ?)",
                    -1, out place_insert_stmts[i]);
                if (rc != Sqlite.OK) {
                    error("Failed to prepare place insert statement for shard %u: %d", i, rc);
                }

                rc = shard_dbs[i].prepare_v2(
                    "INSERT INTO moz_bookmarks (id, fk, title) VALUES (?, ?, ?)",
                    -1, out bookmark_insert_stmts[i]);
                if (rc != Sqlite.OK) {
                    error("Failed to prepare bookmark insert statement for shard %u: %d", i, rc);
                }
            }

            // Get places and distribute them
            Sqlite.Statement places_stmt;
            int rc = orig_db.prepare_v2(
                "SELECT id, url, title, frecency, last_visit_date FROM moz_places WHERE frecency > 0",
                -1, out places_stmt);
            if (rc != Sqlite.OK) {
                error("Failed to prepare places query: %d", rc);
            }

            while (places_stmt.step() == Sqlite.ROW) {
                int64 id = places_stmt.column_int64(0);
                string url = places_stmt.column_text(1);
                string? title = places_stmt.column_text(2);
                int frecency = places_stmt.column_int(3);
                int64 last_visit_date = places_stmt.column_int64(4);

                // Determine which shard this URL belongs to
                uint shard_id = get_shard_for_url(url);

                // Insert into appropriate shard
                place_insert_stmts[shard_id].reset();
                place_insert_stmts[shard_id].clear_bindings();
                place_insert_stmts[shard_id].bind_int64(1, id);
                place_insert_stmts[shard_id].bind_text(2, url);
                place_insert_stmts[shard_id].bind_text(3, title);
                place_insert_stmts[shard_id].bind_int(4, frecency);
                place_insert_stmts[shard_id].bind_int64(5, last_visit_date);

                place_insert_stmts[shard_id].step();
                place_insert_stmts[shard_id].reset();
            }

            // Get bookmarks and distribute them
            Sqlite.Statement bookmarks_stmt;
            rc = orig_db.prepare_v2(
                "SELECT b.id, b.fk, b.title, p.url FROM moz_bookmarks b " +
                "JOIN moz_places p ON b.fk = p.id",
                -1, out bookmarks_stmt);
            if (rc != Sqlite.OK) {
                error("Failed to prepare bookmarks query: %d", rc);
            }

            while (bookmarks_stmt.step() == Sqlite.ROW) {
                int64 id = bookmarks_stmt.column_int64(0);
                int64 fk = bookmarks_stmt.column_int64(1);
                string? title = bookmarks_stmt.column_text(2);
                string url = bookmarks_stmt.column_text(3);

                // Determine which shard this URL belongs to
                uint shard_id = get_shard_for_url(url);

                // Insert into appropriate shard
                bookmark_insert_stmts[shard_id].reset();
                bookmark_insert_stmts[shard_id].clear_bindings();
                bookmark_insert_stmts[shard_id].bind_int64(1, id);
                bookmark_insert_stmts[shard_id].bind_int64(2, fk);
                bookmark_insert_stmts[shard_id].bind_text(3, title);

                bookmark_insert_stmts[shard_id].step();
                bookmark_insert_stmts[shard_id].reset();
            }

            // Cleanup statements
            for (uint i = 0; i < num_shards; i++) {
                place_insert_stmts[i].reset();
                bookmark_insert_stmts[i].reset();
            }
            places_stmt.reset();
            bookmarks_stmt.reset();
        }

        private string search_places() {
            string firefox_path = Path.build_filename(Environment.get_home_dir(), ".mozilla", "firefox");
            string conf_path = Path.build_filename(firefox_path, "profiles.ini");

            try {
                KeyFile config = new KeyFile();
                config.load_from_file(conf_path, KeyFileFlags.NONE);
                string prof_path = config.get_string("Profile0", "Path");
                string sql_path = Path.build_filename(firefox_path, prof_path);
                return Path.build_filename(sql_path, "places.sqlite");
            } catch (Error e) {
                error("Error finding places.sqlite: %s", e.message);
            }
        }

        protected override void search_shard(ResultContainer rs, uint shard_id) {
            string cleaned_query = rs.get_query().replace(".", " ").replace("/", " ");
            string cleaned = DatabaseUtils.fix_query(cleaned_query);

            unowned Sqlite.Statement? prepared_stmt = prepared_stmts[shard_id];

            prepared_stmt.reset();
            prepared_stmt.clear_bindings();
            prepared_stmt.bind_text(1, "title:" + cleaned + " OR url:" + cleaned);

            var now = new DateTime.now_local();
            string? formatted_date = null;
            int counter = 0;

            while (prepared_stmt.step() == Sqlite.ROW) {
                if ((counter++ % 10 == 0) && rs.is_cancelled()) return;
                string? title = prepared_stmt.column_text(0);
                if (title == null) continue;

                string? url = prepared_stmt.column_text(1);
                if (url == null) continue;

                string? source = prepared_stmt.column_text(2);
                if (source == null) continue;

                int64 last_visit_timestamp = prepared_stmt.column_int64(3);

                if (last_visit_timestamp > 0) {
                    int64 last_visit_seconds = last_visit_timestamp / 1000000;
                    DateTime last_visit = new DateTime.from_unix_utc(last_visit_seconds);
                    formatted_date = BobLauncher.Utils.format_modification_time(now, last_visit);
                } else {
                    formatted_date = null;
                }

                string new_url = Strings.decode_html_chars(url);

                if (new_url.has_prefix("file://")) {
                    double url_score = rs.match_score_spaceless(new_url);
                    rs.add_lazy(new_url.hash(), url_score + bonus, () => new FileMatch.from_uri(new_url));
                } else {
                    double score = rs.match_score_spaceless(title);
                    if (score < 0) {
                        score = rs.match_score_spaceless(title);
                    }
                    rs.add_lazy(new_url.hash(), score + bonus, () => {
                        FirefoxItemType item_type = (source == "bookmark") ?
                                            FirefoxItemType.BOOKMARK : FirefoxItemType.HISTORY;
                        return new HistoryMatch(title, new_url, item_type, formatted_date);
                    });
                }
            }
        }
    }
}
