[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.ApiBayPlugin);
}


namespace BobLauncher {
    public class ApiBayPlugin : SearchBase {
        construct {
            icon_name = "application-x-bittorrent";
        }

        internal override bool activate() {
            try {
                BASE_URI = Uri.parse(BASE_URL, UriFlags.NONE);
                return true;
            } catch (Error e) {
                warning("Failed to parse BASE_URL: %s", e.message);
                return false;
            }
        }


        private const string BASE_URL = "https://apibay.org/q.php";
        private static Uri BASE_URI;

        private int[] category_ids = { };

        public override void on_setting_changed(string key, GLib.Variant value) {
            var iter = value.iterator();
            int val;
            category_ids = {};
            while (iter.next("i", out val)) {
                category_ids += val;
            }
        }

        public string? send_request(string query) {
            var client = new CurlClient.HttpClient();

            string[] cat_strings = new string[category_ids.length];
            for (int i = 0; i < category_ids.length; i++) {
                cat_strings[i] = category_ids[i].to_string();
            }
            var query_string = "q=" + query + "&cat=" + string.joinv(",", cat_strings);

            // Build the base URL WITHOUT the query string
            client.base_url = Uri.build(UriFlags.NONE,
                                       BASE_URI.get_scheme(),
                                       BASE_URI.get_userinfo(),
                                       BASE_URI.get_host(),
                                       BASE_URI.get_port(),
                                       BASE_URI.get_path(),
                                       query_string,  // No query string here
                                       BASE_URI.get_fragment()).to_string();

            try {
                var response = client.request(CurlClient.HttpClientMethod.GET);

                if (response.code == 200) {
                    return response.get_response_body();
                } else {
                    throw new CurlClient.HttpClientError.ERROR("Torrent search failed with status code: %d", response.code);
                }
            } catch (CurlClient.HttpClientError e) {
                warning("Error occurred: %s", e.message);
            }
            return null;
        }

        public override void search(ResultContainer rs) {
            unowned string needle = rs.get_query();
            var reply = this.send_request(needle);
            if (reply == null) {
                return;
            }

            var parser = new Json.Parser();
            try {
                parser.load_from_data(reply);
            } catch (Error e) {
                return;
            }

            // The root is an array, not an object
            var root_array = parser.get_root().get_array();

            foreach (var torrent_element in root_array.get_elements()) {
                var torrent_object = torrent_element.get_object();

                // use the number of seeders to set the matchscore
                int16 seeders = (int16)uint.parse(torrent_object.get_string_member("seeders"));
                uint hash = torrent_object.get_string_member("info_hash").hash();
                string name = torrent_object.get_string_member("name");
                Score letter_score = rs.match_score(name);
                Score combined = letter_score + seeders;
                rs.add_lazy(hash, combined, () => new TorrentMatch(torrent_object));
            }
        }

        public class TorrentMatch : Match, ITextMatch, IURIMatch {
            public string info_hash { get; set; }
            public uint leechers { get; set; }
            public uint seeders { get; set; }
            public uint num_files { get; set; }
            public uint64 size { get; set; }
            public int64 added { get; set; }
            public string category_name { get; construct; }
            public string mime_type { get; construct; }
            public string? imdb { get; set; }
            public string uri { get; construct; }

            public override string get_icon_name() {
                return IconCacheService.best_icon_name_for_mime_type(mime_type);
            }


            private string cleaned_name;
            public override string get_title() {
                return cleaned_name;
            }

            private string description;
            public override string get_description() {
                return description;
            }

            public string get_text() {
                return this.uri;
            }

            public string get_uri() {
                return this.uri;
            }

            public TorrentMatch(Json.Object torrent_object) {
                var _category_name = obtain_category_name(uint.parse(torrent_object.get_string_member("category")));
                var _seeders = uint.parse(torrent_object.get_string_member("seeders"));
                var _num_files = uint.parse(torrent_object.get_string_member("num_files"));
                var _size = uint64.parse(torrent_object.get_string_member("size"));
                var _added = int64.parse(torrent_object.get_string_member("added"));
                var _cleaned_name = clean_name(torrent_object.get_string_member("name"));

                var _mime_type = find_mime_type(_category_name);
                var _description = create_description(_category_name, _size, _added, _seeders, _num_files);
                Object(
                    added: _added,
                    uri: generate_magnet_uri(_cleaned_name, torrent_object.get_string_member("info_hash")),
                    category_name: _category_name,
                    num_files: _num_files,
                    seeders: _seeders,
                    mime_type: _mime_type,
                    size: _size,
                    imdb: torrent_object.get_string_member("imdb"),
                    leechers: uint.parse(torrent_object.get_string_member("leechers")),
                    info_hash: torrent_object.get_string_member("info_hash")
                );
                this.description = _description;
                this.cleaned_name = _cleaned_name;
            }
            private static string[] trackers = {
                "udp%3A%2F%2Ftracker.openbittorrent.com%3A6969",
                "udp%3A%2F%2Ftracker.tiny-vps.com%3A6969",
                "udp%3A%2F%2F46.148.18.250%3A2710",
                "udp%3A%2F%2Fopentrackr.org%3A1337"
            };

