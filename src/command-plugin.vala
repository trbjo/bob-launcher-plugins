[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.CommandPlugin);
}

namespace BobLauncher {
    [Flags]
    public enum ExecProperty {
        NONE = 0,
        BINARY = 1 << 0,        // Regular binary executable
        SHELL = 1 << 1,         // Shell script (bash, sh, zsh)
        PERL = 1 << 2,          // Perl script
        PYTHON = 1 << 3,        // Python script
        RUBY = 1 << 4,          // Ruby script
        NODE = 1 << 5,          // Node.js script
        SYMLINK = 1 << 6,       // Is a symbolic link
        SUID = 1 << 7,          // Has SUID bit set
        SGID = 1 << 8,          // Has SGID bit set
        WORLD_WRITABLE = 1 << 9, // World writable (potential security concern)
        ROOT_ONLY = 1 << 10,    // Only executable by root
        PATH_OVERFLOW = 1 << 11; // Indicates path index needs separate lookup

        public static ExecProperty create_with_path_index(ExecProperty props, uint path_index) {
            if (path_index >= 20) { // Reserve last bit for overflow
                return props | PATH_OVERFLOW;
            }
            return props | ((path_index + 1) << 12);
        }

        public uint get_path_index() {
            if (PATH_OVERFLOW in this) {
                return uint.MAX;
            }
            uint shifted = this >> 12;
            return shifted > 0 ? (shifted - 1) : uint.MAX;
        }

        public static string to_string(ExecProperty props) {
                if (props == NONE)
                    return "";

                var builder = new StringBuilder();

                if ((props & BINARY) != 0) builder.append("Binary | ");
                if ((props & SHELL) != 0) builder.append("Shell Script | ");
                if ((props & PERL) != 0) builder.append("Perl Script | ");
                if ((props & PYTHON) != 0) builder.append("Python Script | ");
                if ((props & RUBY) != 0) builder.append("Ruby Script | ");
                if ((props & NODE) != 0) builder.append("Node.js Script | ");
                if ((props & SYMLINK) != 0) builder.append("Symlink | ");
                if ((props & SUID) != 0) builder.append("SUID | ");
                if ((props & SGID) != 0) builder.append("SGID | ");
                if ((props & WORLD_WRITABLE) != 0) builder.append("World-Writable | ");
                if ((props & ROOT_ONLY) != 0) builder.append("Root Only | ");

                return builder.str;
            }


        public string get_content_type() {
            if ((this & SHELL) != 0)
                return "application/x-shellscript";
            if ((this & PYTHON) != 0)
                return "text/x-python";
            if ((this & PERL) != 0)
                return "application/x-perl";
            if ((this & BINARY) != 0)
                return "application/x-executable";

            return "application/octet-stream";
        }
    }

    public class CommandMatch : SourceMatch, IFile, IActionMatch {
        private static string[] ENVIRONMENT;

        static construct {
            ENVIRONMENT = Environ.get();
        }

        private File? _file = null;
        public File get_file() {
            if (_file == null) {
                _file = File.new_for_path(this.filename);
            }
            return _file;
        }

        public bool do_action() {
            return BobLaunchContext.get_instance().launch_command(this.command, full_cmd, true, false);
        }

        public string get_uri() {
            if (_file == null) {
                _file = File.new_for_path(this.filename);
            }
            return _file.get_uri();
        }

        public string get_file_path() {
            if (_file == null) {
                _file = File.new_for_path(this.filename);
            }
            return _file.get_path();
        }

        public bool needs_terminal() {
            return command.has_prefix("sudo ") || command.has_prefix("doas ");
        }

        private AppInfo? _appinfo = null;
        public AppInfo get_appinfo() {
            if (_appinfo == null) {
                try {
                    _appinfo = AppInfo.create_from_commandline(this.command, filename, 0);
                } catch (Error err) {
                    warning ("%s", err.message);
                }
            }
            return _appinfo;
        }

        public string command;
        public bool is_historical;
        public string filename;
        public string[] full_cmd;
        private ExecProperty props;


        public CommandMatch(CommandPlugin plg, string full_path, string cmd, bool is_historical, ExecProperty props) {
            string[] cmd_parts;
            try {
                Shell.parse_argv(cmd, out cmd_parts);
                cmd_parts[0] = full_path;
            } catch (ShellError e) {
                warning("cmd: %s could not be created", cmd);
            }

            this.command = cmd;
            this.full_cmd = cmd_parts;
            this.filename = full_path;
            this.is_historical = is_historical;
            this.props = props;
            executed.connect(plg.command_executed);
        }

