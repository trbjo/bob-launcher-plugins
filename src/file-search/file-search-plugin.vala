[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.FileSearchPlugin);
}

namespace BobLauncher {
    public class DirectoryConfig {
        public string path;
        public uint max_depth;
        public bool show_hidden;
        public bool respect_gitignore;

        public DirectoryConfig(string path, int max_depth, bool show_hidden = false, bool respect_gitignore = true) {
            this.path = path;
            this.max_depth = (uint)max_depth;
            this.show_hidden = show_hidden;
            this.respect_gitignore = respect_gitignore;
        }
    }

    private class DirectoryWork {
        public string path;
        public DirectoryConfig config;
        public int depth;
        public GenericArray<string> gitignore_patterns;

        public DirectoryWork(
            string path,
            DirectoryConfig config,
            int depth,
            GenericArray<string> gitignore_patterns
        ) {
            this.path = path;
            this.config = config;
            this.depth = depth;
            this.gitignore_patterns = gitignore_patterns;
        }
    }

    public class FileSearchPlugin : SearchBase {
        private static HashTable<string, DirectoryConfig>? directory_configs;
        private HashTable<string,bool> ignored_suffixes;
        private INotify.Monitor? monitor;
        private int cancelled;

        const string[] suffixes = {
            ".git",
            ".LOCK",
            ".lock", ".tmp", ".temp", "~", ".swp", ".swx",
            ".part", ".crdownload", ".dwl", ".dwl2", ".log", ".pid"
        };

        construct {
            icon_name = "system-file-manager";
            ignored_suffixes = new HashTable<string,bool>(str_hash, str_equal);
            foreach (var suffix in suffixes) {
                ignored_suffixes.set(suffix, true);
            }
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

        private List<unowned DirectoryConfig> get_directory_configs_sorted() {
            var configs = directory_configs.get_values();
            configs.sort(compare_dirs);
            return configs;
        }

        public override bool activate() {
            const int num_shards = 128;
            // TODO: make configurable and dynamic.

            base.shard_count = num_shards;
            FileTreeManager.initialize(num_shards);

            Threading.atomic_store(ref cancelled, 0);

            monitor = new INotify.Monitor(on_file_changed);

            var configs = get_directory_configs_sorted();
            foreach (unowned var cfg in configs) {
                queue_addition(
                    cfg.path,
                    cfg,
                    0,
                    new GenericArray<string>()
                );
            }

            return true;
        }

        private void on_file_changed(string path, int event_type) {
            if (Threading.atomic_load(ref cancelled) == 1) return;

            bool is_deleted =
                ((event_type & INotify.EventType.DELETE) != 0 ||
                 (event_type & INotify.EventType.DELETE_SELF) != 0 ||
                 (event_type & INotify.EventType.MOVED_FROM) != 0)
                    ? true
                    : false;

            if (is_deleted) {
                FileTreeManager.remove_file(path);
            } else {
                DirectoryConfig? config = find_best_dc(path);
                if (config == null) return;

                int depth = 0;
                string rel_path = path.substring(config.path.length);

                for (int i = 0; i < rel_path.length; i++) {
                    if (rel_path[i] == '/') depth++;
                }
                var work = new DirectoryWork(path, config, depth, new GenericArray<string>());
                handle_file_add_or_change(work);
            }
        }

        private DirectoryConfig? find_best_dc(string path) {
            DirectoryConfig? config = directory_configs.get(path); // exact match;
            if (config != null) return config;

            var configs = get_directory_configs_sorted();
            foreach (unowned var cfg in configs) {
                if (path.has_prefix(cfg.path)) {
                    return cfg;
                }
            }
            return null;
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

        private bool is_name_ignored(string name, GenericArray<string> patterns) {
            foreach (string pattern in patterns) {
                if (pattern.has_prefix("/")) {
                    pattern = pattern.substring(1);
                }

                if (name == pattern || GLib.PatternSpec.match_simple(pattern, name)) {
                    return true;
                }
            }
            return false;
        }

        public override void deactivate() {
            Threading.atomic_store(ref cancelled, 1);
            directory_configs = new HashTable<string, DirectoryConfig>(str_hash, str_equal);
            monitor = null;
        }

        private void queue_addition(
            string path,
            DirectoryConfig config,
            int depth,
            GenericArray<string>? gitignore_patterns
        ) {
            if (Threading.atomic_load(ref cancelled) == 1) return;
            Threading.run(() => {
                var work = new DirectoryWork(path, config, depth, gitignore_patterns);
                handle_file_add_or_change(work);
            });
        }

        private void handle_file_add_or_change(DirectoryWork work) {
            if (should_ignore_file(work.path)) {
                return;
            }

            FileTreeManager.add_file(work.path);

            if (work.depth >= work.config.max_depth) {
                return;
            }

            if (!FileUtils.test(work.path, FileTest.IS_DIR)) {
                return;
            }

            monitor.add_path(work.path);

            var gitignore_patterns = work.gitignore_patterns.copy((item) => item);
            if (work.config.respect_gitignore) {
                var gitignore_path = Path.build_filename(work.path, ".gitignore");
                if (FileUtils.test(gitignore_path, FileTest.EXISTS)) {
                    var current_patterns = load_gitignore_patterns(File.new_for_path(gitignore_path));
                    gitignore_patterns.extend(current_patterns, (item) => item.strip());
                }
            }

            Dir dir;

            try {
                dir = Dir.open(work.path);
            } catch (FileError e) {
                warning("Error enumerating directory: %s", e.message);
                return;
            }

            string? name;
            while ((name = dir.read_name()) != null) {
                if (!work.config.show_hidden && name.has_prefix(".")) {
                    continue;
                }

                if (is_name_ignored(name, gitignore_patterns)) {
                    continue;
                }

                var child_path = Path.build_filename(work.path, name);

                if (directory_configs.contains(child_path)) {
                    debug("already have: %s, not recursing for: %s", child_path, work.config.path);
                    continue;
                }

                Idle.add(() => {
                    queue_addition(child_path, work.config, work.depth + 1, gitignore_patterns);
                    return false;
                }, GLib.Priority.LOW);
            }
        }

        protected override void search_shard(ResultContainer rs, uint shard_id) {
            FileTreeManager.tree_manager_shard(rs, shard_id);
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
}
