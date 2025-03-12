[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.DesktopFilePlugin);
}


namespace BobLauncher {
    public class DesktopFilePlugin : SearchAction {
        private class DesktopFileMatch : Match, IDesktopApplication {
            public override string get_icon_name() {
                return icon_name;
            }

            public override string get_title() {
                return name;
            }

            public override string get_description() {
                return comment;
            }

            internal DesktopFileMatch func() {
                return this;
            }

            private string? icon_name;
            private string? name;
            private string? comment;

            private GenericArray<OpenAppAction> oa_list;

            public unowned GenericArray<Action> get_actions() {
                string[] actions = desktop_info.actions;
                if (oa_list == null) {
                    oa_list = new GenericArray<OpenAppAction>();
                    foreach (string action in actions) {
                        oa_list.add(new OpenAppAction(app_info, action));
                    }
                }
                return oa_list;
            }


            public DesktopFileInfo desktop_info;
            private DesktopAppInfo app_info;
            public string desktop_id;
            public string exec;

            public DesktopFileMatch(DesktopFileInfo info) {
                this.icon_name = info.icon_name;
                this.name = info.name;
                this.comment = info.comment;
                this.desktop_info = info;
                this.app_info = info.app_info;
                this.exec = info.exec;
                this.desktop_id = "application://" + info.file_base_name;
            }

            public unowned DesktopAppInfo get_desktop_appinfo() {
                return this.app_info;
            }

            public bool needs_terminal() {
                return desktop_info.needs_terminal;
            }
        }

        private class MimeTypeChange: ActionTarget {

            private string handled_mime_type;
            public unowned DesktopFileService dfs { get; construct; }

            public override string get_title() {
                return "Set Mime Type for %s".printf(this.handled_mime_type);
            }

            public override string get_icon_name() {
                return "document-properties";
            }

            public override string get_description() {
                return "Change the default app to open files of the type '%s' with".printf(this.handled_mime_type);
            }


            public MimeTypeChange(DesktopFileService dfs) {
                Object (dfs: dfs);
            }

            public void update_mime_type(string mime_type) {
                this.handled_mime_type = mime_type;
            }

            protected override bool do_execute(Match match, Match? target = null) {
                if (!(match is FileMatch) || target == null || !(target is IDesktopApplication)) {
                    return false;
                }

                try {
                    var ifile = (FileMatch)match;
                    var da = (IDesktopApplication)target;
                    string mime_type = ifile.get_mime_type();
                    dfs.set_default_handler_for_mime_type(da.get_desktop_appinfo().get_id(), mime_type);
                    return true;
                } catch (Error err) {
                    warning("%s", err.message);
                    return true;
                }
            }

            public override Score get_relevancy(Match match) {
                if (match is FileMatch) {
                    return MatchScore.ABOVE_THRESHOLD;
                }
                return MatchScore.BELOW_THRESHOLD;
            }
        }

        private class OpenWithAction: Action {
            public DesktopFileInfo desktop_info { get; construct; }

            public override string get_icon_name() {
                return desktop_info.icon_name;
            }

            public override string get_title() {
                return "Open with %s".printf(desktop_info.name);
            }

            public override string get_description() {
                return "Opens current selection using %s".printf(desktop_info.name);
            }

            public override Score get_relevancy(Match match) {
                if (match is FileMatch) {
                    return MatchScore.VERY_GOOD;
                }
                return MatchScore.BELOW_THRESHOLD;
            }

            public OpenWithAction (DesktopFileInfo info) {
                Object (desktop_info : info);
            }

            protected override bool do_execute(Match match, Match? target = null) {
                if (!(match is FileMatch)) {
                    return false;
                }

                try {
                    var muri = (FileMatch)match;
                    List<string> uris = new List<string>();
                    uris.append(muri.get_uri());
                    desktop_info.app_info.launch_uris(uris, Gdk.Display.get_default().get_app_launch_context());
                } catch (Error err) {
                    warning ("%s", err.message);
                }
                return true;
            }
        }

