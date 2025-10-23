[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.FileSearchPlugin);
}

namespace BobLauncher {
    private struct DirectoryWork {
        public File file;
        public FileMonitorEvent event_type;
        public DirectoryConfig config;
        public int depth;
        public GenericArray<string> gitignore_patterns;

        public DirectoryWork(
            File file,
            FileMonitorEvent event_type,
            DirectoryConfig config,
            int depth,
            GenericArray<string> gitignore_patterns
        ) {
            this.file = file;
            this.event_type = event_type;
            this.config = config;
            this.depth = depth;
            this.gitignore_patterns = gitignore_patterns;
        }
    }

    public class FileSearchPlugin : SearchBase {
        private static HashTable<string, DirectoryConfig>? directory_configs;
        private HashTable<string, bool> monitored_paths;
        private Mutex mu;
        private HashTable<string,bool> ignored_suffixes;
        private Queue<DirectoryWork?> work_queue;
        private Mutex queue_mutex;
        private INotify.Monitor monitor;
        private Cond queue_cond;
        private int cancelled;
        private ulong thread_id;
        internal static unowned FileSearchPlugin instance;

        const string[] suffixes = {
            ".git",
            ".LOCK",
            ".lock", ".tmp", ".temp", "~", ".swp", ".swx",
            ".part", ".crdownload", ".dwl", ".dwl2", ".log", ".pid"
        };

        construct {
            icon_name = "system-file-manager";
            monitored_paths = new HashTable<string, bool>(str_hash, str_equal);
            monitor = new INotify.Monitor(on_file_changed);
            mu = Mutex();
            ignored_suffixes = new HashTable<string,bool>(str_hash, str_equal);
            foreach (var suffix in suffixes) {
                ignored_suffixes.set(suffix, true);
            }
            work_queue = new Queue<DirectoryWork?>();
            queue_mutex = Mutex();
            queue_cond = Cond();
            instance = this;
        }

        private bool should_ignore_file(string path) {
            long last_dot = path.last_index_of(".");
            if (last_dot == -1) return false;

            string extension = path.substring(last_dot);
            return ignored_suffixes.contains(extension);
        }

        private static int compare_dirs(DirectoryConfig? a, DirectoryConfig? b) {
            return strcmp(b.path, a.path);
        }


        public override bool activate() {
            int num_shards = 32;
            base.shard_count = num_shards;
            FileTreeManager.initialize(num_shards, Environment.get_variable("HOME"));
            // TODO: make configurable and dynamic.

            Threading.atomic_store(ref cancelled, 0);
            thread_id = Threading.spawn_joinable(dispatch_work);

            var configs = directory_configs.get_values();
            configs.sort(compare_dirs);
            foreach (unowned var cfg in configs) {
                queue_directory(
                    File.new_for_path(cfg.path),
                    FileMonitorEvent.CREATED,
                    cfg,
                    0,
                    new GenericArray<string>()
                );
            }

            start_file_monitoring();
            return true;
        }

        private void start_file_monitoring() {
            if (monitored_paths.size() == 0)
                return;

            if (monitor.add_paths(monitored_paths.get_keys_as_array()) != 0) {
                warning("Failed to start file monitoring");
            }
        }

        private void stop_file_monitoring() {
            if (monitor.remove_paths(monitored_paths.get_keys_as_array()) != 0) {
                warning("Failed to stop file monitoring");
            }
        }

        private void on_file_changed(string path, int event_type) {
            mu.lock();
            _on_file_changed(path, event_type);
            mu.unlock();
        }

        private DirectoryConfig? find_best_dc(string path) {
            DirectoryConfig? config = directory_configs.get(path); // exact match;
            if (config == null) { // prefix matching
                var configs = directory_configs.get_values();
                configs.sort(compare_dirs);
                foreach (unowned var cfg in configs) {
                    if (path.has_prefix(cfg.path)) {
                        return cfg;
                    }
                }
            }
            return null;
        }

        private void _on_file_changed(string path, int event_type) {
            FileMonitorEvent monitor_event = FileUtils.test(path, FileTest.EXISTS) ?
                                                FileMonitorEvent.CHANGES_DONE_HINT :
                                                FileMonitorEvent.DELETED;

            DirectoryConfig? config = find_best_dc(path);

            if (config != null) {
                int depth = 0;
                string rel_path = path.substring(config.path.length);

                if (rel_path != null && rel_path != "") {
                    for (int i = 0; i < rel_path.length; i++) {
                        if (rel_path[i] == '/') depth++;
                    }
                }

                instance.queue_directory(
                    File.new_for_path(path),
                    monitor_event,
                    config,
                    depth,
                    new GenericArray<string>()
                );
            } else {
                File file = File.new_for_path(path);
                File parent = file.get_parent();

                if (parent != null) {
                    string parent_path = parent.get_path();
                    DirectoryConfig? dc = find_best_dc(parent_path);
                    if (dc != null) {
                        instance.queue_directory(
                            file,
                            monitor_event,
                            dc,
                            0,
                            new GenericArray<string>()
                        );
                    }
                }
            }
        }

