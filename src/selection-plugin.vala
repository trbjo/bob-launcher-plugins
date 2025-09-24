[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.SelectionPlugin);
}


namespace BobLauncher {
    public class SelectionPlugin : PluginBase {
        private override string lol_icon_name { get; default = "edit-copy"; }


        private unowned Gdk.Clipboard clipboard;
        private string? selection;

        public override void activate() {
            clipboard = Gdk.Display.get_default().get_primary_clipboard();
            clipboard.changed.connect(this.on_clipboard_changed);
        }

        internal override void deactivate() {
            clipboard.changed.disconnect(this.on_clipboard_changed);
            clipboard = null;
        }

        private void on_clipboard_changed() {
            clipboard.read_text_async.begin(null, (obj, res) => {
                try {
                    string? text = clipboard.read_text_async.end(res);
                    if (text != null) {
                        selection = text;
                    }
                } catch (Error e) {
                    // ignore
                }
            });
        }

        private class SelectionClipboardItem : Match {
            public string text { get; private set; }

            public SelectionClipboardItem(owned string text) {
                Object(
                    title: "Selected text",
                    description: generate_description(text),
                    capability: MatchCapability.TEXT,
                    icon_name: "edit-paste",
                    mime_type: "text/plain"
                );
                this.text = text;
            }

            private static string generate_description(string text) {
                string chugged = text.chug();
                if (chugged.char_count() > 100) {
                    return chugged.substring(0, chugged.index_of_nth_char(100)).replace("\n", "↵");
                } else {
                    return chugged.replace("\n", "↵");
                }
            }
        }

        public override async void search(ResultContainer rs) {

            unowned string needle = rs.get_query();
            if (selection == null) {
                return;
            }

            if (rs.has_match(selection)) {
                rs.add(new SelectionClipboardItem(selection), rs.match_score(selection));
            }
        }
    }
}
