[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.ClipboardManagerPlugin);
}

namespace BobLauncher {
    namespace ClipboardManager {
        public const string[] PREFERRED_MIME_TYPES = {
            // Rich text formats
            "application/rtf",
            "application/x-rtf",

            // Document formats
            "application/pdf",
            "application/vnd.oasis.opendocument.text",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/msword",
            "application/vnd.oasis.opendocument.spreadsheet",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/vnd.ms-excel",
            "application/vnd.oasis.opendocument.presentation",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "application/vnd.ms-powerpoint",

            // Image formats - most detailed to least
            "image/jpeg",
            "image/png",
            "image/webp",
            "image/gif",
            "image/svg+xml",
            "image/bmp",
            "image/tiff",
            "image/x-icon",
            "image/vnd.microsoft.icon",
            "image/*",

            // Audio formats
            "audio/mpeg",
            "audio/ogg",
            "audio/flac",
            "audio/wav",
            "audio/webm",
            "audio/aac",
            "audio/mp4",
            "audio/*",

            // Video formats
            "video/mp4",
            "video/webm",
            "video/ogg",
            "video/x-matroska",
            "video/mpeg",
            "video/quicktime",
            "video/*",

            // Archive formats
            "application/zip",
            "application/x-tar",
            "application/gzip",
            "application/x-bzip2",
            "application/x-7z-compressed",
            "application/x-rar-compressed",

            // Code and data formats
            "application/json",
            "application/xml",
            "application/javascript",
            "application/x-httpd-php",
            "application/x-sh",
            "application/x-python",
            "application/sql",

            // GNOME specific
            "application/x-gnome-saved-search",
            "inode/directory",
            "x-scheme-handler/http",
            "x-scheme-handler/https",
            "x-scheme-handler/ftp",
            "x-scheme-handler/mailto",
            "x-scheme-handler/file",

            // Freedesktop
            "application/x-desktop",
            "application/x-trash",


            "text/plain;charset=utf-8",
            "text/plain",
            "text/html;charset=utf-8",
            "text/html",
            "text/markdown;charset=utf-8",
            "text/markdown",
            "text/css;charset=utf-8",
            "text/css",
            "text/csv;charset=utf-8",
            "text/csv",
            "text/xml;charset=utf-8",
            "text/xml",
            "text/javascript;charset=utf-8",
            "text/javascript",

            "application/vnd.portal.files",
            "application/vnd.portal.filetransfer",
            "text/uri-list",
            "x-special/gnome-copied-files",
            "application/x-kde-cutselection",

            "text/*",

            "UTF8_STRING",
            "STRING",
            "TEXT",
            "application/octet-stream",
        };

        internal static unowned ClipboardManagerPlugin? plg;
    }

    namespace ClipboardTreeManager {
        private static ClipboardHash.Table[] entries;
        internal static uint num_shards;

        private static void teardown() {
            for (int i = 0; i < num_shards; i++) {
                entries[i] = null;
            }
        }

        private static void initialize(int shards) {
            num_shards = shards;

            entries = new ClipboardHash.Table[num_shards];
            for (int i = 0; i < num_shards; i++) {
                entries[i] = new ClipboardHash.Table(512);
            }
        }

        private static uint get_shard_index(uint primkey) {
            return (uint)(primkey % num_shards);
        }

        public static void add_entry(uint primkey, string text, int64 timestamp, string content_type) {
            uint shard_index = get_shard_index(primkey);
            entries[shard_index].insert(primkey, text, timestamp, content_type);
        }

        public static void remove_entry(uint primkey) {
            uint shard_index = get_shard_index(primkey);
            entries[shard_index].remove(primkey);
        }

        public static void search_shard(ResultContainer rs, uint shard_id) {
            unowned ClipboardHash.Entry[] entries_array = entries[shard_id].get_entries();

            for (int i = 0; i < entries_array.length; i++) {
                unowned ClipboardHash.Entry entry = entries_array[i];
                Score score = rs.match_score(entry.text);
                rs.add_lazy_unique(score, () => {
                    return new ClipboardMatch(
                        entry.primkey,
                        entry.text,
                        entry.timestamp,
                        entry.content_type
                    );
                });
            }
        }
    }