        private void dispatch_work() {
            while (Threading.atomic_load(ref cancelled) == 0) {
                queue_mutex.lock();
                while (work_queue.is_empty() && Threading.atomic_load(ref cancelled) == 0) {
                    queue_cond.wait(queue_mutex);
                }

                if (Threading.atomic_load(ref cancelled) != 0) {
                    queue_mutex.unlock();
                    break;
                }

                var work = work_queue.pop_head();
                queue_mutex.unlock();

                process_directory(work);
            }
        }

        private GenericArray<string> load_gitignore_patterns(File gitignore_file) {
            GenericArray<string> patterns = new GenericArray<string>();

            try {
                DataInputStream input_stream = new DataInputStream(gitignore_file.read());
                string line;
                while ((line = input_stream.read_line()) != null) {
                    line = line.strip();
                    if (line.length > 0 && !line.has_prefix("#")) {
                        while (line.has_suffix("/") && line.length > 1) {
                            line = line.substring(0, line.length - 1);
                        }
                        patterns.add(line);
                    }
                }
            } catch (Error e) {
                warning("Error while loading .gitignore patterns: %s", e.message);
            }

            debug("loading gitignore for %s, %s", gitignore_file.get_path(), print_string_list(patterns));
            return patterns;
        }

        public static string print_string_list(GenericArray<string> list) {
            var builder = new StringBuilder ("[");
            bool first = true;
            foreach (var item in list) {
                if (!first) {
                    builder.append (", ");
                }
                builder.append ("\"");
                builder.append ((string)item);
                builder.append ("\"");
                first = false;
            }
            builder.append ("]");
            return builder.str;
        }

        private bool is_ignored(string path, GenericArray<string> patterns, string base_path) {
            string relative_path = path.substring(base_path.length + 1);

            foreach (string pattern in patterns) {
                if (pattern.has_prefix("/")) {
                    pattern = pattern.substring(1);
                }

                if (relative_path == pattern ||
                    relative_path.has_prefix(pattern + "/") ||
                    (pattern.has_suffix("/") && relative_path.has_prefix(pattern)) ||
                    GLib.PatternSpec.match_simple(pattern, relative_path)) {
                    return true;
                }
            }
            return false;
        }

        public override void deactivate() {
            Threading.atomic_store(ref cancelled, 1);
            queue_mutex.lock();
            queue_cond.signal();
            queue_mutex.unlock();

            if (thread_id != 0) {
                Threading.join(thread_id);
                thread_id = 0;
            }

            mu.lock();
            directory_configs = new HashTable<string, DirectoryConfig>(str_hash, str_equal);
            stop_file_monitoring();
            monitored_paths = new HashTable<string, bool>(str_hash, str_equal);
            mu.unlock();
        }

        private void queue_directory(
            File file,
            FileMonitorEvent event_type,
            DirectoryConfig config,
            int depth,
            GenericArray<string> gitignore_patterns
        ) {
            var work = DirectoryWork(file, event_type, config, depth, gitignore_patterns);
            queue_mutex.lock();
            work_queue.push_tail(work);
            queue_cond.signal();
            queue_mutex.unlock();
        }

