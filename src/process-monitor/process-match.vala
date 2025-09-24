using ProcessUtils;

namespace BobLauncher {
    public class ProcessMatch : Match, IRichDescription {
        public uint pid { get; construct; }
        public string name { get; construct; }
        public string user { get; construct; }
        public ProcessState state { get; construct; }
        public double cpu_usage { get; construct; }
        public uint64 memory_usage { get; construct; }
        public string command { get; construct; }

        private Description? _cached_description = null;

        public override string get_title() {
            return @"$pid: $name | ($command)";
        }

        public override string get_description() {
            assert_not_reached();
        }

        public override string get_icon_name() {
            return "application-x-executable";
        }

        public string get_mime_type() {
            return "text/plain";
        }

        public unowned Description get_rich_description(Levensteihn.StringInfo si) {
            if (_cached_description == null) {
                _cached_description = build_rich_description();
            }
            return _cached_description;
        }

        private Description build_rich_description() {
            var root = new Description.container("process-description");


            var state_container = new Description.container("state-container", Gtk.Orientation.HORIZONTAL);
            state_container.add_child(new Description("emblem-system-symbolic", "state-icon", FragmentType.IMAGE));
            state_container.add_child(new Description(state.to_string(), get_state_css_class()));
            root.add_child(state_container);

            var cpu_container = new Description.container("cpu-container", Gtk.Orientation.HORIZONTAL);
            cpu_container.add_child(new Description("computer-symbolic", "cpu-icon", FragmentType.IMAGE));
            cpu_container.add_child(new Description("%.1f%%".printf(cpu_usage), "cpu-text"));
            root.add_child(cpu_container);

            var memory_container = new Description.container("memory-container", Gtk.Orientation.HORIZONTAL);
            memory_container.add_child(new Description("drive-harddisk-system-symbolic", "memory-icon", FragmentType.IMAGE));
            memory_container.add_child(new Description(format_size(memory_usage), "memory-text"));
            root.add_child(memory_container);

            var user_container = new Description.container("user-container", Gtk.Orientation.HORIZONTAL);
            user_container.add_child(new Description("avatar-default-symbolic", "user-icon", FragmentType.IMAGE));
            user_container.add_child(new Description(user, "user-text"));
            root.add_child(user_container);

            return root;
        }

        private string get_state_css_class() {
            switch (state) {
                case ProcessState.RUNNING:
                    return "state-running";
                case ProcessState.SLEEPING:
                    return "state-sleeping";
                case ProcessState.STOPPED:
                    return "state-stopped";
                case ProcessState.ZOMBIE:
                    return "state-zombie";
                default:
                    return "state-unknown";
            }
        }

        public ProcessMatch(
            uint pid,
            string name,
            string user,
            string state,
            double cpu_usage,
            uint64 memory_usage,
            string command
        ) {
            Object(
                pid: pid,
                name: name,
                user: user,
                state: ProcessState.from_string(state),
                cpu_usage: cpu_usage,
                memory_usage: memory_usage,
                command: command
            );
        }
    }

    public class ProcessSignalAction: Action {
        private int signal;
        private bool group_signal;

        private string title;
        private string description;
        private string icon_name;


        public override string get_title() {
            return title;
        }

        public override string get_description() {
            return description;
        }

        public override string get_icon_name() {
            return icon_name;
        }


        public ProcessSignalAction(string title, string description, string icon_name, int signal, bool group_signal = false) {
            Object();
            this.signal = signal;
            this.title = title;
            this.description = description;
            this.icon_name = icon_name;
            this.group_signal = group_signal;
        }

        public override Score get_relevancy(Match match) {
            if (match is ProcessMatch) {
                return MatchScore.VERY_GOOD;
            }
            return MatchScore.LOWEST;
        }

