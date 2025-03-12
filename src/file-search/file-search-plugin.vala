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
        private int search_size = 0;
        private GenericSet<DirectoryConfig> directory_configs;
        private GenericArray<string> monitored_paths;
        private bool is_monitoring = false;
        private Mutex mu;
        private HashTable<string,bool> ignored_suffixes;
        private Queue<DirectoryWork?> work_queue;
        private Mutex queue_mutex;
        private Cond queue_cond;
        private bool starting;
        private int cancelled;
        private uint64 thread_id;

        const string[] suffixes = {
            ".git",
            ".LOCK",
            ".lock", ".tmp", ".temp", "~", ".swp", ".swx",
            ".part", ".crdownload", ".dwl", ".dwl2", ".log", ".pid"
        };

        construct {
            icon_name = "system-file-manager";
            directory_configs = new GenericSet<DirectoryConfig>((a) => str_hash(a.path), compare_directory_infos);
            monitored_paths = new GenericArray<string>();
            mu = Mutex();
            ignored_suffixes = new HashTable<string,bool>(str_hash, str_equal);
            foreach (var suffix in suffixes) {
                ignored_suffixes.set(suffix, true);
            }
            work_queue = new Queue<DirectoryWork?>();
            queue_mutex = Mutex();
            queue_cond = Cond();
            starting = false;
            cancelled = 0;
        }

        private bool should_ignore_file(string path) {
            long last_dot = path.last_index_of(".");
            if (last_dot == -1) return false;

            string extension = path.substring(last_dot);
            return ignored_suffixes.contains(extension);
        }

        protected override bool activate(Cancellable current_cancellable) {
            current_cancellable.cancelled.connect(() => {
                queue_mutex.lock();
                starting = false;
                Threading.atomic_store(ref cancelled, 1);
                queue_cond.signal();
                queue_mutex.unlock();
            });

            Threading.atomic_store(ref search_size, 0);
            int num_shards = 128;
            base.shard_count = num_shards;
            FileTreeManager.initialize(num_shards);

            starting = true;
            Threading.atomic_store(ref cancelled, 0);

            var iter = directory_configs.iterator();
            unowned DirectoryConfig dc;
            while ((dc = iter.next_value()) != null) {
                queue_directory(
                    File.new_for_path(dc.path),
                    FileMonitorEvent.CREATED,
                    dc,
                    0,
                    new GenericArray<string>()
                );
            }

            while (starting) {
                queue_mutex.lock();
                while (work_queue.is_empty() && starting) {
                    queue_cond.wait(queue_mutex);
                }

                if (!starting) {
                    queue_mutex.unlock();
                    break;
                }

                Threading.atomic_inc(ref search_size);
                var work = work_queue.pop_head();
                queue_mutex.unlock();

                Threading.run(() => {
                    process_directory(work);
                    Threading.atomic_dec(ref search_size);
                    if (Threading.atomic_load(ref search_size) == 0) {
                        queue_mutex.lock();
                        starting = false;
                        queue_cond.signal();
                        queue_mutex.unlock();
                        message("Initialization done, monitoring %u files across %u shards",
                              FileTreeManager.total_size(), base.shard_count);

                        start_file_monitoring();

                        thread_id = Threading.spawn_joinable(dispatch_work);
                    }
                });
            }
            return true;
        }

        private void start_file_monitoring() {
            if (is_monitoring || monitored_paths.length == 0)
                return;

            string[] paths = new string[monitored_paths.length];
            for (int i = 0; i < monitored_paths.length; i++) {
                paths[i] = monitored_paths[i];
            }

            if (Monitors.add_paths(paths, on_file_changed) == 0) {
                is_monitoring = true;
                message("File monitoring started for %d paths", monitored_paths.length);
            } else {
                warning("Failed to start file monitoring");
            }
        }

        private void stop_file_monitoring() {
            if (!is_monitoring)
                return;

            string[] paths = new string[monitored_paths.length];
            for (int i = 0; i < monitored_paths.length; i++) {
                paths[i] = monitored_paths[i];
            }

            if (Monitors.remove_paths(paths) == 0) {
                is_monitoring = false;
                message("File monitoring stopped");
            } else {
                warning("Failed to stop file monitoring");
            }
        }

        private void on_file_changed(string path, int event_type) {

            FileMonitorEvent monitor_event;
            if ((event_type & (1 << 2)) != 0) { // IN_MODIFY
                monitor_event = FileMonitorEvent.CHANGES_DONE_HINT;
            } else if ((event_type & (1 << 4)) != 0) { // IN_CREATE
                monitor_event = FileMonitorEvent.CREATED;
            } else if ((event_type & (1 << 3)) != 0) { // IN_DELETE
                monitor_event = FileMonitorEvent.DELETED;
            } else {
                monitor_event = FileMonitorEvent.CHANGES_DONE_HINT;
            }

            DirectoryConfig? config = null;
            var iter = this.directory_configs.iterator();
            unowned DirectoryConfig dc;
            while ((dc = iter.next_value()) != null) {
                if (path.has_prefix(dc.path)) {
                    config = dc;
                    break;
                }
            }

            if (config != null) {
                int depth = 0;
                string rel_path = path.substring(config.path.length);

                if (rel_path != null && rel_path != "") {
                    for (int i = 0; i < rel_path.length; i++) {
                        if (rel_path[i] == '/') depth++;
                    }
                }

                this.queue_directory(
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

                    iter = this.directory_configs.iterator();
                    while ((dc = iter.next_value()) != null) {
                        if (parent_path.has_prefix(dc.path)) {
                            this.queue_directory(
                                file,
                                monitor_event,
                                dc,
                                0,
                                new GenericArray<string>()
                            );
                            break;
                        }
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

                Threading.run(() => process_directory(work));
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
                if (pattern.has_suffix("/") && relative_path.has_prefix(pattern)) {
                    return true;
                } else if (GLib.PatternSpec.match_simple(pattern, relative_path)) {
                    return true;
                }
            }
            return false;
        }

        protected override void deactivate() {
            Threading.atomic_store(ref cancelled, 1);
            queue_mutex.lock();
            starting = false;
            queue_cond.signal();
            queue_mutex.unlock();
            if (thread_id != 0) {
                Threading.join(thread_id);
                thread_id = 0;
            }

            mu.lock();
            directory_configs = new GenericSet<DirectoryConfig>(direct_hash, compare_directory_infos);
            stop_file_monitoring();
            monitored_paths = new GenericArray<string>();
            mu.unlock();
            message("deactivate file search done");
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

                    string bname = work.file.get_basename();
                    if (!work.config.show_hidden && bname.has_prefix(".")) {
                        break;
                    }

                    var path = work.file.get_path();
                    FileTreeManager.add_file(path);

                    mu.lock();
                    if (!monitored_paths.find_with_equal_func(path, (a, b) => a == b)) {
                        monitored_paths.add(path);
                    }
                    mu.unlock();

                    if (info.get_file_type() != FileType.DIRECTORY) {
                        break;
                    }

                    var gitignore_patterns = work.gitignore_patterns.copy((item) => item);
                    if (work.config.respect_gitignore) {
                        File gitignore_file = work.file.get_child(".gitignore");
                        if (gitignore_file.query_exists()) {
                            var current_patterns = load_gitignore_patterns(gitignore_file);
                            gitignore_patterns.extend(current_patterns, (item) => item);
                        }
                    }

                    /*
                    try {
                        var monitor = work.file.monitor(FileMonitorFlags.NONE);
                        monitor.changed.connect((f, of, et) => {
                            queue_directory(f, et, work.config, work.depth + 1, gitignore_patterns);
                        });
                        mu.lock();
                        directory_monitors.add(monitor);
                        mu.unlock();
                    } catch (Error err) {
                        message("Can't monitor new dir: %s", err.message);
                    }
                    */

                    try {
                        var enumerator = work.file.enumerate_children(FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NONE);

                        FileInfo next_info;
                        while ((next_info = enumerator.next_file()) != null) {
                            var name = next_info.get_name();
                            var child = work.file.get_child(name);

                            mu.lock();
                            if (directory_configs.contains(new DirectoryConfig(child.get_path(), 0))) {
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

                    mu.lock();
                    for (int i = 0; i < monitored_paths.length; i++) {
                        if (monitored_paths[i] == path) {
                            monitored_paths.remove_index(i);
                            break;
                        }
                    }
                    mu.unlock();
                    break;
            }
        }

        protected override void search_shard(ResultContainer rs, uint shard_id) {
            FileTreeManager.tree_manager_shard(rs, shard_id, this.bonus);
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

        public override void on_setting_initialized(string key, GLib.Variant value) {
            if (key == "directory-configs") {
                initialize_dir_config(value);
            }
        }

        public override SettingsCallback? on_setting_changed(string key, GLib.Variant value) {
            if (key == "directory-configs") {
                return (cancellable) => {
                    update_dir_config(key, value, cancellable);
                };
            }
            return null;
        }

        private void initialize_dir_config(GLib.Variant value) {
            VariantIter iter = value.iterator();
            string path;
            int max_depth;
            bool show_hidden;
            bool respect_gitignore;
            string home = Environment.get_home_dir();

            while (iter.next("(sibb)", out path, out max_depth, out show_hidden, out respect_gitignore)) {
                if (path.has_prefix("$HOME")) {
                    path = path.replace("$HOME", home);
                }
                directory_configs.add(new DirectoryConfig(path, max_depth, show_hidden, respect_gitignore));
            }
        }

        private void update_dir_config(string key, GLib.Variant value, Cancellable current_cancellable) {
            deactivate();
            initialize_dir_config(value);
            activate(current_cancellable);
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