        private void process_directory(DirectoryWork work) {
            if (should_ignore_file(work.file.get_path())) {
                return;
            }

            if (!work.file.query_exists()) {
                work.event_type = FileMonitorEvent.DELETED;
            }

            switch (work.event_type) {
                case FileMonitorEvent.CREATED:
                case FileMonitorEvent.CHANGES_DONE_HINT:
                    if (work.config.max_depth == 0 ||
                        (work.config.max_depth != -1 && work.depth >= work.config.max_depth)) {
                        break;
                    }

                    FileInfo info;
                    try {
                        info = work.file.query_info(FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NONE);
                    } catch (Error e) {
                        message("Failed to handle file change: %s", e.message);
                        break;
                    }

                    if (info == null) break;

                    var path = work.file.get_path();
                    FileTreeManager.add_file(path);

                    if (info.get_file_type() != FileType.DIRECTORY) {
                        break;
                    }

                    mu.lock();
                    if (monitored_paths.get(path)) {
                        mu.unlock();
                        return;
                    }
                    monitored_paths.set(path, true);
                    mu.unlock();
                    monitor.add_path(path);


                    var gitignore_patterns = work.gitignore_patterns.copy((item) => item);
                    if (work.config.respect_gitignore) {
                        File gitignore_file = work.file.get_child(".gitignore");
                        if (gitignore_file.query_exists()) {
                            var current_patterns = load_gitignore_patterns(gitignore_file);
                            gitignore_patterns.extend(current_patterns, (item) => item.strip());
                        }
                    }

                    try {
                        var enumerator = work.file.enumerate_children(FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NONE);

                        FileInfo next_info;
                        while ((next_info = enumerator.next_file()) != null) {
                            var name = next_info.get_name();
                            var child = work.file.get_child(name);

                            if (!work.config.show_hidden && name.has_prefix(".")) {
                                continue;
                            }

                            mu.lock();
                            if (directory_configs.contains(child.get_path())) {
                                debug("already have: %s, not adding", child.get_path());
                                mu.unlock();
                                continue;
                            }
                            mu.unlock();

                            if (gitignore_patterns.length > 0 &&
                                is_ignored(child.get_path(), gitignore_patterns, path)) {
                                continue;
                            }

                            queue_directory(
                                child,
                                FileMonitorEvent.CREATED,
                                work.config,
                                work.depth + 1,
                                gitignore_patterns
                            );
                        }
                    } catch (Error e) {
                        warning("Error enumerating directory: %s", e.message);
                    }
                    break;

                case FileMonitorEvent.DELETED:
                    var path = work.file.get_path();
                    FileTreeManager.remove_file(path);

                    for (uint i = 0; i < this.shard_count; i++) {
                        uint shard_id = i;
                        Threading.run(() => FileTreeManager.remove_by_prefix_shard(shard_id, path));
                    }

                    mu.lock();
                    monitored_paths.remove(path);
                    mu.unlock();
                    monitor.remove_path(path);
                    break;
            }
        }

        protected override void search_shard(ResultContainer rs, uint shard_id) {
            FileTreeManager.tree_manager_shard(rs, shard_id);
        }

        private static bool compare_directory_infos(DirectoryConfig a, DirectoryConfig b) {
            if (a.show_hidden != b.show_hidden) {
                return false;
            }

            if (a.respect_gitignore != b.respect_gitignore) {
                return false;
            }

            if (a.max_depth != b.max_depth) {
                return false;
            }

            if (strcmp(a.path, b.path) != 0) {
                return false;
            }

            return true;
        }

        public override void on_setting_changed(string key, GLib.Variant value) {
            if (key != "directory-configs") return;
            if (directory_configs == null) {
                initialize_dir_config(value);
            } else {
                deactivate();
                initialize_dir_config(value);
                activate();
            }
        }

        private void initialize_dir_config(GLib.Variant value) {
            directory_configs = new HashTable<string, DirectoryConfig>(str_hash, str_equal);

            VariantIter iter = value.iterator();
            string path;
            int max_depth;
            bool show_hidden;
            bool respect_gitignore;

            while (iter.next("(sibb)", out path, out max_depth, out show_hidden, out respect_gitignore)) {
                path = expand_environment_variables(path);
                directory_configs.set(path, new DirectoryConfig(path, max_depth, show_hidden, respect_gitignore));
            }
        }

        private string expand_environment_variables(string input) {
            string result = input;
            int search_start = 0;

            while (true) {
                int dollar_pos = result.index_of("${", search_start);
                if (dollar_pos == -1) {
                    break;
                }

                int end_pos = result.index_of("}", dollar_pos);
                if (end_pos == -1) {
                    // Malformed variable (missing closing brace), stop processing
                    break;
                }

                string var_name = result.substring(dollar_pos + 2, end_pos - dollar_pos - 2);
                string? var_value = Environment.get_variable(var_name);

                if (var_value != null) {
                    result = result.substring(0, dollar_pos) + var_value + result.substring(end_pos + 1);
                    search_start = dollar_pos + var_value.length;
                } else {
                    // Variable not found, skip past this occurrence to avoid infinite loop
                    search_start = end_pos + 1;
                }
            }

            return result;
        }

    }

    public class DirectoryConfig {
        public string path;
        public int max_depth;
        public bool show_hidden;
        public bool respect_gitignore;

        public DirectoryConfig(string path, int max_depth = -1, bool show_hidden = false, bool respect_gitignore = true) {
            this.path = path;
            this.max_depth = max_depth;
            this.show_hidden = show_hidden;
            this.respect_gitignore = respect_gitignore;
        }
    }
}
