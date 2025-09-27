[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.SnippetPlugin);
}

namespace BobLauncher {
    public class SnippetPlugin : SearchBase {
        private CreateSnippet create_snippet;
        private HashTable<string, SnippetResult> snippets;

        construct {
            snippets = new HashTable<string, SnippetResult>(str_hash, str_equal);
            icon_name = "text";
            create_snippet = new CreateSnippet(this);
            message("construct");
        }

        public override bool activate() {
            message("activate");
            return true;
        }

        public SnippetPlugin(GLib.TypeModule module) {
            Object();
        }

        private class CreateSnippet : ActionTarget {
            private unowned SnippetPlugin plg;

            public CreateSnippet(SnippetPlugin _plg) {
                Object();
                plg = _plg;
            }

            public override string get_title() {
                return "Add this as a snippet";
            }

            public override string get_description() {
                return "Add this as a snippet";
            }

            public override string get_icon_name() {
                return "text";
            }

            public override Score get_relevancy(Match m) {
                if (!(m is ITextMatch)) return MatchScore.NONE;
                return MatchScore.ABOVE_THRESHOLD;
            }

            protected override bool do_execute(Match match, Match? target = null) {
                if (target == null) return false; // not possible

                var value_match = match as ITextMatch;
                if (value_match == null) return false;

                var key_match = target as ITextMatch;
                if (key_match == null) return false;

                string val = value_match.get_text();
                string key = key_match.get_text();
                return plg.insert(key, val);
            }

        }

        private class SnippetResult : Match, ITextMatch {
            private string key;
            private string val;

            public SnippetResult(string key, string val) {
                Object();
                this.key = key;
                this.val = val;
            }

            public override string get_icon_name() {
                return "text";
            }

            public string get_text() {
                return val;
            }

            public override string get_title() {
                return val;
            }

            public override string get_description() {
                return key;
            }

            internal Match make_match() {
                return this;
            }
        }

        internal bool insert(string key, string val) {
            snippets.set(key, new SnippetResult(key, val));
            return true;
        }

        public override void search(ResultContainer rs) {
            snippets.foreach((key, snippet) => {
                Score score = rs.match_score(key);
                rs.add_lazy_unique(score, snippet.make_match);
            });
        }

        public override void find_for_match(Match match, ActionSet rs) {
            if (!(match is ITextMatch)) return;
            rs.add_action(create_snippet);
        }
    }
}
