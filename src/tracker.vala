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

        protected override bool activate(Cancellable current_cancellable) {
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

        protected override void deactivate() {
            if (connection != null) {
                connection.close();
                connection = null;
            }
        }

        public override void search(ResultContainer rs) {
            spinlock();
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
                    if ((counter++ % 2 == 0) && rs.is_cancelled()) return;

                    string uri = cursor.get_string(0);
                    try {
                        string path = GLib.Filename.from_uri(uri);
                        double score = cursor.get_double(1);
                        rs.add_lazy(path.hash(), score + bonus, () => new FileMatch.from_path(path));
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
