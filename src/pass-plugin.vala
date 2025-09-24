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
            passwords = new GenericArray<string>();
            monitors = new GenericArray<FileMonitor>();
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

            public bool do_action () {
                string identifier = "pass";
                string[] argv = {"pass", "-c", this.password_name};
                bool success = BobLaunchContext.get_instance().launch_command(identifier, argv, true, false);
                try {
                    string message, icon_name;
                    if (success) {
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
                    notification.show();
                } catch (Error err) {
                    warning ("%s", err.message);
                }
                return success;
            }
        }

        private File password_store;
        private GenericArray<string> passwords;
        private GenericArray<FileMonitor> monitors;

        public override bool activate() {
            password_store = File.new_for_path (
                "%s/.password-store".printf (Environment.get_home_dir ())
            );
            update_passwords();
            return true;
        }

        public override void deactivate() { }

        private void update_passwords () {
            foreach (unowned FileMonitor monitor in monitors) {
                monitor.cancel();
            }
            monitors = null;

            try {
                monitors = activate_monitors(password_store);
            } catch (Error err) {
                warning ("Unable to monitor password directory: %s", err.message);
            }
            try {
                passwords = list_passwords(password_store, password_store);
                passwords.sort(strcmp);
            } catch (Error err) {
                warning ("Unable to list passwords: %s", err.message);
            }
        }

        private GenericArray<FileMonitor> activate_monitors(File directory) throws Error {
            GenericArray<FileMonitor> result = new GenericArray<FileMonitor> ();

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
            result.add(monitor);

            FileInfo? info = null;
            while ((info = enumerator.next_file (null)) != null) {
                if (info.get_is_hidden ()) continue;

                File target_file = directory.get_child (info.get_name ());
                if (info.get_file_type () == FileType.DIRECTORY) {
                    result.extend_and_steal(activate_monitors(target_file));
                }
            }

            return result;
        }

        private GenericArray<string> list_passwords (File root, File directory) throws Error {
            GenericArray<string> result = new GenericArray<string>();

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
                    result.extend_and_steal(list_passwords (root, target_file));
                }
                else if (info.get_content_type () == "application/pgp-encrypted") {
                    var path = root.get_relative_path (target_file);
                    result.insert (0, path.replace (".gpg", ""));
                }
            }
            return result;
        }

        public override void search(ResultContainer rs) {
            foreach (unowned string password in passwords) {
                if (rs.has_match(password)) {
                    var score = rs.match_score(password);
                    rs.add_lazy_unique(score, () => { return new PassMatch(password); });
                }
            }
        }
    }
}
