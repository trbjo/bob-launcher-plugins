namespace BobLauncher {
    errordomain DesktopFileError {
        UNINTERESTING_ENTRY
    }

    public class DesktopFileInfo : Object {
        public string name { get; construct; }
        public string comment { get; construct; }
        public string icon_name { get; construct; }
        public DesktopAppInfo app_info { get; construct; }

        public bool needs_terminal { get; construct; }
        public bool is_hidden { get; construct; }
        public string file_base_name { get; construct; }

        public string exec { get; construct; }

        public string[] actions { get; construct; }
        public string[] mime_types { get; construct; }
        public string[] categories { get; construct; }

        public DesktopFileInfo(
                                string name,
                                string file_base_name,
                                string comment,
                                string icon_name,
                                DesktopAppInfo app_info,
                                bool needs_terminal,
                                bool is_hidden,
                                string exec,
                                string[] actions,
                                string[] mime_types,
                                string[] categories
         ) {
            Object(
                name: name,
                file_base_name: file_base_name,
                comment: comment,
                icon_name: icon_name,
                app_info: app_info,
                needs_terminal: needs_terminal,
                is_hidden: is_hidden,
                exec: exec,
                actions: actions,
                mime_types: mime_types,
                categories: categories
            );
        }
    }

    public class DesktopFileService : Object {
        private static Regex exec_re;

        static construct {
            try {
                exec_re = new Regex ("%[fFuU]");
            } catch (Error err) {
                critical ("%s", err.message);
            }
        }

        private GLib.HashTable<string, FileMonitor> directory_monitors;
        public GLib.HashTable<string, DesktopFileInfo> desktop_files { get; construct; }
        public GLib.HashTable<string, GenericArray<unowned DesktopFileInfo>> mimetype_map { get; construct; }

        public signal void reload_started();
        public signal void reload_done();

        construct {
            desktop_files = new GLib.HashTable<string, DesktopFileInfo>(str_hash, str_equal);
            mimetype_map = new GLib.HashTable<string, GenericArray<unowned DesktopFileInfo?>>(str_hash, str_equal);

            load_all_desktop_files();
            load_mime_types();
        }

        private void load_all_desktop_files() {
            desktop_files.remove_all();

            string[] data_dirs = Environment.get_system_data_dirs();
            data_dirs += Environment.get_user_data_dir();

            GLib.HashTable<string, File> desktop_file_dirs = new GLib.HashTable<string, File>(str_hash, str_equal);

            foreach (unowned string data_dir in data_dirs) {
                string dir_path = Path.build_filename(data_dir, "applications", null);
                var directory = File.new_for_path(dir_path);
                desktop_file_dirs.set(dir_path, directory);
                process_directory(directory);
            }

            directory_monitors = new GLib.HashTable<string, FileMonitor>(str_hash, str_equal);
            desktop_file_dirs.foreach((k, d) => {
                try {
                    FileMonitor monitor = d.monitor_directory(0, null);
                    monitor.changed.connect(this.desktop_file_directory_changed);
                    directory_monitors.set(k, monitor);
                }
                catch (Error err) {
                    warning ("Unable to monitor directory: %s", err.message);
                }
            });
        }

        private void process_directory(File directory) {
            try {
                string path = directory.get_path();
                debug("Searching for desktop files in: %s", path);
                if (!(directory.query_exists())) return;

                var enumerator = directory.enumerate_children(FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE, 0, null);
                FileInfo f;
                while ((f = enumerator.next_file(null)) != null) {
                    if (!(f.get_file_type() == FileType.DIRECTORY)) {
                        unowned string name = f.get_name();
                        if (name.has_suffix(".desktop") && !(name.has_prefix(BOB_LAUNCHER_APP_ID))) {
                            load_desktop_file(directory.get_child(name));
                        }
                    }
                }
            } catch (Error err) {
                warning ("%s", err.message);
            }
        }

        private void desktop_file_directory_changed() {
            reload_started();
            reload_desktop_files();
        }

        private void reload_desktop_files() {
            debug("Reloading desktop files...");
            load_all_desktop_files();
            load_mime_types();
            reload_done();
        }

        private void load_desktop_file(File file) {
            var keyfile = new KeyFile();
            var file_name = file.get_basename();
            try {
                keyfile.load_from_file(file.get_path(), 0);
                desktop_files[file_name] = dfi_from_keyfile(keyfile, file_name);
            } catch (Error err) {
                debug("%s", err.message);
            }
        }

        private void load_mime_types() {
            mimetype_map.remove_all();

            desktop_files.foreach((key, dfi) => {
                if (dfi.is_hidden || dfi.mime_types == null) {
                    return;
                }

                foreach (unowned string mime_type in dfi.mime_types) {
                    GenericArray<unowned DesktopFileInfo?>? list = mimetype_map[mime_type];
                    if (list == null) {
                        list = new GenericArray<unowned DesktopFileInfo?>();
                        mimetype_map[mime_type] = list;
                    }
                    list.add(dfi);
                }
            });

            sort_mime_type_handlers();
        }

        private DesktopFileInfo? find_default_handler(string mime_type) {
            AppInfo? default_app = AppInfo.get_default_for_type(mime_type, false);
            if (default_app == null) {
                return null;
            }

            var default_id = default_app.get_id();
            if (default_id == null) {
                return null;
            }

            return desktop_files.get(default_id);
        }


        private void sort_mime_type_handlers() {
            mimetype_map.foreach((mime_type, handlers) => {
                if (handlers == null || handlers.length == 0) {
                    return;
                }

                var default_handler = find_default_handler(mime_type);

                handlers.sort_with_data((dfi_a, dfi_b) => {
                    if (dfi_a == null) return 1;
                    if (dfi_b == null) return -1;

                    if (default_handler != null && dfi_a == default_handler) return -1;
                    if (default_handler != null && dfi_b == default_handler) return 1;

                    return dfi_a.name.collate(dfi_b.name);
                });
            });
        }

        public bool set_default_handler_for_mime_type(string desktop_id, string mime_type) throws Error {
            var desktop_info = desktop_files.get(desktop_id);
            if (desktop_info == null) {
                throw new Error(Quark.from_string("DesktopFileService"), 0,
                    "No desktop entry found for id: %s".printf(desktop_id));
            }

            var app_info = desktop_info.app_info;
            if (app_info == null) {
                throw new Error(Quark.from_string("DesktopFileService"), 1,
                    "No AppInfo found for desktop entry: %s".printf(desktop_id));
            }

            bool success = app_info.set_as_default_for_type(mime_type);
            if (success) {
                sort_mime_type_handlers();
            }

            return success;
        }



        public GenericArray<unowned DesktopFileInfo?> get_desktop_files_for_type(string mime_type) {
            return mimetype_map[mime_type] ?? new GenericArray<unowned DesktopFileInfo?>();
        }

        private static DesktopFileInfo dfi_from_keyfile(KeyFile keyfile, string file_base_name) throws GLib.Error {
            if (keyfile.get_string (KeyFileDesktop.GROUP, KeyFileDesktop.KEY_TYPE) != KeyFileDesktop.TYPE_APPLICATION) {
                throw new DesktopFileError.UNINTERESTING_ENTRY ("Not Application-type desktop entry");
            }

            DesktopAppInfo app_info = new DesktopAppInfo.from_keyfile(keyfile);

            if (app_info == null) {
                throw new DesktopFileError.UNINTERESTING_ENTRY ("Unable to create AppInfo for %s".printf(file_base_name));
            }

            string name = app_info.get_name();

            string? exec = app_info.get_commandline();
            if (exec == null) {
                throw new DesktopFileError.UNINTERESTING_ENTRY ("Unable to get exec for %s".printf(name));
            }

            try {
                exec = exec_re.replace_literal(exec, -1, 0, "");
            } catch (RegexError err) {
                critical("%s", err.message);
            }
            exec = exec.strip();

            bool needs_terminal = false;
            if (keyfile.has_key(KeyFileDesktop.GROUP, KeyFileDesktop.KEY_TERMINAL)) {
                needs_terminal = keyfile.get_boolean(KeyFileDesktop.GROUP, KeyFileDesktop.KEY_TERMINAL);
            }

            bool is_hidden = false;
            if (keyfile.has_key(KeyFileDesktop.GROUP, KeyFileDesktop.KEY_HIDDEN) &&
                keyfile.get_boolean(KeyFileDesktop.GROUP, KeyFileDesktop.KEY_HIDDEN)) {
                is_hidden = true;
            }
            if (keyfile.has_key(KeyFileDesktop.GROUP, KeyFileDesktop.KEY_NO_DISPLAY) &&
                keyfile.get_boolean(KeyFileDesktop.GROUP, KeyFileDesktop.KEY_NO_DISPLAY)) {
                is_hidden = true;
            }

            string comment = app_info.get_description() ?? "";

            var icon = app_info.get_icon() ?? new ThemedIcon("application-default-icon");
            string icon_name = icon.to_string();

            string[] mime_types = new string[0];
            if (keyfile.has_key(KeyFileDesktop.GROUP, KeyFileDesktop.KEY_MIME_TYPE)) {
                mime_types = keyfile.get_string_list(KeyFileDesktop.GROUP, KeyFileDesktop.KEY_MIME_TYPE);
            }

            string[] actions = new string[0];
            if (keyfile.has_key(KeyFileDesktop.GROUP, KeyFileDesktop.KEY_ACTIONS)) {
                actions = keyfile.get_string_list(KeyFileDesktop.GROUP, KeyFileDesktop.KEY_ACTIONS);
            }

            string[] categories = new string[0];
            if (keyfile.has_key(KeyFileDesktop.GROUP, KeyFileDesktop.KEY_CATEGORIES)) {
                categories = keyfile.get_string_list(KeyFileDesktop.GROUP, KeyFileDesktop.KEY_CATEGORIES);
            }

            return new DesktopFileInfo(
                                       name,
                                       file_base_name,
                                       comment,
                                       icon_name,
                                       app_info,
                                       needs_terminal,
                                       is_hidden,
                                       exec,
                                       actions,
                                       mime_types,
                                       categories
            );
        }
    }
}