    public class ClipboardManagerPlugin : SearchBase {
        private static Clipboard.Database db;
        private static WaylandClipboard.Manager? wlc;
        private static GenericArray<BobLauncher.Action> actions;
        private static ClipboardHash.Table recent_entries;  // New table for recent items

        private int max_recent_entries = 1;
        private Regex content_ignore_regex;
        private string[] mimetype_ignore_list;

        construct {
            icon_name = "edit-paste";
            recent_entries = new ClipboardHash.Table(max_recent_entries);
            ClipboardManager.plg = this;
            try {
                content_ignore_regex = new GLib.Regex("^$", GLib.RegexCompileFlags.OPTIMIZE, 0);
            } catch (GLib.RegexError e) { }
        }

        public override void on_setting_changed(string key, GLib.Variant value) {
            if (key == "content-ignore-regex") {
                string regex_pattern = value.get_string();
                try {
                    content_ignore_regex = new GLib.Regex(regex_pattern, GLib.RegexCompileFlags.OPTIMIZE, 0);
                } catch (GLib.RegexError e) {
                    warning("Failed to compile regex '%s', reusing existing: %s: %s", regex_pattern, content_ignore_regex.get_pattern(), e.message);
                }
            } else if (key == "mimetype-ignore-list") {
                mimetype_ignore_list = value.get_strv();
                qsort_with_data<string?>(mimetype_ignore_list, sizeof(string?), (CompareDataFunc)strcmp);
            } else if (key == "max-recent-entries") {
                max_recent_entries = value.get_int32();
                if (recent_entries != null && db != null) load_recent_entries();
            }
        }

        private void load_recent_entries() {
            recent_entries = null;
            recent_entries = new ClipboardHash.Table(max_recent_entries);

            unowned Sqlite.Statement latest_stmt = db.get_latest_stmt(max_recent_entries);
            latest_stmt.reset();
            while (latest_stmt.step() == Sqlite.ROW) {
                uint primkey = (uint)latest_stmt.column_int64(0);
                int64 timestamp = latest_stmt.column_int64(1);
                string top_mime = latest_stmt.column_text(2);
                string? text = latest_stmt.column_text(3);
                if (text != null) {
                    recent_entries.insert(primkey, text, timestamp, top_mime);
                }
            }
        }

        private int64 timestamp_offset;

        public override bool activate() {
            if (!WaylandProtocol.has_protocol("zwlr_data_control_manager_v1")) {
                warning("you don't have support for the zwlr_data_control protocol, not enabling clipboard manager");
                return false;
            }

            db = new Clipboard.Database(this);
            timestamp_offset = db.calculate_timestamp_offset();
            ClipboardTreeManager.initialize(32);
            base.shard_count = 32;

            load_recent_entries();

            unowned Sqlite.Statement stmt = db.get_all_items();
            stmt.reset();
            while (stmt.step() == Sqlite.ROW) {
                uint primkey = (uint)stmt.column_int64(0);
                int64 timestamp = stmt.column_int64(1);
                string top_mime = stmt.column_text(2);
                string? text = stmt.column_text(3);
                if (text != null) {
                    ClipboardTreeManager.add_entry(primkey, text, timestamp, top_mime);
                }
            }

            actions = new GenericArray<BobLauncher.Action>();
            actions.add(new ClipboardCopy());
            actions.add(new ClipboardDelete());

            debug("registered clipboard plugin");

            wlc = new WaylandClipboard.Manager(on_clipboard_changed);
            wlc.listen();

            return true;
        }

        private const string[] possible_files = {
            "application/vnd.portal.filetransfer",
            "application/vnd.portal.files",
            "text/uri-list",
            "x-special/gnome-copied-files"
        };

