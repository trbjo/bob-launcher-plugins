[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.RecentlyUsedPlugin);
}

namespace BobLauncher {
    public class RecentlyUsedPlugin : SearchBase {
        private const string RECENT_XML_NAME = "recently-used.xbel";
        private GenericArray<FileInfo> recent_files;
        private GenericArray<GenericArray<unowned FileInfo>> recent_files_inner;
        private GenericArray<GenericArray<unowned string>> path_names_inner;
        private GenericArray<string> path_names;
        private INotify.Monitor? file_monitor;
        private File recent_file;
        private string self_uri;
        const int num_shards = 8;

        construct {
            recent_files = new GenericArray<FileInfo>();
            icon_name = "document-open-recent";
            instance = this;
        }

        public override bool activate() {
            base.shard_count = num_shards;
            FileTreeManager.initialize(num_shards);


            recent_file = File.new_for_path(Path.build_filename(
                Environment.get_home_dir(), "." + RECENT_XML_NAME, null));

            if (!recent_file.query_exists()) {
                recent_file = File.new_for_path(Path.build_filename(
                    Environment.get_user_data_dir(), RECENT_XML_NAME, null));
            }

            self_uri = recent_file.get_uri();
            string self_path = recent_file.get_path();

            load_recent_files();

            file_monitor = new INotify.Monitor(load_recent_files);
            string[] paths = { self_path };
            int result = file_monitor.add_paths(paths);

            if (result < 0) {
                stderr.printf("Error setting up file monitor for path: %s\n", self_path);
                return false;
            }
            return true;

        }

        public override void deactivate() {
            if (file_monitor != null) {
                string[] paths = { recent_file.get_path() };
                file_monitor.remove_paths(paths);
                file_monitor = null;
            }

            recent_files = new GenericArray<FileInfo>();
        }

        private static weak RecentlyUsedPlugin? instance = null;
        private static uint timeout_id;

        private void load_recent_files() {
            recent_files = new GenericArray<FileInfo>();

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
                }
            } catch (Error err) {
                warning("Unable to parse %s: %s", recent_file.get_path(), err.message);
            }
            sort_list();
            build_path_names();
        }

        private const string SEARCH_FILE_ATTRIBUTES =
            FileAttribute.STANDARD_NAME + "," +
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
                    FileTreeManager.remove_file(file.get_path());
                    debug("Skipping non-existent file: %s", uri);
                    return;
                }
                FileTreeManager.add_file(file.get_path());
                return;

                var file_info = file.query_info(SEARCH_FILE_ATTRIBUTES, FileQueryInfoFlags.NONE, null);

                file_info.set_attribute_string("custom::uri", uri);

                DateTime? timestamp = null;

                try {
                    timestamp = bf.get_visited_date_time(uri);
                } catch (Error e) {
                    message("Could not get BookmarkFile visited time for %s: %s", uri, e.message);
                }

                if (timestamp == null) {
                    timestamp = new DateTime.now_utc();
                    message("No timestamp in BookmarkFile for %s, using current time", uri);
                }

                file_info.set_attribute_int64("custom::timestamp", timestamp.to_unix());

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

        private void build_path_names() {
            path_names_inner = new GenericArray<GenericArray<unowned string>>(num_shards);
            recent_files_inner = new GenericArray<GenericArray<unowned FileInfo>>(num_shards);
            uint total_length = recent_files.length;
            path_names = new GenericArray<string>(total_length);

            uint chunk = (total_length + num_shards - 1) / num_shards;
            GenericArray<unowned string> _path_names = new GenericArray<unowned string>(chunk);
            for (int shard_id = 0; shard_id < num_shards; shard_id++) {
                path_names_inner.add(new GenericArray<unowned string>());
                recent_files_inner.add(new GenericArray<unowned FileInfo>());

                uint start = shard_id * chunk;
                uint end = (shard_id + 1) * chunk;
                if (end > recent_files.length) end = recent_files.length;

                for (uint j = start; j < end; j++) {
                    var file_info = recent_files.get(j);
                    string uri = file_info.get_attribute_string("custom::uri");
                    string filepath = GLib.Filename.from_uri(uri);
                    path_names.add(filepath);

                    path_names_inner.get(shard_id).add(filepath);
                    recent_files_inner.get(shard_id).add(file_info);
                }
            }
        }

        protected override void search_shard(ResultContainer rs, uint shard_id) {
            FileTreeManager.tree_manager_shard(rs, shard_id);
            return;

            uint chunk = (recent_files.length + num_shards - 1) / num_shards;
            uint start = shard_id * chunk;
            // uint end = (shard_id + 1) * chunk;
            // if (end > recent_files.length) end = recent_files.length;

            unowned GenericArray<unowned string> my_paths = path_names_inner.get(shard_id);
            unowned GenericArray<unowned FileInfo> _recent_files = recent_files_inner.get(shard_id);

            unowned string needle = rs.get_query();
            bool needle_empty = needle == "";
            message("shard: %u, recent_files: %u, my_paths: %u", shard_id, recent_files.length, my_paths.length);
            uint index = 0;

            foreach (unowned string path_name in my_paths) {
                Score path_score = needle_empty ? MatchScore.ABOVE_THRESHOLD : rs.match_score(path_name);
                if (path_score > MatchScore.BELOW_THRESHOLD) {
                    unowned FileInfo file_info = _recent_files.data[index];
                    unowned string title = file_info.get_display_name();
                    int64 timestamp_unix = file_info.get_attribute_int64("custom::timestamp");
                    DateTime? timestamp = new DateTime.from_unix_utc(timestamp_unix);
                    rs.add_lazy(path_name.hash(), path_score, () => new RecentlyUsedMatch(
                            title,
                            path_name,
                            file_info.get_content_type(),
                            timestamp
                        )
                    );
                }
                index++;
            }
        }

        private class RecentlyUsedMatch : FileMatch {
            public static string? uri_to_path(string uri) {
                return File.new_for_uri(uri).get_path();
            }

            public RecentlyUsedMatch(
                string title,
                string path,
                string mime_type,
                DateTime? timestamp
            ) {
                Object (filename: path);
                base.timestamp = timestamp;
            }
        }
    }
}
