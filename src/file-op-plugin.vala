[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.FileOperationsPlugin);
}


namespace BobLauncher {
    public class FileOperationsPlugin : PluginBase {
        private GenericArray<Action> actions;


        construct {
            icon_name = "edit-copy";
            actions = new GenericArray<Action>();

            actions.add(new Remove());
            actions.add(new RenameTo());
        }

        private class Remove: Action {
            public override string get_title() {
                return "Remove";
            }

            public override string get_description() {
                return "Move to Trash";
            }
            public override string get_icon_name() {
                return "user-trash";
            }

            public override Score get_relevancy(Match m) {
                if (m is IFile) {
                    return MatchScore.THRESHOLD;
                }
                return MatchScore.LOWEST;
            }

            public override bool do_execute(Match source, Match? target = null) {
                unowned IFile uri_match = source as IFile;
                if (uri_match == null) return false;

                var f = ((IFile)uri_match).get_file();
                try {
                     f.trash();
                    return true;
                } catch (Error err) {
                    warning ("%s", err.message);
                }
                return false;
            }
        }

        private class RenameTo: ActionTarget {
            public override string get_title() {
                return "Rename to";
            }

            public override string get_description() {
                return "Rename the file to...";
            }
            public override string get_icon_name() {
                return "tag";
            }

            public override Score get_relevancy(Match match) {
                if (match is FileMatch) {
                    return MatchScore.BELOW_AVERAGE;
                }
                return MatchScore.LOWEST;
            }

            public override bool do_execute(Match source, Match? target = null) {
                if (target == null) return false; // not possible

                unowned FileMatch? uri_match = source as FileMatch;
                if (uri_match == null) return false; // not possible

                File f = ((IFile)uri_match).get_file();
                if (!f.query_exists()) {
                    warning ("File \"%s\"does not exist.", uri_match.get_title());
                    return false;
                }
                string newpath = Path.build_filename (Path.get_dirname (f.get_path()), target.get_title());
                var f2 = File.new_for_path(newpath);
                debug("Moving \"%s\" to \"%s\"", f.get_path(), newpath);
                bool done = false;
                try {
                    done = f.move(f2, GLib.FileCopyFlags.OVERWRITE);
                    return true;
                } catch (GLib.Error err) {}
                if (!done) {
                    warning ("Cannot move \"%s\" to \"%s\"", f.get_path(), newpath);
                }
                return false;
            }
        }

        public override void find_for_match(Match match, ActionSet rs) {
            foreach (var action in actions) {
                rs.add_action(action);
            }
        }
    }
}
