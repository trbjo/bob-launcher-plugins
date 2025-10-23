[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.DownloadsPlugin);
}


namespace BobLauncher {
    public class DownloadsPlugin : SearchBase {
        public override bool prefer_insertion_order { get { return true; } }
        private GenericArray<DownloadsContent> sorted_list;
        private INotify.Monitor? file_monitor;
        private File download_directory;
        private string dl_path;

        private static weak DownloadsPlugin? instance = null;

        private int spinlock = 0;

        construct {
            icon_name = "folder-download";
            sorted_list = new GenericArray<DownloadsContent>();
            download_directory = File.new_for_path(get_download_dir());
            dl_path = download_directory.get_path();

            instance = this;
        }

        public override bool activate() {
            load_directory_contents();

            file_monitor = new INotify.Monitor(on_file_changed);

            string[] paths = { dl_path };
            int result = file_monitor.add_paths(paths);

            if (result < 0) {
                stderr.printf("Error setting up file monitor for path: %s\n", dl_path);
                return false;
            }

            return true;
        }

        public override void deactivate() {
            if (file_monitor != null) {
                string[] paths = { dl_path };
                file_monitor.remove_paths(paths);
                file_monitor = null;
            }

            acquire_lock();
            sorted_list = new GenericArray<DownloadsContent>();
            release_lock();
        }

        private string get_download_dir() {
            return GLib.Environment.get_user_special_dir(GLib.UserDirectory.DOWNLOAD);
        }

        private const string DL_FILE_ATTRIBUTES =
            FileAttribute.STANDARD_NAME + "," +
            FileAttribute.STANDARD_TYPE + "," +
            FileAttribute.STANDARD_ICON + "," +
            FileAttribute.STANDARD_CONTENT_TYPE + "," +
            FileAttribute.TIME_CREATED + "," +
            FileAttribute.TIME_MODIFIED + "," +
            FileAttribute.STANDARD_IS_HIDDEN;

        private void acquire_lock() {
            int expected = 0;
            while (!Threading.cas(ref spinlock, ref expected, 1)) {
                expected = 0;
                Threading.pause();
            }
        }

        private void release_lock() {
            Threading.atomic_store(ref spinlock, 0);
        }

        private void load_directory_contents() {
            acquire_lock();
            sorted_list = new GenericArray<DownloadsContent>();
            release_lock();

            var now = new DateTime.now_local();
            var reversed = now.to_unix();
            try {
                var enumerator = download_directory.enumerate_children(DL_FILE_ATTRIBUTES, FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
                FileInfo file_info;
                while ((file_info = enumerator.next_file()) != null) {
                    add_file_to_list(file_info, now, reversed);
                }
                sort_list();
            } catch (Error e) {
                stderr.printf("Error loading directory contents: %s\n", e.message);
            }
        }

        private void on_file_changed(string path, int event_type) {
            var file = File.new_for_path(path);

            if ((event_type & INotify.EventType.CREATE) != 0) {
                add_file(file);
            } else if ((event_type & INotify.EventType.DELETE) != 0) {
                remove_file(file);
            } else if ((event_type & INotify.EventType.MODIFY) != 0 ||
                       (event_type & INotify.EventType.ATTRIB) != 0 ||
                       (event_type & INotify.EventType.CLOSE_WRITE) != 0) {
                update_file(file);
            } else if ((event_type & INotify.EventType.MOVED_TO) != 0) {
                add_file(file);
            } else if ((event_type & INotify.EventType.MOVED_FROM) != 0) {
                remove_file(file);
            }
        }

        private void add_file(File file) {
            try {
                string file_path = file.get_path();
                acquire_lock();
                uint index;
                bool already_exists = sorted_list.find_custom<string>(file_path, (item, search_path) => {
                    return item.get_file_path() == search_path;
                }, out index);
                release_lock();

                if (already_exists) {
                    update_file(file);
                    return;
                }

                var file_info = file.query_info(DL_FILE_ATTRIBUTES, FileQueryInfoFlags.NONE);
                var now = new DateTime.now_local();
                var reversed = now.to_unix();
                add_file_to_list(file_info, now, reversed);
                sort_list();
            } catch (Error e) {
                stderr.printf("Error adding file: %s\n", e.message);
            }
        }

        private void update_file(File file) {
            try {
                acquire_lock();
                uint index;
                bool found = sorted_list.find_custom<string>(file.get_path(), (item, search_path) => {
                    return item.get_file_path() == search_path;
                }, out index);

                if (!found) {
                    release_lock();
                    return;
                }

                var file_info = file.query_info(DL_FILE_ATTRIBUTES, FileQueryInfoFlags.NONE);
                var item = sorted_list.get(index);
                item.sortable_time = (uint)file_info.get_modification_date_time().to_unix();
                release_lock();

                sort_list();
            } catch (Error e) {
                release_lock();
                stderr.printf("Error updating file: %s\n", e.message);
            }
        }

        private void remove_file(File file) {
            string file_path = file.get_path();

            acquire_lock();
            uint index;
            bool found = sorted_list.find_custom<string>(file_path, (item, search_path) => {
                return item.get_file_path() == search_path;
            }, out index);

            if (found) {
                sorted_list.remove_index(index);
            }
            release_lock();
        }

        private uint get_sortable_time(FileInfo file_info, DateTime now, int64 reversed) {
            DateTime c_time = file_info.get_creation_date_time();
            uint64 creation_time_uint;
            if (c_time != null) {
                creation_time_uint = c_time.to_unix();
            } else {
                creation_time_uint = file_info.get_modification_date_time().to_unix();
            }
            uint sortable_time = (uint)creation_time_uint;
            return sortable_time;
        }

        private void add_file_to_list(FileInfo file_info, DateTime now, int64 reversed) {
            uint sortable_time = get_sortable_time(file_info, now, reversed);
            string name = file_info.get_name();
            string full_path = GLib.Path.build_filename(dl_path, name);
            var c_time = file_info.get_modification_date_time();

            string pretty_time = BobLauncher.Utils.format_modification_time(now, c_time);

            acquire_lock();
            sorted_list.add(new DownloadsContent(full_path, pretty_time, sortable_time));
            release_lock();
        }

        private void sort_list() {
            acquire_lock();
            sorted_list.sort((a, b) => (int)(a.sortable_time - b.sortable_time));
            release_lock();
        }

        public override void search(ResultContainer rs) {
            acquire_lock();
            Score sort_time_bonus = 0;
            foreach (var item in sorted_list) {
                if (rs.has_match(item.get_title())) {
                    string path = item.get_file_path();
                    rs.add_lazy(path.hash(), sort_time_bonus, item.func);
                    sort_time_bonus++;
                }
            }
            release_lock();
        }

        private class DownloadsContent : FileMatch {
            private string pretty_time;

            public uint sortable_time { get; construct set; }

            internal DownloadsContent func() {
                return this;
            }

            public DownloadsContent(string path, string pretty_time, uint sortable_time) {
                Object (filename: path, sortable_time: sortable_time);
                this.pretty_time = pretty_time;
            }
        }
    }
}
