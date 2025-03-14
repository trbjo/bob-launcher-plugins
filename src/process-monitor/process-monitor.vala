using ProcessUtils;

[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.ProcessMonitorPlugin);
}

namespace BobLauncher {
    public class ProcessMonitorPlugin : SearchAction {
        private enum SortBy {
            PID,
            CPU,
            MEMORY,
            NAME
        }

        private List<Action> process_actions;
        private double system_start_time = -1;
        private double clock_ticks_per_second = 100.0;
        private uint kthread_pid;
        private SortBy current_sort_by = SortBy.PID;

        private GLib.HashTable<uint, ProcessInfo?> process_info_cache;

        private struct ProcessInfo {
            public ulong last_utime;
            public ulong last_stime;
            public double last_time;
        }

        construct {
            icon_name = "org.gnome.SystemMonitor";
        }

        private const string PROC_FILE_ATTRIBUTES =
            FileAttribute.STANDARD_NAME + "," +
            FileAttribute.STANDARD_TYPE + "," +
            FileAttribute.STANDARD_SORT_ORDER;

        protected override bool activate(Cancellable current_cancellable) {
            process_info_cache = new GLib.HashTable<uint, ProcessInfo?>(direct_hash, direct_equal);
            process_actions = new List<Action>();
            process_actions.append(new TerminateProcessAction());
            process_actions.append(new TerminateProcessAction(true));
            process_actions.append(new KillProcessAction());
            process_actions.append(new KillProcessAction(true));
            process_actions.append(new ContinueProcessAction());
            process_actions.append(new ContinueProcessAction(true));
            init_system_info();
            return true;
        }

        protected override void deactivate() {
            process_actions = null;
            clean_process_cache();
            process_info_cache.remove_all();
        }

        private void init_system_info() {
            if (system_start_time == -1) {
                system_start_time = get_uptime();
            }
            clock_ticks_per_second = get_clock_ticks_per_second();
            kthread_pid = find_kthreadd_pid();
        }

        public override void on_setting_initialized(string key, GLib.Variant value) {
            handle_setting(key, value);
        }


        public override SettingsCallback? on_setting_changed(string key, GLib.Variant value) {
            return handle_setting(key, value);
        }

        private SettingsCallback? handle_setting(string key, GLib.Variant value) {
            if (key == "sort-by") {
                string sort_by = value.get_string();
                SortBy new_sort_by;

                switch (sort_by) {
                    case "cpu":
                        new_sort_by = SortBy.CPU;
                        break;
                    case "memory":
                        new_sort_by = SortBy.MEMORY;
                        break;
                    case "name":
                        new_sort_by = SortBy.NAME;
                        break;
                    case "pid":
                    default:
                        new_sort_by = SortBy.PID;
                        break;
                }
                current_sort_by = new_sort_by;
            }
            return null;
        }

        private Score calculate_score(uint pid_uint, string name, double cpu_usage, uint64 memory_usage) {
            switch (current_sort_by) {
                case SortBy.CPU:
                    return (double)(cpu_usage * 100000); // Higher CPU usage gets higher priority
                case SortBy.MEMORY:
                    return (double)(memory_usage); // Higher memory usage gets higher priority
                case SortBy.NAME:
                    // Alphabetical sorting - lower characters get higher priority
                    uint name_hash = name.hash();
                    return (double)(uint.MAX - name_hash);
                case SortBy.PID:
                default:
                    return (double)(uint.MAX - pid_uint); // Lower PID gets higher priority
            }
        }

        private uint find_kthreadd_pid() {
            try {
                var proc_dir = File.new_for_path("/proc");
                var enumerator = proc_dir.enumerate_children(FileAttribute.STANDARD_NAME, 0);

                FileInfo file_info;
                while ((file_info = enumerator.next_file()) != null) {
                    string name = file_info.get_name();
                    if (uint.parse(name) > 0) {
                        var comm_file = File.new_for_path("/proc/%s/comm".printf(name));
                        uint8[] contents;
                        comm_file.load_contents(null, out contents, null);
                        if (((string)contents).strip() == "kthreadd") {
                            return uint.parse(name);
                        }
                    }
                }
            } catch (Error e) {
                warning("Error finding kthreadd: %s", e.message);
            }
            return 0; // Not found
        }

        private uint get_parent_pid(uint pid) {
            try {
                var stat_file = File.new_for_path("/proc/%d/stat".printf((int)pid));
                uint8[] contents;
                stat_file.load_contents(null, out contents, null);
                string[] parts = ((string)contents).split(" ");
                return uint.parse(parts[3]); // The 4th field is the PPID
            } catch (Error e) {
                return 0;
            }
        }

        private bool is_kernel_thread(uint pid) {
            while (pid >= kthread_pid) {
                if (pid == kthread_pid) {
                    return true;
                }
                pid = get_parent_pid(pid);
            }
            return false;
        }

        private double get_uptime() {
            try {
                var uptime_file = File.new_for_path("/proc/uptime");
                uint8[] contents;
                uptime_file.load_contents(null, out contents, null);
                return double.parse(((string)contents).split(" ")[0]);
            } catch (Error e) {
                warning("Error getting uptime: %s", e.message);
                return 0;
            }
        }

        private double get_clock_ticks_per_second() {
            long clock_ticks = Posix.sysconf(Posix._SC_CLK_TCK);
            if (clock_ticks > 0) {
                return (double)clock_ticks;
            } else {
                return 100.0; // Default to 100 if unable to read
            }
        }