        public override string get_title() {
            return command;
        }

        public override string get_description() {
            return ExecProperty.to_string(props) + filename;
        }

        public override string get_icon_name() {
            return "application-x-executable";
        }

        public string get_mime_type() {
            return props.get_content_type();
        }
    }

    private class CommandShard {
        private void spinlock() {
            while (Threading.atomic_exchange(ref lock_token, 1) == 1) {
                Threading.pause();
            }
        }

        private void spinunlock() {
            Threading.atomic_store(ref lock_token, 0);
        }

        private int lock_token;


        private GLib.HashTable<string, ExecProperty> command_map;
        private GLib.HashTable<string, string>? overflow_paths;
        internal unowned CommandPlugin plg;

        public CommandShard(CommandPlugin plg) {
            this.plg = plg;
            command_map = new GLib.HashTable<string, ExecProperty>(str_hash, str_equal);
            overflow_paths = null;
        }

        public void add_command(string dir, string cmd_name, ExecProperty props, uint path_index) {
            spinlock();
            var cmd_props = ExecProperty.create_with_path_index(props, path_index);

            if (PATH_OVERFLOW in cmd_props) {
                if (overflow_paths == null) {
                    overflow_paths = new GLib.HashTable<string, string>(str_hash, str_equal);
                }
                overflow_paths[cmd_name] = dir;
            }

            command_map[cmd_name] = cmd_props;
            spinunlock();
        }

        public void remove_command(string cmd_name) {
            spinlock();
            if (overflow_paths != null) {
                overflow_paths.remove(cmd_name);
            }
            command_map.remove(cmd_name);
            spinunlock();
        }

        public void sharder(CommandPlugin plg, ResultContainer rs, string[] path_dirs) {
            string needle = rs.get_query().strip();
            string[] input_parts = needle.split_set(" \t");
            string base_needle = input_parts[0];
            var si = Levensteihn.StringInfo.create(base_needle);

            string input_args = input_parts.length > 1 ? needle.substring(input_parts[0].length).strip() : "";
            bool require_exact = base_needle.char_count() < 3;

            spinlock();
            try {
                command_map.foreach((cmd_name, props) => {
                    if (require_exact && cmd_name != base_needle) {
                        return;
                    }
                    int16 score = Levensteihn.match_score(si, cmd_name);
                    if (score <= 0) {
                        return;
                    }

                    string dir;
                    uint path_index = props.get_path_index();
                    if (path_index == uint.MAX && overflow_paths != null) {
                        dir = overflow_paths[cmd_name];
                    } else if (path_index == uint.MAX) {
                        return; // Corrupted state
                    } else {
                        dir = path_dirs[path_index];
                    }

                    string full_path = Path.build_filename(dir, cmd_name);
                    string argstring = input_args == "" ? cmd_name : cmd_name + " " + input_args;

                    uint cmd_hash = ((full_path.hash() << 3) ^ (argstring.hash() >> 3));
                    rs.add_lazy(cmd_hash, score, () => new CommandMatch(plg, full_path, argstring, false, props));
                });
            } finally {
                spinunlock();

            }
        }
    }

    private class CommandShardManager {
        private CommandShard[] shards;
        public uint num_shards { get; private set; }
        private string[] path_dirs;

        public CommandShardManager(int num_shards, CommandPlugin plg) {
            this.num_shards = num_shards;

            shards = new CommandShard[num_shards];
            for (int i = 0; i < num_shards; i++) {
                shards[i] = new CommandShard(plg);
            }

            path_dirs = Environment.get_variable("PATH").split(":");
        }

        private uint get_shard_index(string cmd_name) {
            uint hash = 0;
            for (int i = 0; i < cmd_name.length; i++) {
                hash = hash * 31 + cmd_name[i];
            }
            return hash % num_shards;
        }

        public void add_command(string dir, string cmd_name, ExecProperty props) {
            uint shard_index = get_shard_index(cmd_name);

            uint path_index = 0;
            bool found = false;
            for (uint i = 0; i < path_dirs.length; i++) {
                if (path_dirs[i] == dir) {
                    path_index = i;
                    found = true;
                    break;
                }
            }

            if (!found) {
                warning("Path not found in PATH: %s", dir);
                return;
            }

            shards[shard_index].add_command(dir, cmd_name, props, path_index);
        }

        public void remove_command(string cmd_name) {
            uint shard_index = get_shard_index(cmd_name);
            shards[shard_index].remove_command(cmd_name);
        }

        public void tree_manager_shard(CommandPlugin plg, ResultContainer rs, uint shard_id) {
            shards[shard_id].sharder(plg, rs, path_dirs);
        }
    }

