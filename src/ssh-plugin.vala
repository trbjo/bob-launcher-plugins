/*
 * Copyright (C) 2011 Antono Vasiljev <self@antono.info>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.    See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301    USA.
 *
 * Authored by Antono Vasiljev <self@antono.info>
 *
 */

[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.SshPlugin);
}


namespace BobLauncher {
    public class SshPlugin : SearchBase {
        construct {
            icon_name = "utilities-terminal";
        }

        private GLib.HashTable<string, SshHost> hosts;

        protected File config_file;
        protected FileMonitor monitor;

        public override bool activate() {
            hosts = new GLib.HashTable<string, SshHost>(str_hash, str_equal);
            this.config_file = File.new_for_path (Environment.get_home_dir () + "/.ssh/config");

            parse_ssh_config.begin();

            try {
                this.monitor = config_file.monitor_file (FileMonitorFlags.NONE);
                this.monitor.changed.connect(this.handle_ssh_config_update);
                return true;
            }
            catch (IOError e) {
                warning ("Failed to start monitoring changes of ssh client config file");
                return false;
            }
        }

        public override void deactivate() {
                this.monitor.changed.disconnect(this.handle_ssh_config_update);
        }

        private async void parse_ssh_config () {
            hosts.remove_all();

            try {
                var dis = new DataInputStream (config_file.read ());

                Regex host_key_re = new Regex ("^\\s*(?:Match\\s+host|Host)\\s+(\\S+(?:\\s+\\S+)*?)(?:\\s+exec|\\s+HostName|\\s+User|\\s*$)", RegexCompileFlags.OPTIMIZE | RegexCompileFlags.CASELESS);
                Regex comment_re = new Regex ("^\\s#.*$", RegexCompileFlags.OPTIMIZE);

                string line = "";

                while ((line = yield dis.read_line_async (Priority.DEFAULT)) != null) {
                    /* Delete comments */
                    line = comment_re.replace (line, -1, 0, "");
                    if (host_key_re.match (line)) {
                        MatchInfo match_info;
                        host_key_re.match (line, 0, out match_info);
                        string hosts_str = match_info.fetch (1);
                        /* split to find multiple host definitions */
                        foreach (var host in hosts_str.split (" ")) {
                            string host_stripped = host.strip ();
                            if (host_stripped != "" && host_stripped.index_of ("*") == -1 && host_stripped.index_of ("?") == -1) {
                                debug("host added: %s", host_stripped);
                                hosts.set(host_stripped, new SshHost(host_stripped));
                            }
                        }
                    }
                }
            }
            catch (Error e) {
                warning ("%s: %s", config_file.get_path (), e.message);
            }
        }

        public void handle_ssh_config_update (FileMonitor monitor,
                                                                                    File file,
                                                                                    File? other_file,
                                                                                    FileMonitorEvent event_type) {
            if (event_type == FileMonitorEvent.CHANGES_DONE_HINT) {
                message ("ssh_config is changed, reparsing");
                parse_ssh_config.begin ();
            }
        }

        public override void search(ResultContainer rs) {
            hosts.foreach((_, host) => {
                rs.add_lazy_unique(rs.match_score(host.host_query), host.func);
            });
        }

        private class SshHost : Match, IActionMatch {
            public string host_query { get; construct set; }

            internal SshHost func() {
                return this;
            }

            public bool do_action () {
                string ssh = "ssh %s".printf(host_query);
                string? executable = Environment.find_program_in_path ("ssh");
                if (executable == null) {
                    warning ("could not find ssh in path");
                    return false;
                }

                string[] argv = {executable, host_query};
                return BobLaunchContext.get_instance().launch_command(ssh, argv, false, true);
            }
            public override string get_title() {
                return "SSH: " + host_query;
            }
            public override string get_description() {
                return "Connect with SSH";
            }
            public override string get_icon_name() {
                return "utilities-terminal";
            }


            public SshHost (string host_name) {
                Object (host_query: host_name);
            }
        }
    }
}
