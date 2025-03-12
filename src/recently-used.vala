[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.RecentlyUsedPlugin);
}

namespace BobLauncher {
    public class RecentlyUsedPlugin : SearchBase {
        private const string RECENT_XML_NAME = "recently-used.xbel";
        private GenericArray<FileInfo> recent_files;
        private FileMonitor? file_monitor;
        private File recent_file;
        private string self_uri;
        private bool loading = true;

        construct {
            recent_files = new GenericArray<FileInfo>();
            icon_name = "document-open-recent";
        }

        protected override bool activate(Cancellable current_cancellable) {
            recent_file = File.new_for_path(Path.build_filename(
                Environment.get_home_dir(), "." + RECENT_XML_NAME, null));

            if (!recent_file.query_exists()) {
                recent_file = File.new_for_path(Path.build_filename(
                    Environment.get_user_data_dir(), RECENT_XML_NAME, null));
            }
            self_uri = recent_file.get_uri();

            load_recent_files();

            try {
                file_monitor = recent_file.monitor_file(FileMonitorFlags.NONE, null);
                file_monitor.changed.connect(on_recent_file_changed);
                return true;
            } catch (Error e) {
                warning("Could not set up file monitor: %s", e.message);
                return false;
            }
        }

        protected override void deactivate() {
            if (file_monitor != null) {
                file_monitor.cancel();
                file_monitor = null;
            }
            recent_files = new GenericArray<FileInfo>();
        }


        private void on_recent_file_changed(File file, File? other_file, FileMonitorEvent event_type) {
            if (loading) {
                return;
            }
            switch (event_type) {
                case FileMonitorEvent.CHANGED:
                case FileMonitorEvent.CREATED:
                    load_recent_files();
                    break;
                default:
                    break;
            }
        }

        private void load_recent_files() {
            recent_files = new GenericArray<FileInfo>();
            loading = true;

            try {
                uint8[] file_contents;
                string contents;

                if (recent_file.load_contents(null, out file_contents, null)) {
                    contents = (string) file_contents;

                    var bf = new BookmarkFile();
                    bf.load_from_data(contents, file_contents.length);
                    string[] uris = bf.get_uris();

                    foreach(unowned string uri in uris) {
                        add_or_update_uri(uri, bf);
                    }
                    bf.to_file(recent_file.get_path());
                    Timeout.add(1000, () => {
                        loading = false;
                        return false;
                    },
                    GLib.Priority.DEFAULT);
                }
            } catch (Error err) {
                warning("Unable to parse %s: %s", recent_file.get_path(), err.message);
            }
        }

        private const string SEARCH_FILE_ATTRIBUTES =
            FileAttribute.STANDARD_NAME + "," +
            FileAttribute.TIME_ACCESS + "," +
            FileAttribute.TIME_MODIFIED + "," +
            FileAttribute.STANDARD_DISPLAY_NAME + "," +
            FileAttribute.STANDARD_TYPE + "," +
            FileAttribute.STANDARD_CONTENT_TYPE + ",";

        private void add_or_update_uri(string uri, BookmarkFile bf) {
            if (uri == self_uri) {
                return;
            }

            try {
                var file = File.new_for_uri(uri);

                if (!file.query_exists()) {
                    bf.remove_item(uri);
                    debug("Skipping non-existent file: %s", uri);
                    return;
                }

                var file_info = file.query_info(SEARCH_FILE_ATTRIBUTES, FileQueryInfoFlags.NONE, null);

                // Store the URI in the FileInfo object
                file_info.set_attribute_string("custom::uri", uri);

                DateTime? timestamp = null;

                try {
                    timestamp = bf.get_modified_date_time(uri);
                } catch (Error e) {
                    debug("Could not get BookmarkFile modified time for %s: %s", uri, e.message);
                }

                if (timestamp == null && file_info.has_attribute(FileAttribute.TIME_ACCESS)) {
                    timestamp = file_info.get_access_date_time();
                }

                if (timestamp == null && file_info.has_attribute(FileAttribute.TIME_MODIFIED)) {
                    timestamp = file_info.get_modification_date_time();
                }

                if (timestamp == null) {
                    timestamp = new DateTime.now_utc();
                    debug("Using current time as fallback for %s", uri);
                }

                file_info.set_attribute_int64("custom::timestamp", timestamp.to_unix());

                // Remove existing entry if present
                uint index;
                bool found = recent_files.find_custom<string>(uri, (item, search_uri) => {
                    return item.get_attribute_string("custom::uri") == search_uri;
                }, out index);

                if (found) {
                    recent_files.remove_index(index);
                }

                recent_files.add(file_info);
            } catch (Error e) {
                warning("Error adding or updating URI %s: %s", uri, e.message);
            }
        }

        private void sort_list() {
            recent_files.sort((a, b) => (int)(a.get_attribute_int64("custom::timestamp") - b.get_attribute_int64("custom::timestamp")));
        }

        public override void search(ResultContainer rs) {
            sort_list();

            unowned string needle = rs.get_query();
            bool needle_empty = needle == "";
            double sort_order = 0.0;
            foreach (var file_info in recent_files) {
                unowned string title = file_info.get_display_name();
                Score score = rs.match_score(title);

                if (needle_empty || score > 0.0) {
                    sort_order += 0.001;
                    score += sort_order;
                    string uri = file_info.get_attribute_string("custom::uri");
                    string filepath = GLib.Filename.from_uri(uri);
                    rs.add_lazy(filepath.hash(), score + bonus, () => new RecentlyUsedMatch(
                            title,
                            uri,
                            file_info.get_content_type()
                        )
                    );
                }
            }
        }

        private class RecentlyUsedMatch : FileMatch {
            public static string? uri_to_path(string uri) {
                return File.new_for_uri(uri).get_path();
            }
            public RecentlyUsedMatch(
                string title,
                string uri,
                string mime_type
            ) {
                string path = uri_to_path(uri);
                Object (filename: path);
            }
        }
    }
}