    public class CommandPlugin : SearchBase {
        private const bool HISTORICAL = true;
        private const bool NON_HISTORICAL = false;

        private GenericSet<string> past_commands;
        private GenericArray<BobLauncher.Action> actions;
        private CommandShardManager command_manager;

        Sqlite.Database db;

        construct {
            icon_name = "system-run";
            command_manager = new CommandShardManager(7, this);
            actions = new GenericArray<BobLauncher.Action>();
            actions.add(new ForgetCommandAction(this));
        }

        public override bool activate() {
            past_commands = new GenericSet<string>(str_hash, str_equal);

            db = DatabaseUtils.open_database(this);
            create_command_history_table(db);
            load_command_history(db);
            DatabaseUtils.cleanup(db);

            base.shard_count = command_manager.num_shards + 1;

            build_command_cache();
            remove_dangerous_commands();
            return true;
        }

        public override void deactivate() {
            if (db != null) {
                DatabaseUtils.cleanup(db);
                db = null;
            }
        }

        private void build_command_cache() {
            string path = Environment.get_variable("PATH");
            if (path == null) return;

            string[] paths = path.split(":");

            foreach (string dir in paths) {
                if (dir == "")
                    continue;

                try {
                    Dir handle = Dir.open(dir);
                    string? name = null;

                    while ((name = handle.read_name()) != null) {
                        string full_path = Path.build_filename(dir, name);

                        // Skip if not executable
                        if (!FileUtils.test(full_path, FileTest.IS_EXECUTABLE))
                            continue;

                        var properties = ExecProperty.NONE;

                        try {
                            var file = File.new_for_path(full_path);
                            var info = file.query_info("standard::*,unix::*", FileQueryInfoFlags.NONE);
                            var content_type = info.get_content_type();
                            var mode = info.get_attribute_uint32("unix::mode");

                            // Check for symlink
                            if (FileUtils.test(full_path, FileTest.IS_SYMLINK))
                                properties |= ExecProperty.SYMLINK;

                            // Check script type
                            if (content_type.has_prefix("text/")) {
                                var dis = new DataInputStream(file.read());
                                string first_line = dis.read_line();

                                if (first_line != null && first_line.has_prefix("#!")) {
                                    if (first_line.has_suffix("bash") || first_line.has_suffix("sh") || first_line.has_suffix("zsh"))
                                        properties |= ExecProperty.SHELL;
                                    else if (first_line.contains("perl"))
                                        properties |= ExecProperty.PERL;
                                    else if (first_line.contains("python"))
                                        properties |= ExecProperty.PYTHON;
                                    else if (first_line.contains("ruby"))
                                        properties |= ExecProperty.RUBY;
                                    else if (first_line.contains("node"))
                                        properties |= ExecProperty.NODE;
                                }
                            } else if (content_type.has_prefix("application/x-shellscript")) {
                                properties |= ExecProperty.SHELL;
                            } else if (content_type.has_prefix("text/x-python")) {
                                properties |= ExecProperty.PYTHON;
                            } else if (content_type.has_prefix("application/x-perl")) {
                                properties |= ExecProperty.PERL;
                            } else {
                                properties |= ExecProperty.BINARY;
                            }

                            // Permission checks
                            if ((mode & 0x4000) != 0)
                                properties |= ExecProperty.SUID;
                            if ((mode & 0x2000) != 0)
                                properties |= ExecProperty.SGID;
                            if ((mode & 0x0002) != 0)
                                properties |= ExecProperty.WORLD_WRITABLE;
                            if ((mode & 0x011) == 0)
                                properties |= ExecProperty.ROOT_ONLY;

                            command_manager.add_command(dir, name, properties);

                        } catch (Error e) {
                            warning("Error analyzing file %s: %s", full_path, e.message);
                        }
                    }
                } catch (Error e) {
                    warning("Error reading directory %s: %s", dir, e.message);
                }
            }
        }

        private void remove_dangerous_commands() {
            // Common dangerous commands we want to exclude
            string[] dangerous = {
               "rm",
               "shred",
               "mkfs",
               "dd",
               "fdisk",
               "mkfs.ext4",
               "mkfs.ext3",
               "mkfs.ext2"
           };

           foreach (string cmd in dangerous) {
               command_manager.remove_command(cmd);
               // Also remove variants (e.g. rm.exe, rm-old)
               foreach (string variant in new string[] { cmd + ".", cmd + "-" }) {
                   command_manager.remove_command(variant);
               }
           }
        }