        internal static void on_clipboard_changed(GLib.HashTable<GLib.Bytes, GLib.GenericArray<string>> content, uint hash) {
            uint primkey = hash;
            string? top_mime = null;
            GLib.Bytes? top_bytes = null;
            List<string> mimes = new List<string>();
            List<Bytes> content_bytes = new List<Bytes>();

            bool skip_item = false;

            content.foreach((bytes, mime_types) => {
                if (skip_item) return;
                foreach (string mime_type in mime_types) {
                    if (mime_type in ClipboardManager.plg.mimetype_ignore_list) skip_item = true;
                    if (skip_item) return;

                    mimes.append(mime_type);
                    content_bytes.append(bytes);
                }
            });

            if (skip_item) return;

            bool found = false;

            foreach (string preferred_mime in ClipboardManager.PREFERRED_MIME_TYPES) {
                if (found) break;
                for (int i = 0; i < mimes.length(); i++) {
                    if (found) break;
                    unowned string mime_type = mimes.nth_data(i);
                    if (mime_type == preferred_mime) {
                        top_mime = mime_type;
                        top_bytes = content_bytes.nth_data(i);
                        found = true;
                    }
                }
            }

            // Don't record the entry if we didn't find any MIME type
            if (top_mime == null || top_bytes == null) return;

            // Use text for display if available, otherwise use the MIME type
            string display_text;

            if (top_mime.down().contains("text")) {
                unowned uint8[] data = top_bytes.get_data();
                var builder = new StringBuilder();
                builder.append_len((string)data, data.length);
                display_text = builder.str;

                if (ClipboardManager.plg.content_ignore_regex.match (display_text)) {
                    debug("display text matches regex: %s, returning", ClipboardManager.plg.content_ignore_regex.get_pattern());
                    return;
                }
            } else {
                display_text = top_mime;
            }

            foreach (string file_type in possible_files) {
                if (file_type in mimes.data) {
                    if (FileUtils.test(display_text, FileTest.EXISTS)) {
                        var file = File.new_for_path(display_text);
                        try {
                            top_mime = file.query_info(FileAttribute.STANDARD_CONTENT_TYPE, 0).get_content_type();
                        } catch (Error e) { }
                    }
                }
            }

            int64 now = get_current_time();
            ClipboardTreeManager.add_entry(primkey, display_text, now, top_mime);
            recent_entries.insert_shift(primkey, display_text, now, top_mime);
            db.insert_item(content, hash, top_mime, display_text);
        }

        public override void deactivate() {
            wlc = null;
            if (db != null) db.cleanup();
            db = null;
            ClipboardTreeManager.teardown();
        }

        internal GLib.HashTable<Bytes, GenericArray<string>> get_content(uint primkey) {
            return db.get_content(primkey);
        }

        internal bool set_clipboard(ClipboardMatch match) {
            var content = this.get_content(match.primkey);
            if (content.size() == 0) {
                return false;
            }

            int64 now = GLib.get_real_time();
            db.update_timestamp(match.primkey, now);
            recent_entries.insert_shift(match.primkey, match.get_title(), now, match.content_type);
            wlc.set_clipboard(content);
            return true;
        }

        internal bool delete_item(ClipboardMatch match) {
            if (db.delete_item(match.primkey)) {
                ClipboardTreeManager.remove_entry(match.primkey);
                recent_entries.remove_shift(match.primkey);
                return true;
            }
            return false;
        }

        protected override void search_shard(ResultContainer rs, uint shard_id) {
            if (rs.get_query() != "") {
                ClipboardTreeManager.search_shard(rs, shard_id);
            } else if (shard_id == 0) {
                int16 base_score = MatchScore.ABOVE_THRESHOLD;
                unowned ClipboardHash.Entry[] recent_array = recent_entries.get_entries();
                int length = (int)recent_array.length;
                for (int i = length-1; i >= 0 ; i--) {
                    unowned var entry = recent_array[i];
                    // uint32 hash = uint32.MAX - (uint32)((entry.timestamp - timestamp_offset) >> 14);
                    rs.add_lazy_unique(base_score, () =>
                        new ClipboardMatch(
                            entry.primkey,
                            entry.text,
                            entry.timestamp,
                            entry.content_type
                        )
                    );
                }
            }
        }

        public override void find_for_match(Match match, ActionSet rs) {
            if (!(match is ClipboardMatch)) return;
            foreach (var action in actions) {
                rs.add_action(action);
            }
        }

        private static int64 get_current_time() {
            return new DateTime.now_local().to_unix() * 1000000;
        }
    }
}
