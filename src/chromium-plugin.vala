/*
 * Copyright (C) 2013 Jan Hrdina <jan.hrdka@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program.    If not, see <http://www.gnu.org/licenses/>.
 */

[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.ChromiumPlugin);
}


namespace BobLauncher {

    public class ChromiumPlugin : SearchBase {
        private GenericArray<BookmarkMatch> bookmarks_once;

        construct {
            icon_name = "chromium";
        }

        protected override bool activate(Cancellable current_cancellable) {
            bookmarks_once = new GenericArray<BookmarkMatch>();
            var parser = new Json.Parser();
            string fpath = GLib.Path.build_filename (
                Environment.get_user_config_dir(), "chromium", "Default", "Bookmarks");

            string CONTAINER = "folder";
            GenericSet<string> UNWANTED_SCHEME = new GenericSet<string>(str_hash, str_equal);
            UNWANTED_SCHEME.add ("data");
            UNWANTED_SCHEME.add ("place");
            UNWANTED_SCHEME.add ("javascript");

            List<unowned Json.Node> folders = new List<unowned Json.Node>();

            try {
                File f = File.new_for_path (fpath);
                var input_stream = f.read();
                parser.load_from_stream(input_stream);

                var root_object = parser.get_root().get_object();
                folders.concat (root_object.get_member ("roots").get_object()
                                                                     .get_member ("bookmark_bar").get_object()
                                                                     .get_array_member ("children").get_elements());
                folders.concat (root_object.get_member ("roots").get_object()
                                                                     .get_member ("other").get_object()
                                                                     .get_array_member ("children").get_elements());

                Json.Object o;
                foreach (var item in folders) {
                    o = item.get_object();
                    if (is_bookmark (o) && is_good (o, UNWANTED_SCHEME)) {
                        bookmarks_once.add (new BookmarkMatch(o.get_string_member ("name"), o.get_string_member ("url")));
                    }
                    if (is_container (o, CONTAINER)) {
                        folders.concat(o.get_array_member ("children").get_elements());
                    }
                }
                return true;

            } catch (Error err) {
                warning ("%s", err.message);
                return false;
            }
        }


        protected override void deactivate() {
            bookmarks_once = null;
        }

        private class BookmarkMatch: Match {
            private string? title_folded = null;
            private string? uri_folded = null;
            public string? uri { get; construct; }


            public unowned string get_title_folded() {
                if (title_folded == null) title_folded = get_title().casefold();
                return title_folded;
            }

            public unowned string get_uri_folded() {
                    if (uri_folded == null) uri_folded = uri.casefold();
                return uri_folded;
            }

            private string title;
            public override string get_title() {
                return title;
            }

            public override string get_description() {
                return uri;
            }

            public override string get_icon_name() {
                return "text-html";
            }

            public BookmarkMatch(string name, string uri) {
                Object(uri: uri);
                this.title = name;
            }
        }

        public override void search(ResultContainer rs) {
            var needle = rs.get_query();
            foreach (var bmk in bookmarks_once) {
                unowned string name = bmk.get_title_folded();
                unowned string url = bmk.get_uri_folded();
                if (rs.has_match(name)) {
                    var score = rs.match_score(name);
                    rs.add_lazy(bmk.uri.hash(), score + bonus, () => { return bmk; });
                } else if (rs.has_match(url)) {
                    var score = rs.match_score(url);
                    rs.add_lazy(bmk.uri.hash(), score + bonus, () => { return bmk; });
                }
            }
        }


        /* Bookmarks parsing methods */
        private static bool is_container(Json.Object o, string container_string) {
            return o.get_string_member ("type") == container_string;
        }

        private static bool is_bookmark(Json.Object o) {
            return o.has_member("url");
        }

        private static bool is_good(Json.Object o, GenericSet<string> unwanted_scheme) {
            return !unwanted_scheme.contains (o.get_string_member ("url").split (":", 1)[0]);
        }
    }
}