        private void create_command_history_table(Sqlite.Database db) {
            string[] setup_statements = {
                """
                CREATE TABLE IF NOT EXISTS command_history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    command TEXT NOT NULL UNIQUE,
                    timestamp INTEGER NOT NULL
                );
                """
            };
            DatabaseUtils.setup_database(db, setup_statements);
        }

        private void load_command_history(Sqlite.Database db) {
            string sql = "SELECT command FROM command_history ORDER BY timestamp DESC;";
            Sqlite.Statement stmt = DatabaseUtils.prepare_statement(db, sql);

            while (stmt.step() == Sqlite.ROW) {
                string command = stmt.column_text(0);
                past_commands.add(command);
            }
        }

        internal void command_executed(Match match, bool success) {
            if (!success) return;
            unowned CommandMatch? co = match as CommandMatch;
            if (co == null) return;
            string command = co.command.strip();
            past_commands.add(command);

            var db = DatabaseUtils.open_database(this);
            save_command_to_database(db, command);
            DatabaseUtils.cleanup(db);
        }

        private void save_command_to_database(Sqlite.Database db, string command) {
            string sql = """
                INSERT OR REPLACE INTO command_history (command, timestamp)
                VALUES ($COMMAND, $TIMESTAMP);
            """;
            Sqlite.Statement stmt = DatabaseUtils.prepare_statement(db, sql);

            stmt.bind_text(stmt.bind_parameter_index("$COMMAND"), command);
            stmt.bind_int64(stmt.bind_parameter_index("$TIMESTAMP"), (int64)time_t());

            if (stmt.step() != Sqlite.DONE) {
                warning("Failed to save command to database: %s", db.errmsg());
            }
        }

        public bool forget_command(string command) {
            var db = DatabaseUtils.open_database(this);
            string delete_sql = "DELETE FROM command_history WHERE command = ?;";
            Sqlite.Statement delete_stmt = DatabaseUtils.prepare_statement(db, delete_sql);

            delete_stmt.bind_text(1, command);

            bool result = delete_stmt.step() == Sqlite.DONE;
            if (result) {
                past_commands.remove(command);
            } else {
                warning("Failed to forget command: %s", db.errmsg());
            }

            DatabaseUtils.cleanup(db);
            return result;
        }

        protected override void search_shard(ResultContainer rs, uint shard_id) {
            string needle = rs.get_query().strip();
            if (needle.length == 0) {
                return;
            }

            if (shard_id != 0) {
                command_manager.tree_manager_shard(this, rs, shard_id - 1);
                return;
            }

            string[] input_parts = needle.split_set(" \t");
            string input_args = input_parts.length > 1 ? needle.substring(input_parts[0].length).strip() : "";

            if (needle.has_prefix("~/")) {
                needle = needle.replace("~", Environment.get_home_dir());
            }

            var iter = past_commands.iterator();
            unowned string history_cmd;
            while ((history_cmd = iter.next_value()) != null) {
                Score score = rs.match_score(history_cmd);
                if (score <= 0) continue;

                string[] parts = history_cmd.split(" ", 2);
                if (parts.length == 0) continue;

                string base_cmd = parts[0];
                string argstring = parts.length == 2 ? parts[1] : input_args;

                uint cmd_hash = ((base_cmd.hash() << 3) ^ (argstring.hash() >> 3));

                string history_cmd_dup = history_cmd.dup();

                rs.add_lazy(cmd_hash, score, () => new CommandMatch(this, base_cmd, history_cmd_dup, true, 0));
            }
        }

        public override void find_for_match(Match match, ActionSet rs) {
            foreach (var action in actions) {
                rs.add_action(action);
            }
        }

        private class ForgetCommandAction: BobLauncher.Action {
            public CommandPlugin plugin { get; construct; }
            public override string get_title() {
                return "Forget Command";
            }

            public override string get_description() {
                return "Remove this command from command history";
            }

            public override string get_icon_name() {
                return "edit-delete";
            }

            public override Score get_relevancy(Match match) {
                if (match is CommandMatch && ((CommandMatch)match).is_historical) {
                    return MatchScore.ABOVE_THRESHOLD;
                } else {
                    return MatchScore.BELOW_THRESHOLD;
                }
            }

            public ForgetCommandAction(CommandPlugin plugin) {
                Object(plugin: plugin);
            }

            protected override bool do_execute(Match match, Match? target = null) {
                if (!(match is CommandMatch)) {
                    return false;
                }
                var command_object = (CommandMatch)match;
                return plugin.forget_command(command_object.command);
            }
        }
    }
}