        public override bool do_execute(Match source, Match? target = null) {
            if (!(source is ProcessMatch)) {
                return false;
            }
            ProcessMatch process_match = (ProcessMatch)source;
            Posix.pid_t pid = (Posix.pid_t)process_match.pid;

            if (group_signal) {
                Posix.pid_t pgid = Posix.getpgid(pid);
                // start the process first if stopped
                if (process_match.state == ProcessState.STOPPED && signal == Posix.Signal.TERM || signal == Posix.Signal.INT) {
                    Posix.killpg(pgid, Posix.Signal.CONT);
                }
                Posix.killpg(pgid, signal);
            } else {
                // start the process first if stopped
                if (process_match.state == ProcessState.STOPPED && signal == Posix.Signal.TERM || signal == Posix.Signal.INT) {
                    Posix.kill(pid, Posix.Signal.CONT);
                }
                Posix.kill(pid, signal);
            }

            debug("Signal %d sent to %s%d", signal, group_signal ? "process group " : "", pid);
            return true;
        }


        protected bool can_signal_process(ProcessMatch process) {
            try {
                // Get the current user's UID and GID
                uid_t current_uid = Posix.getuid();
                gid_t current_gid = Posix.getgid();

                // Read the process's UID and GID
                var status_file = File.new_for_path("/proc/%u/status".printf(process.pid));
                uint8[] contents;
                status_file.load_contents(null, out contents, null);
                string status_content = (string) contents;

                string[] lines = status_content.split("\n");
                uint process_uid = 0;
                uint process_gid = 0;

                foreach (string line in lines) {
                    if (line.has_prefix("Uid:")) {
                        string[] parts = line.split("\t");
                        if (parts.length > 1) process_uid = uint.parse(parts[1]);
                    }
                    if (line.has_prefix("Gid:")) {
                        string[] parts = line.split("\t");
                        if (parts.length > 1) process_gid = uint.parse(parts[1]);
                    }
                }

                if (current_uid == 0) return true;

                if (current_uid == process_uid) return true;

                if (current_gid == process_gid) return true;

                return is_group_member((gid_t)process_gid);

            } catch (Error e) {
                warning("Error checking process permissions: %s", e.message);
                return false;
            }
        }
    }

    public class TerminateProcessAction : ProcessSignalAction {
        public new bool valid_for_match(Match match) {
            if (!(match is ProcessMatch)) return false;
            var process_match = (ProcessMatch)match;
            return can_signal_process(process_match) &&
                   process_match.state != ProcessState.ZOMBIE &&
                   process_match.state != ProcessState.DEAD;
        }

        public TerminateProcessAction(bool group_signal = false) {
            base(
                group_signal ? "Terminate Process Group" : "Terminate Process",
                group_signal ? "Send SIGTERM to the process group" : "Send SIGTERM to the process",
                "process-stop",
                Posix.Signal.TERM,
                group_signal
            );
        }
    }

    public class KillProcessAction : ProcessSignalAction {
        public new bool valid_for_match(Match match) {
            if (!(match is ProcessMatch)) return false;
            var process_match = (ProcessMatch)match;
            return can_signal_process(process_match) &&
                   process_match.state != ProcessState.ZOMBIE &&
                   process_match.state != ProcessState.DEAD;
        }

        public KillProcessAction(bool group_signal = false) {
            base(
                group_signal ? "Kill Process Group" : "Kill Process",
                group_signal ? "Send SIGKILL to the process group" : "Send SIGKILL to the process",
                "process-stop",
                Posix.Signal.KILL,
                group_signal
            );
        }
    }

    public class ContinueProcessAction : ProcessSignalAction {
        public new bool valid_for_match(Match match) {
            if (!(match is ProcessMatch)) return false;
            var process_match = (ProcessMatch)match;
            return can_signal_process(process_match);
        }

        public ContinueProcessAction(bool group_signal = false) {
            base(
                group_signal ? "Continue Process Group" : "Continue Process",
                group_signal ? "Send SIGCONT to the process group" : "Send SIGCONT to the process",
                "media-playback-start",
                Posix.Signal.CONT,
                group_signal
            );
        }
    }
}
