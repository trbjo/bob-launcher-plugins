[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.SnippetsPlugin);
}

namespace BobLauncher {
    public class SnippetsPlugin : SearchBase {
        private CreateSnippet create_snippet;
        private DeleteSnippet delete_action;
        private Snippets.Database db;

        construct {
            icon_name = "text";
            create_snippet = new CreateSnippet(this);
            delete_action = new DeleteSnippet(this);
        }

        public override bool activate() {
            db = new Snippets.Database(this);
            return true;
        }

        public override void deactivate() {
            if (db != null) {
                db.cleanup();
                db = null;
            }
        }

        private class DeleteSnippet : Action {
            private unowned SnippetsPlugin plg;

            public override string get_title() {
                return "Delete Snippet";
            }

            public override string get_description() {
                return "Delete this snippet permanently";
            }

            public override string get_icon_name() {
                return "edit-delete";
            }

            internal DeleteSnippet(SnippetsPlugin _plg) {
                Object();
                plg = _plg;
            }

            public override Score get_relevancy(Match match) {
                if (!(match is SnippetMatch)) {
                    return MatchScore.LOWEST;
                }
                return MatchScore.ABOVE_THRESHOLD;
            }

            public override bool do_execute(Match source, Match? target = null) {
                if (!(source is SnippetMatch) || (target != null)) {
                    return false;
                }

                var snippet = (SnippetMatch)source;
                return plg.delete(snippet.key);
            }
        }

        public static bool is_supported(Match m) {
            return (m is ITextMatch ||
                    (m is IFile && (!((IFile)m).is_directory())) ||
                    m is IURLMatch);
        }


        private class CreateSnippet : ActionTarget {
            private unowned SnippetsPlugin plg;

            public CreateSnippet(SnippetsPlugin _plg) {
                Object();
                plg = _plg;
            }

            public override Match target_match (string query) {
                return new UnknownMatch(query);
            }

            public override string get_title() {
                return "Add this as a snippet";
            }

            public override string get_description() {
                return "Save for quick access later";
            }

            public override string get_icon_name() {
                return "text";
            }

            public override Score get_relevancy(Match m) {
                if (is_supported(m)) {
                    return MatchScore.ABOVE_THRESHOLD;
                }
                return MatchScore.BELOW_THRESHOLD;
            }

            protected override bool do_execute(Match match, Match? target = null) {
                if (target == null) return false;

                var key_match = target as ITextMatch;
                if (key_match == null) return false;
                string key = key_match.get_text();

                // Handle different types of matches
                if (match is IFile) {
                    var file_match = match as IFile;
                    return handle_file_match(file_match, key);
                } else if (match is IURLMatch) {
                    var url_match = match as IURLMatch;
                    return handle_url_match(url_match, key);
                } else if (match is ITextMatch) {
                    var text_match = match as ITextMatch;
                    return handle_text_match(text_match, key);
                }

                return false;
            }

            private bool handle_file_match(IFile file_match, string key) {
                try {
                    var file = file_match.get_file();
                    uint8[] data;

                    file.load_contents(null, out data, null);

                    string mime_type = file_match.get_mime_type();

                    string filename = file.get_basename();

                    return plg.insert(key, data, mime_type, filename);
                } catch (Error e) {
                    warning("Failed to read file for snippet: %s", e.message);
                    return false;
                }
            }

            private bool handle_url_match(IURLMatch url_match, string key) {
                string url = url_match.get_url();
                return plg.insert(key, url.data, "text/uri-list", url);
            }

            private bool handle_text_match(ITextMatch text_match, string key) {
                string text = text_match.get_text();
                return plg.insert(key, text.data, "text/plain");
            }
        }

        public class SnippetText : SnippetMatch, ITextMatch {
            public SnippetText(SnippetsPlugin plg, string key, string preview, string mime_type) {
                base(plg, key, preview, mime_type);
            }

            public string get_text() {
                var snippet = base.plg.db.get_snippet(key);
                if (snippet != null && (base.mime_type.has_prefix("text/") || base.mime_type == "text/uri-list")) {
                    unowned uint8[] data = snippet.data;
                    var builder = new StringBuilder();
                    builder.append_len((string)data, data.length);
                    return builder.str;
                }
                return preview;
            }
        }

        public class SnippetMatch : Match {
            internal string key;
            internal string preview;
            protected string mime_type;
            protected weak SnippetsPlugin plg;

            public SnippetMatch(SnippetsPlugin plg, string key, string preview, string mime_type) {
                Object();
                this.plg = plg;
                this.key = key;
                this.preview = preview;
                this.mime_type = mime_type;
            }

            public override string get_icon_name() {
                if (mime_type.has_prefix("image/")) {
                    return "image";
                } else if (mime_type.has_prefix("text/")) {
                    return "text";
                } else if (mime_type == "text/uri-list") {
                    return "web-browser";
                } else {
                    return "file";
                }
            }

            public override string get_title() {
                return key;
            }

            public override string get_description() {
                return preview;
            }
        }

        internal bool insert(string key, uint8[] data, string mime_type, string? description = null) {
            if (db == null) return false;
            return db.insert_snippet(key, data, mime_type, description);
        }

        internal bool delete(string key) {
            if (db == null) return false;
            return db.delete_snippet(key);
        }

        public void search_empty(ResultContainer rs) {
            int16 base_score = MatchScore.ABOVE_THRESHOLD;
            var all_metadata = db.get_all_metadata();
            all_metadata.foreach((key, metadata) => {
                rs.add_lazy_unique(int16.min(MatchScore.HIGHEST, base_score + (int16)metadata.usage_count), () => {
                    return metadata.mime_type.has_prefix("text") ?
                     new SnippetText(this, key, metadata.preview, metadata.mime_type) :
                     new SnippetMatch(this, key, metadata.preview, metadata.mime_type);
                });
            });
        }

        public override void search(ResultContainer rs) {
            if (db == null) return;

            if (rs.get_query() == "") {
                search_empty(rs);
            } else {
                search_non_empty(rs);
            }
        }

        public void search_non_empty(ResultContainer rs) {
            var all_metadata = db.get_all_metadata();
            all_metadata.foreach((key, metadata) => {
                Score score = rs.match_score(key);
                if (score <= MatchScore.BELOW_THRESHOLD) return;
                rs.add_lazy_unique(score, () => {
                    return metadata.mime_type.has_prefix("text") ?
                     new SnippetText(this, key, metadata.preview, metadata.mime_type) :
                     new SnippetMatch(this, key, metadata.preview, metadata.mime_type);
                });
            });
        }

        public override void find_for_match(Match match, ActionSet rs) {
            if (match is SnippetMatch) {
                rs.add_action(delete_action);
                return;
            }

            if (is_supported(match)) {
                rs.add_action(create_snippet);
            }
        }
    }
}