            public static string generate_magnet_uri(string name, string info_hash) {
                if (info_hash.length == 0) {
                    return "";
                }

                StringBuilder magnet_uri = new StringBuilder();
                magnet_uri.append("magnet:?xt=urn:btih:");
                magnet_uri.append(info_hash);

                string encoded_name = Uri.escape_string(name.strip().replace("&", "%26"), null, true);
                magnet_uri.append("&dn=").append(encoded_name);

                foreach (string tracker in trackers) {
                    magnet_uri.append("&tr=").append(tracker);
                }

                return magnet_uri.str;
            }


            private const string[,] replacements = {
                {"&amp;", "&"},
                {"&aelig;", "æ"},
                {"Ã¦", "æ"},
                {"Ã˜", "Ø"},
                {"^ ", ""},
                {"Ã©", "é"},
                {"\t", ""},
                {"&Atilde;&cedil;", "ø"},
                {"&hellip;", "…"},
                {"&oslash;", "ø"},
                {"Ã¸", "ø"},
                {"Ã¶", "ö"},
                {"&ouml;", "ö"},
                {"Ã–", "Ö"},
                {"&auml;", "ä"},
                {"&ndash;", "–"},
                {"&mdash;", "—"},
                {"ï¿½", "ä"},
                {"Ã¤", "ä"},
                {"&Auml;", "Ä"},
                {"&Ouml;", "Ö"},
                {"Ã„", "Ä"},
                {"Ã¥", "å"},
                {"&aring;", "å"},
                {"&Atilde;&yen;", "å"},
                {"&Aring;", "Å"},
                {"Ã…", "Å"},
                {"&frac12;", "½"},
                {"&ntilde;", "ñ"},
                {"Ã±", "ñ"},
                {"&eacute;", "é"},
                {"\\", ""},
                {"Ã†", "Æ"},
                {"&uuml;", "ü"},
                {"&quot;", "\""}
            };

            public static string clean_name(string input) {
                string result = input;

                for (int i = 0; i < replacements.length[0]; i++) {
                    result = result.replace(replacements[i,0], replacements[i,1]);
                }

                return result.strip();
            }


            private static string create_description(string category_name, uint64 size, int64 added, uint seeders, uint num_files) {
                var size_gb = format_size(size);
                var date = new DateTime.from_unix_local(added).format("%Y-%m-%d");
                return @"$category_name | Size: $size_gb | Seeders: $seeders | Added: $date | Files: $num_files";
            }

            private static string format_size(uint64 size) {
                double formatted_size;
                string unit;

                if (size > 1000000000) {
                    formatted_size = (double)size / 1000000000;
                    unit = "GB";
                } else {
                    formatted_size = (double)size / 1000000;
                    unit = "MB";
                }

                formatted_size = Math.round(formatted_size * 100) / 100;

                return "%.2f %s".printf(formatted_size, unit);
            }


            private static string obtain_category_name(uint category) {
                switch (category) {
                    case 101: return "Music";
                    case 102: return "Audio Book";
                    case 103: return "Sound Clip";
                    case 104: return "FLAC Music";
                    case 199: return "Other Audio";
                    case 201: return "Movie";
                    case 202: return "DVD Movie";
                    case 203: return "Music Video";
                    case 205: return "TV-Show";
                    case 206: return "Handheld Video";
                    case 207: return "HD Movie";
                    case 208: return "HD TV-show";
                    case 209: return "3D Movie";
                    case 299: return "Other Video";
                    case 301: return "PC Software";
                    case 302: return "Mac Software";
                    case 303: return "Linux Software";
                    case 601: return "E-book";
                    case 602: return "Comics";
                    case 603: return "Picture";
                    case 604: return "Comics";
                    case 699: return "Other";
                    default:
                        if (category >= 400 && category < 500) {
                            return "Game";
                        }
                        return "Unknown";
                }
            }

            private static string find_mime_type(string category_name) {
                switch (category_name) {
                    case "Music":
                    case "FLAC Music":
                        return "audio/mpeg";
                    case "Audio Book":
                    case "Sound Clip":
                    case "Other Audio":
                        return "audio/x-vorbis+ogg";
                    case "Movie":
                    case "DVD Movie":
                    case "Music Video":
                    case "TV-Show":
                    case "Handheld Video":
                    case "HD Movie":
                    case "HD TV-show":
                    case "3D Movie":
                    case "Other Video":
                        return "video/x-matroska";
                    case "PC Software":
                    case "Mac Software":
                    case "Linux Software":
                        return "application/x-executable";
                    case "E-book":
                        return "application/epub+zip";
                    case "Comics":
                        return "application/x-cbr";
                    case "Picture":
                        return "image/jpeg";
                    case "Game":
                        return "application/x-executable";
                    default:
                        return "application/octet-stream";
                }
            }
        }
    }
}
