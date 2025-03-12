/*
 * Copyright (C) 2014 Rico Tzschichholz <ricotz@ubuntu.com>
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
    return typeof(BobLauncher.GnomeBookmarksPlugin);
}


namespace BobLauncher {
    public class GnomeBookmarksPlugin : SearchBase {
        const string PREFIX = "file://";
        public static string uri_to_path(string uri) {
            string decoded = GLib.Uri.unescape_string(uri, null);
            return decoded.substring(PREFIX.length);
        }

        private GenericArray<BookmarkMatch> bookmarks;

        construct {
            icon_name = "bookmark-new";
            bookmarks = new GenericArray<BookmarkMatch>();
        }


        protected override bool activate(Cancellable current_cancellable) {
            bookmarks = new GenericArray<BookmarkMatch>();
            var filename = Path.build_filename(Environment.get_user_config_dir(), "gtk-3.0", "bookmarks");

            try {
                string contents;
                string[] lines;
                if (FileUtils.get_contents (filename, out contents)) {
                    lines = contents.split ("\n");
                    foreach (unowned string line in lines) {
                        var parts = line.split (" ", 2);
                        if (parts[0] == null)
                            continue;
                        if (parts[1] == null)
                            parts[1] = GLib.Path.get_basename (parts[0]);

                        bookmarks.add(new BookmarkMatch(parts[1], parts[0]));
                    }
                }
                return true;
            } catch (Error err) {
                warning ("%s", err.message);
                return false;
            }
        }

        protected override void deactivate() {
            bookmarks = new GenericArray<BookmarkMatch>();
        }

        private class BookmarkMatch : FileMatch {

            internal BookmarkMatch func() {
                return this;
            }

            public override string get_icon_name() {
                return "user-bookmarks";
            }

            public uint hash { get; construct; }

            public BookmarkMatch(string name, string uri) {
                Object(filename: uri_to_path(uri), hash: uri.hash());
            }
        }

        public override void search(ResultContainer rs) {
            foreach (var bmk in bookmarks) {
                if (rs.has_match(bmk.get_title())) {
                    var score = rs.match_score(bmk.get_title());
                    rs.add_lazy(bmk.hash, score + bonus, bmk.func);
                } else if (rs.has_match(bmk.filename)){
                    var score = rs.match_score(bmk.filename);
                    rs.add_lazy(bmk.hash, score + bonus, bmk.func);
                }
            }
        }
    }
}