        private class OpenAppAction: Action {
            public DesktopAppInfo desktop_info { get; construct; }
            public string action { get; construct; }
            public string icon_name { get; construct; }

            public override string get_icon_name() {
                return icon_name;
            }

            private string? title = null;
            public override string get_title() {
                if (title == null) {
                    title = desktop_info.get_name();
                }
                return title;
            }

            private string _description;

            public override string get_description() {
                return _description;
            }

            public override Score get_relevancy(Match match) {
                if (match is DesktopFileMatch) {
                    return MatchScore.VERY_GOOD;
                }
                return MatchScore.LOWEST;
            }

            public OpenAppAction(DesktopAppInfo info, string action) {
                var icon = info.get_icon() ?? new ThemedIcon ("application-default-icon");
                Object (
                    desktop_info: info,
                    action: action,
                    icon_name: icon.to_string()
                );
                string action_name = info.get_action_name(action);
                this._description = "Launch action '%s'".printf(action_name);
            }

            protected override bool do_execute(Match match, Match? target = null) {
                    desktop_info.launch_action(action, Gdk.Display.get_default().get_app_launch_context());
                    return true;
            }
        }



        private GenericArray<DesktopFileMatch> desktop_files;
        private GLib.HashTable<string, GenericArray<OpenWithAction>> mimetype_map;
        private DesktopFileService dfs;
        private MimeTypeChange mtc;

        construct {
            icon_name = "application-x-executable";
            dfs = new DesktopFileService();
            mtc = new MimeTypeChange(dfs);

            load_empty_maps();

            dfs.reload_started.connect(load_empty_maps);
            dfs.reload_done.connect(load_desktop_files_and_mimes);
        }

        protected override void deactivate() {
            load_empty_maps();
        }

        private void load_empty_maps() {
            desktop_files = new GenericArray<DesktopFileMatch>();
            mimetype_map = new GLib.HashTable<string, GenericArray<OpenWithAction>>(str_hash, str_equal);
        }

        protected override bool activate(Cancellable current_cancellable) {
            load_desktop_files_and_mimes();
            return true;
        }

        private void load_desktop_files_and_mimes() {
            dfs.desktop_files.foreach((k, dfi) => desktop_files.add(new DesktopFileMatch(dfi)));
            dfs.mimetype_map.foreach((mime_type, dfi_lst) => {
                var ow_list = new GenericArray<OpenWithAction>();
                foreach (unowned var dfi in dfi_lst) {
                    ow_list.add(new OpenWithAction(dfi));
                }
                mimetype_map[mime_type] = ow_list;
            });
        }

        public override void search(ResultContainer rs) {
            unowned string needle = rs.get_query();
            bool query_empty = needle.char_count() == 0;
            foreach (var dfm in desktop_files) {
                string desc = dfm.get_description();
                string title = dfm.get_title();

                Score score = 0.0;
                if (query_empty) {
                    score = MatchScore.ABOVE_THRESHOLD;
                } else if (rs.has_match(title)) {
                    score = rs.match_score(title);
                } else if (rs.has_match(desc)) {
                    score = rs.match_score(desc);
                } else if (dfm.exec.has_prefix(needle) && rs.has_match(dfm.exec)) {
                    score = rs.match_score(dfm.exec);
                } else {
                    continue;
                }

                if (score < MatchScore.EXCELLENT && dfm.desktop_info.is_hidden) {
                    continue;
                }

                rs.add_lazy_unique(score + bonus, dfm.func);
            }
        }

        public override void find_for_match(Match match, ActionSet rs) {
            if (match is IFile) {
                string mime_type = ((IFile)match).get_mime_type();
                var mimes = mimetype_map.get(mime_type);
                if (mimes != null) {
                    foreach (var action in mimes) {
                        rs.add_action(action);
                    }
                }

                mtc.update_mime_type(mime_type);
                rs.add_action(mtc);
            } else if (match is IDesktopApplication) {
                var dmatch = (IDesktopApplication)match;
                foreach (var action in dmatch.get_actions()) {
                    rs.add_action(action);
                }
            }
        }
    }
}
