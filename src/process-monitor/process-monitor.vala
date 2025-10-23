using ProcessUtils;

[ModuleInit]
public Type plugin_init() {
    return typeof(BobLauncher.ProcessMonitorPlugin);
}

namespace BobLauncher {
    public class ProcessMonitorPlugin : SearchBase {
        public override bool prefer_insertion_order { get { return true; } }

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

        private static GLib.HashTable<uint, ProcessInfo?> process_info_cache;

        private struct ProcessInfo {
            public ulong last_utime;
            public ulong last_stime;
            public double last_time;
            public string name;
            public uint pid;
            public string user;
            public string state;
            public double cpu_usage;
            public uint64 memory_usage;
            public string command;
        }

        construct {
            icon_name = "utilities-system-monitor";
        }

        private const string PROC_FILE_ATTRIBUTES =
            FileAttribute.STANDARD_NAME + "," +
            FileAttribute.STANDARD_TYPE + "," +
            FileAttribute.STANDARD_SORT_ORDER;

        public override bool activate() {
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

        public override void deactivate() {
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

        public override void on_setting_changed(string key, GLib.Variant value) {
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
        }

        private CompareFunc<unowned ProcessInfo?> get_compare_function() {
            switch (current_sort_by) {
                case SortBy.CPU:
                    return compare_by_cpu;
                case SortBy.MEMORY:
                    return compare_by_memory;
                case SortBy.NAME:
                    return compare_by_name;
                case SortBy.PID:
                default:
                    return compare_by_pid;
            }
        }

        private static int compare_by_cpu(ProcessInfo? a, ProcessInfo? b) {
            // Higher CPU usage first (descending)
            if (a.cpu_usage > b.cpu_usage) return -1;
            if (a.cpu_usage < b.cpu_usage) return 1;
            return 0;
        }

        private static int compare_by_memory(ProcessInfo? a, ProcessInfo? b) {
            // Higher memory usage first (descending)
            if (a.memory_usage > b.memory_usage) return -1;
            if (a.memory_usage < b.memory_usage) return 1;
            return 0;
        }

        private static int compare_by_name(ProcessInfo? a, ProcessInfo? b) {
            // Alphabetical order (ascending)
            return strcmp(a.name, b.name);
        }

        private static int compare_by_pid(ProcessInfo? a, ProcessInfo? b) {
            // Lower PID first (ascending)
            if (a.pid < b.pid) return 1;
            if (a.pid > b.pid) return -1;
            return 0;
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
                    parse_process_info(name);
                }

                GLib.List<unowned ProcessInfo?> process_list;
                if (needle == "") {
                    process_list = process_info_cache.get_values();
                } else {
                    process_list = new GLib.List<unowned ProcessInfo?>();
                    process_info_cache.foreach((pid, process_info) => {
                        bool is_match = (
                                // pid.has_prefix(needle) || // don't fuzzy match pids
                                rs.has_match(process_info.name) ||
                                rs.has_match(process_info.user) ||
                                rs.has_match(process_info.command));
                        if (is_match) {
                            process_list.append(process_info);
                        }
                    });
                }

                process_list.sort(get_compare_function());

                foreach (var process_info in process_list) {
                    rs.add_lazy_unique(0, () => {
                        return new ProcessMatch(
                            process_info.pid,
                            process_info.name,
                            process_info.user,
                            process_info.state,
                            process_info.cpu_usage,
                            process_info.memory_usage,
                            process_info.command
                        );
                    });
                }

            } catch (Error e) {
                clean_process_cache();
                warning(e.message);
            }
        }

        private void parse_process_info(string pid) {
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

            ProcessInfo? prev_info = null;
            if (process_info_cache.contains(pid_uint)) {
                prev_info = process_info_cache.get(pid_uint);
                double time_delta = (current_time - prev_info.last_time) / 1000000.0; // Convert to seconds
                if (time_delta > 0) {
                    ulong cpu_time_delta = (utime + stime) - (prev_info.last_utime + prev_info.last_stime);
                    cpu_usage = 100.0 * (cpu_time_delta / clock_ticks_per_second) / time_delta;
                }
            }

            cpu_usage = Math.round(cpu_usage * 10) / 10;

            process_info_cache[pid_uint] = ProcessInfo() {
                pid = pid_uint,
                last_utime = utime,
                last_stime = stime,
                last_time = current_time,
                name = name,
                user = user,
                state = state,
                cpu_usage = cpu_usage,
                memory_usage = memory_usage,
                command = command,
            };
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