        private void clean_process_cache() {
            var current_pids = new GenericSet<uint>(direct_hash, direct_equal);
            try {
                var proc_dir = GLib.Dir.open("/proc");
                string? name = null;
                while ((name = proc_dir.read_name()) != null) {
                    uint pid;
                    if (uint.try_parse(name, out pid)) {
                        current_pids.add(pid);
                    }
                }
            } catch (Error e) {
                warning("Failed to read /proc: %s", e.message);
            }

            process_info_cache.foreach_remove((pid, _) => (!current_pids.contains(pid)));
        }

        public override void search(ResultContainer rs) {
            try {
                var proc_dir = File.new_for_path("/proc");
                var enumerator = proc_dir.enumerate_children(
                    PROC_FILE_ATTRIBUTES,
                    FileQueryInfoFlags.NONE,
                    null
                );

                string needle = rs.get_query().strip().down();

                FileInfo? file;
                while ((file = enumerator.next_file()) != null) {
                    string name = file.get_name();
                    if (int.parse(name) == 0) {
                        continue;  // Skip non-numeric directories
                    }
                    parse_process_info(rs, name, needle);
                }
            } catch (Error e) {
                clean_process_cache();
                warning(e.message);
            }
        }

        private void parse_process_info(ResultContainer rs, string pid, string needle) {
            uint pid_uint = uint.parse(pid);
            if (is_kernel_thread(pid_uint)) {
                return;
            }

            var status_file = File.new_for_path(@"/proc/$pid/status");
            var cmdline_file = File.new_for_path(@"/proc/$pid/cmdline");
            var stat_file = File.new_for_path(@"/proc/$pid/stat");

            uint8[] status_contents_array = {};
            uint8[] cmdline_contents_array = {};
            uint8[] stat_contents_array = {};
            string? etag_out;

            try {
                bool status_loaded = status_file.load_contents(null, out status_contents_array, out etag_out);
                if (!status_loaded) return;
                bool cmdline_loaded = cmdline_file.load_contents(null, out cmdline_contents_array, out etag_out);
                if (!cmdline_loaded) return;
                bool stat_loaded = stat_file.load_contents(null, out stat_contents_array, out etag_out);
                if (!stat_loaded) return;
            } catch (Error e) {
                return;
            }

            string status_contents = (string)status_contents_array;
            string cmdline_contents = (string)cmdline_contents_array;
            string stat_contents = (string)stat_contents_array;

            string name = "";
            string user = "";
            string state = "";
            uint64 memory_usage = 0;

            foreach (var line in status_contents.split("\n")) {
                if (line.has_prefix("Name:")) {
                    name = line.split(":")[1].strip();
                } else if (line.has_prefix("Uid:")) {
                    var uid = int.parse(line.split(":")[1].strip().split("\t")[0]);
                    user = Posix.getpwuid(uid).pw_name;
                } else if (line.has_prefix("State:")) {
                    state = line.split(":")[1].strip().split(" ")[0];
                } else if (line.has_prefix("VmRSS:")) {
                    memory_usage = uint64.parse(line.split(":")[1].strip().split(" ")[0]) * 1024; // Convert KB to bytes
                }
            }

            string command = cmdline_contents.replace("\0", " ").strip();
            if (command == "") {
                command = name;
            }

            // Parse stat file for CPU usage
            string[] stat_parts = stat_contents.split(" ");
            ulong utime = ulong.parse(stat_parts[13]);
            ulong stime = ulong.parse(stat_parts[14]);

            int64 current_time = GLib.get_monotonic_time();
            double cpu_usage = 0;

            if (process_info_cache.contains(pid_uint)) {
                var info = process_info_cache[pid_uint];
                double time_delta = (current_time - info.last_time) / 1000000.0; // Convert to seconds
                if (time_delta > 0) {
                    ulong cpu_time_delta = (utime + stime) - (info.last_utime + info.last_stime);
                    cpu_usage = 100.0 * (cpu_time_delta / clock_ticks_per_second) / time_delta;
                }
            }

            // Update cache
            process_info_cache[pid_uint] = ProcessInfo() {
                last_utime = utime,
                last_stime = stime,
                last_time = current_time
            };


            if (needle == "" ||
                    pid.has_prefix(needle) || // don't fuzzy match pids
                    rs.has_match(user) ||
                    rs.has_match(name) ||
                    rs.has_match(command)) {

                cpu_usage = Math.round(cpu_usage * 10) / 10;
                Score score = calculate_score(pid_uint, name, cpu_usage, memory_usage);

                rs.add_lazy(pid_uint, score + bonus, () => {
                    string title = @"$pid: $name | ($command)";
                    string description = @"User: $user | State: $state | CPU: %.1f%% | Mem: %s".printf(cpu_usage, format_size(memory_usage));
                    return new ProcessMatch(title, description, pid_uint, name, user, state, cpu_usage, memory_usage, command);
                });
            }
        }

        private string format_size(uint64 size) {
            string[] units = { "B", "KB", "MB", "GB", "TB" };
            int unit = 0;
            double size_d = (double)size;

            while (size_d >= 1024 && unit < units.length - 1) {
                size_d /= 1024;
                unit++;
            }

            return "%.1f %s".printf(size_d, units[unit]);
        }

        public override void find_for_match(Match match, ActionSet rs) {
            foreach (var action in process_actions) {
                rs.add_action(action);
            }
        }
    }
}
