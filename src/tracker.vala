[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.TrackerSearchPlugin);
}

namespace BobLauncher {
    public class TrackerSearchPlugin : SearchBase {
        private void spinlock() {
            while (Threading.atomic_exchange(ref lock_token, 1) == 1) {
                Threading.pause();
            }
        }

        private void spinunlock() {
            Threading.atomic_store(ref lock_token, 0);
        }

        private int lock_token;

        construct {
            icon_name = "find-location";
        }

        private Tsparql.SparqlConnection? connection;
        private Tsparql.SparqlStatement? case_insensitive_stmt;

        public override bool activate() {
            try {
                debug("TrackerSearchPlugin: Connecting to Tracker SPARQL endpoint...");
                connection = Tsparql.SparqlConnection.bus_new("org.freedesktop.Tracker3.Miner.Files", null, null);

                case_insensitive_stmt = connection.query_statement(
                    "SELECT ?filePath " +
                    "fts:rank(?file) " +
                    "WHERE { ?file fts:match ~query. " +
                    "?file nie:isStoredAs ?filePath }"
                );

                debug("TrackerSearchPlugin: Connected to Tracker SPARQL endpoint");
                return true;
            } catch (Error e) {
                warning ("Failed to connect to Tracker: %s", e.message);
                return false;
            }
        }

        public override void deactivate() {
            if (connection != null) {
                connection.close();
                connection = null;
            }
        }

        public override void search(ResultContainer rs) {
            spinlock();
            if (rs.is_cancelled()) {
                spinunlock();
                return;
            }
            case_insensitive_stmt.bind_string("query", rs.get_query());

            Tsparql.SparqlCursor cursor;

            try {
                cursor = case_insensitive_stmt.execute(null);
            } catch (GLib.Error e) {
                warning("failed to execute query, error message: %s", e.message);
                spinunlock();
                return;
            }

            int counter = 0;
            try {
                while (cursor.next(null)) {
                    if ((((counter++) & 0x7) == 0) && rs.is_cancelled()) return;

                    string uri = cursor.get_string(0);
                    try {
                        string? path = GLib.Filename.from_uri(uri);
                        if (path != null && FileUtils.test(path, FileTest.EXISTS)) {
                            Score score = (int16)(400.0 * cursor.get_double(1));
                            string basename = GLib.Path.get_basename (path);

                            Score path_score = rs.match_score(path);
                            Score title_score = rs.match_score(basename);
                            Score final_score = int16.max(int16.max(score, path_score), title_score);
                            rs.add_lazy(path.hash(), final_score, () => new FileMatch.from_path(path));
                        }
                    } catch (Error e) {
                        warning("could not resolve uri: %s, error: %s", uri, e.message);
                        continue;
                    }
                }
            } catch (GLib.Error e) {
            } finally {
                case_insensitive_stmt.clear_bindings();
                cursor.close();
                spinunlock();
            }
        }
    }
}
