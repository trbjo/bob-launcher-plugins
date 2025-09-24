[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.CommonActions);
}

namespace BobLauncher {

    public class CommonActions : PluginBase {
        private GenericArray<Action> actions;

        construct {
            icon_name = "system-run";
        }

        public override bool activate() {
            actions = new GenericArray<Action>();

            actions.add(new Runner());
            actions.add(new TerminalRunner());
            actions.add(new Opener());
            actions.add(new OpenFolder());
            actions.add(new TerminalOpenFolder());
            actions.add(new ClipboardCopy());
            return true;
        }

        public override void deactivate() {
            actions = new GenericArray<Action>();
        }

        private class Runner: Action {
            private Cancellable cancellable;

            construct {
                cancellable = new Cancellable();
            }

            public override string get_title() {
                return "Run";
            }

            public override string get_description() {
                return "Run an application, action or script";
            }

            public override string get_icon_name() {
                return "system-run";
            }

            public override Score get_relevancy(Match match) {
                if (match is Action || match is IActionMatch || match is IDesktopApplication) {
                    return MatchScore.HIGHEST;
                }
                if (match is IFile) {
                    string file_path = ((IFile)match).get_file_path();
                    bool can_open = (FileUtils.test (file_path, FileTest.IS_EXECUTABLE) && !FileUtils.test (file_path, FileTest.IS_DIR));
                    if (can_open) {
                        return MatchScore.HIGHEST;
                    }
                }
                return MatchScore.LOWEST;
            }


            protected override bool do_execute(Match match, Match? target = null) {
                if (match is IActionMatch) {
                    return ((IActionMatch)match).do_action();
                } else if (match is IDesktopApplication) {
                    unowned IDesktopApplication app_match = (IDesktopApplication) match;
                    return BobLaunchContext.get_instance().launch_app(app_match.get_desktop_appinfo());
                } else if (match is IFile) {
                    return BobLaunchContext.get_instance().launch_file(((IFile)match).get_file());
                }
                warning ("'%s' is not be handled here", match.get_title());
                return false;
            }
        }

        private class TerminalRunner: Action {
            public override string get_title() {
                return "Run in Terminal";
            }

            public override string get_description() {
                return "Run application or command in terminal";
            }

            public override string get_icon_name() {
                return "utilities-terminal";
            }


            protected override bool do_execute(Match match, Match? target = null) {
                try {
                    if (match is IDesktopApplication) {
                        unowned IDesktopApplication app_match = (IDesktopApplication) match;
                        return BobLaunchContext.get_instance().launch_app(app_match.get_desktop_appinfo(), true, null);
                    } else {
                        return false;
                    }
                } catch (Error err) {
                    warning ("%s", err.message);
                    return false;
                }
            }

            public override Score get_relevancy(Match match) {
                if (match is IDesktopApplication) {
                    return MatchScore.BELOW_AVERAGE;
                }
                if (match is IFile) {
                    string file_path = ((IFile)match).get_file_path();
                    bool can_open = (FileUtils.test (file_path, FileTest.IS_EXECUTABLE) && !FileUtils.test (file_path, FileTest.IS_DIR));
                    if (can_open) {
                        return MatchScore.BELOW_AVERAGE;
                    }
                }
                return MatchScore.LOWEST;
            }
        }

        private class Opener: Action {
            public override string get_title() {
                return "Open";
            }

            public override string get_description() {
                return "Run an application, action or script";
            }

            public override string get_icon_name() {
                return "application-default-icon";
            }

            protected override bool do_execute(Match match, Match? target = null) {
                if (match is IFile) {
                    var file = ((IFile)match).get_file();
                    BobLaunchContext.get_instance().launch_file(file);
                    return true;
                } else if (match is IURLMatch) {
                    BobLaunchContext.get_instance().launch_uri(match.get_url());
                    return true;
                }
                return false;
            }

