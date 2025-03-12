[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.DownloadsPlugin);
}


namespace BobLauncher {
    public class DownloadsPlugin : SearchBase {
        private GenericArray<DownloadsContent> sorted_list;
        private FileMonitor? directory_monitor;
        private File download_directory;
        private string dl_path;

        construct {
            icon_name = "folder-download";
            sorted_list = new GenericArray<DownloadsContent>();
            download_directory = File.new_for_path(get_download_dir());
            dl_path = download_directory.get_path();
        }

        protected override bool activate(Cancellable current_cancellable) {
            load_directory_contents();
            // try {
                // directory_monitor = download_directory.monitor_directory(FileMonitorFlags.NONE);
                // directory_monitor.changed.connect(on_file_changed);
                return true;
            // } catch (Error e) {
                // stderr.printf("Error setting up file monitor: %s\n", e.message);
                // return false;
            // }
        }


        protected override void deactivate() {
            if (directory_monitor != null) {
                directory_monitor.cancel();
                directory_monitor = null;
            }
            sorted_list = new GenericArray<DownloadsContent>();
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
            FileAttribute.STANDARD_IS_HIDDEN;

        private void load_directory_contents() {
            sorted_list = new GenericArray<DownloadsContent>();
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

        private void on_file_changed(File file, File? other_file, FileMonitorEvent event_type) {
            switch (event_type) {
                case FileMonitorEvent.CREATED:
                case FileMonitorEvent.CHANGED:
                    update_file(file);
                    break;
                case FileMonitorEvent.DELETED:
                    remove_file(file);
                    break;
                default:
                    break;
            }
        }

        private void update_file(File file) {
            try {
                var file_info = file.query_info(DL_FILE_ATTRIBUTES, FileQueryInfoFlags.NONE);
                uint index;
                bool found = sorted_list.find_custom<string>(file.get_path(), (item, search_path) => {
                    return item.get_file_path() == search_path;
                }, out index);

                if (found) {
                    sorted_list.remove_index(index);
                }
                var now = new DateTime.now_local();
                var reversed = now.to_unix();
                add_file_to_list(file_info, now, reversed);
                sort_list();
            } catch (Error e) {
                stderr.printf("Error updating file: %s\n", e.message);
            }
        }

        private void remove_file(File file) {
            string file_path = file.get_path();
            uint index;
            bool found = sorted_list.find_custom<string>(file_path, (item, search_path) => {
                return item.get_file_path() == search_path;
            }, out index);

            if (found) {
                sorted_list.remove_index(index);
            }
        }

        private void add_file_to_list(FileInfo file_info, DateTime now, int64 reversed) {
            string name = file_info.get_name();
            string full_path = GLib.Path.build_filename(dl_path, name);
            DateTime c_time = file_info.get_creation_date_time();
            uint64 creation_time_uint;
            if (c_time != null) {
                creation_time_uint = c_time.to_unix();
            } else {
                creation_time_uint = uint64.MIN;
            }

            uint sortable_time = (uint)(reversed - creation_time_uint);
            string pretty_time = BobLauncher.Utils.format_modification_time(now, c_time);

            sorted_list.add(new DownloadsContent(full_path, pretty_time, sortable_time));
        }

        private void sort_list() {
            sorted_list.sort((a, b) => (int)(b.sortable_time - a.sortable_time));
        }

        public override void search(ResultContainer rs) {
            foreach (var item in sorted_list) {
                if (rs.has_match(item.get_title())) {
                    string path = item.get_file_path();
                    rs.add_lazy(path.hash(), item.sortable_time + bonus, item.func);
                }
            }
        }

        private class DownloadsContent : FileMatch {
            private string pretty_time;

            public uint sortable_time { get; construct; }

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
