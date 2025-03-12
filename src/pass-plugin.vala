/*
 * Copyright (C) 2015 Michael Aquilina <michaelaquilina@gmail.com>

 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
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
 * Authored by Michael Aquilina <michaelaquilina@gmail.com>
 *
 */

[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.PassPlugin);
}


namespace BobLauncher {
    public class PassPlugin : SearchBase {
        construct {
            icon_name = "dialog-password";
        }

        private class PassMatch : Match, IActionMatch {
            public override string get_title() {
                return password_name;
            }

            public override string get_description() {
                return "Copy decrypted PGP password to clipboard";
            }

            public override string get_icon_name() {
                return "dialog-password";
            }

            private string password_name;
            public PassMatch (string password_name) {
                Object();
                this.password_name = password_name;
            }

            public void do_action () {
                Pid child_pid;
                int standard_output;
                int standard_error;

                try {
                    Process.spawn_async_with_pipes (null,
                            {"pass", "-c", this.password_name},
                            null, SpawnFlags.SEARCH_PATH | SpawnFlags.DO_NOT_REAP_CHILD,
                            null, out child_pid,
                            null, out standard_output, out standard_error
                    );
                    ChildWatch.add (child_pid, (pid, status) => {
                        Process.close_pid (pid);

                        try {
                            string message, icon_name;
                            if (status == 0) {
                                message = "Copied %s password to clipboard".printf (this.get_title());
                                icon_name = "dialog-password";
                            } else {
                                message = "Unable to decrypt %s password".printf (this.get_title());
                                icon_name = "dialog-error";
                            }

                            var notification = (Notify.Notification) Object.new (
                                    typeof (Notify.Notification),
                                    summary: "Password Manager",
                                    body: message,
                                    icon_name: icon_name,
                                    null
                            );
                            notification.show ();
                        }
                        catch (Error err) {
                            warning ("%s", err.message);
                        }
                    });
                } catch (SpawnError err) {
                    warning ("%s", err.message);
                }
            }
        }

        private File password_store;
        private List<string> passwords;
        private List<FileMonitor> monitors;

        protected override bool activate(Cancellable current_cancellable) {
            password_store = File.new_for_path (
                "%s/.password-store".printf (Environment.get_home_dir ())
            );
            update_passwords();
            return true;
        }

        protected override void deactivate() {
        }

        private void update_passwords () {
            foreach (unowned FileMonitor monitor in monitors) {
                monitor.cancel ();
            }
            monitors = null;

            try {
                monitors = activate_monitors (password_store);
            } catch (Error err) {
                warning ("Unable to monitor password directory: %s", err.message);
            }
            try {
                passwords = list_passwords (password_store, password_store);
            } catch (Error err) {
                warning ("Unable to list passwords: %s", err.message);
            }
        }

        private List<FileMonitor> activate_monitors (File directory) throws Error {
            List<FileMonitor> result = new List<FileMonitor> ();

            FileEnumerator enumerator = directory.enumerate_children (
                FileAttribute.STANDARD_NAME + "," +
                FileAttribute.STANDARD_TYPE + "," +
                FileAttribute.STANDARD_IS_HIDDEN,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS,
                null
            );

            FileMonitor monitor = directory.monitor_directory (FileMonitorFlags.NONE, null);
            monitor.set_rate_limit (500);
            monitor.changed.connect ((src, dest, event) => {
                message ("Detected a change (%s) in password store. Reloading", event.to_string ());
                update_passwords ();
            });
            result.append (monitor);

            FileInfo? info = null;
            while ((info = enumerator.next_file (null)) != null) {
                if (info.get_is_hidden ()) continue;

                File target_file = directory.get_child (info.get_name ());
                if (info.get_file_type () == FileType.DIRECTORY) {
                    result.concat (activate_monitors (target_file));
                }
            }

            return result;
        }

        private List<string> list_passwords (File root, File directory) throws Error {
            List<string> result = new List<string>();

            FileEnumerator enumerator = directory.enumerate_children (
                FileAttribute.STANDARD_NAME + "," +
                FileAttribute.STANDARD_TYPE + "," +
                FileAttribute.STANDARD_CONTENT_TYPE,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS,
                null
            );

            FileInfo? info = null;
            while ((info = enumerator.next_file (null)) != null) {
                File target_file = directory.get_child (info.get_name ());
                if (info.get_file_type () == FileType.DIRECTORY) {
                    result.concat (list_passwords (root, target_file));
                }
                else if (info.get_content_type () == "application/pgp-encrypted") {
                    var path = root.get_relative_path (target_file);
                    result.prepend (path.replace (".gpg", ""));
                }
            }
            return result;
        }

        public override void search(ResultContainer rs) {
            foreach (unowned string password in passwords) {
                if (rs.has_match(password)) {
                    var score = rs.match_score(password);
                    rs.add_lazy_unique(score + bonus, () => { return new PassMatch(password); });
                }
            }
        }
    }
}