            public override Score get_relevancy(Match match) {
                if (match is IFile) {
                    return MatchScore.EXCELLENT;
                }
                if (match is IURLMatch) {
                    return MatchScore.EXCELLENT;
                }
                bool can_open = (match is UnknownMatch && (web_uri.match (match.get_title()) || file_path.match (match.get_title())));
                if (can_open) {
                    return MatchScore.EXCELLENT;
                }
                return MatchScore.LOWEST;
            }

            private Regex web_uri;
            private Regex file_path;

            construct {
                try {
                    web_uri = new Regex ("^(ftp|http(s)?)://[^.]+\\.[^.]+", RegexCompileFlags.OPTIMIZE);
                    file_path = new Regex ("^(/|~/)[^/]+", RegexCompileFlags.OPTIMIZE);
                } catch (Error err) {
                    warning ("%s", err.message);
                }
            }
        }

        private class OpenFolder: Action {

            public override string get_icon_name() {
                return "folder-open";
            }

            public override string get_title() {
                return "Open folder";
            }

            public override string get_description() {
                return "Open folder containing this file";
            }


            protected override bool do_execute(Match match, Match? target = null) {
                if (!(match is IFile)) {
                    return false;
                }

                try {
                    var file = ((IFile)match).get_file();
                    var parent = file.get_parent();

                    if (parent != null) {
                        AppInfo.launch_default_for_uri(parent.get_uri(), null);
                        return true;
                    }
                } catch (Error err) {
                    warning("Failed to open folder: %s", err.message);
                }
                return false;
            }

            public override Score get_relevancy(Match match) {
                if (!(match is IFile)) {
                    return MatchScore.LOWEST;
                }
                var f = ((IFile)match).get_file();
                var parent = f.get_parent();
                bool can_open = parent != null && f.is_native();
                if (can_open) {
                    return MatchScore.AVERAGE;
                }
                return MatchScore.LOWEST;
            }
        }

        private class TerminalOpenFolder: Action {
            public override string get_title() {
                return "Open Terminal here";
            }

            public override string get_description() {
                return "Open directory in the terminal";
            }

            public override string get_icon_name() {
                return "utilities-terminal";
            }

            protected override bool do_execute(Match match, Match? target = null) {
                if (!(match is IFile)) {
                    return false;
                }

                File file = ((IFile)match).get_file();
                string shell = Environment.get_variable ("SHELL");
                if (GLib.FileUtils.test(file.get_path(), GLib.FileTest.IS_DIR)) {
                    Utils.open_command_line(shell, null, true, file.get_path());
                } else {
                    Utils.open_command_line(shell, null, true, file.get_parent().get_path());
                }
                return true;
            }

            public override Score get_relevancy(Match match) {
                if (!(match is IFile)) {
                    return MatchScore.LOWEST;
                }
                File file = ((IFile)match).get_file();
                var parent = file.get_parent();
                if (parent != null && file.is_native()) {
                    return MatchScore.AVERAGE;
                }
                return MatchScore.LOWEST;
            }
        }

        private class ClipboardCopy: Action {
            public override string get_title() {
                return "Copy to Clipboard";
            }

            public override string get_description() {
                return "Copy selection to clipboard";
            }

            public override string get_icon_name() {
                return "insert-link";
            }

            protected override bool do_execute(Match match, Match? target = null) {
                unowned Gdk.Clipboard cb = Gdk.Display.get_default().get_clipboard();
                if (match is ITextMatch) {
                    string content = match.get_text();
                    cb.set_text(content);
                } else if (match is IFile) {
                    string content = ((IFile)match).get_uri();
                    cb.set_text(content);
                }
                return true;
            }

            public override Score get_relevancy(Match match) {
                if (match is IFile) {
                    return MatchScore.GOOD;
                }
                if (match is ITextMatch) {
                    return MatchScore.GOOD;
                }
                return MatchScore.LOWEST;
            }
        }

        public override void find_for_match(Match match, ActionSet rs) {
            foreach (var action in actions) {
                rs.add_action(action);
            }
        }
    }
}
