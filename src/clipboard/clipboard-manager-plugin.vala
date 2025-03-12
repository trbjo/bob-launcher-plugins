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

            // Generic types
            "text/*",
            "application/octet-stream",

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

            // Fallback X11 types (least preferred)
            "UTF8_STRING",
            "STRING",
            "TEXT",
            "text/plain;charset=utf-8",
            "text/plain"
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
                double score = rs.match_score(entry.text);
                if (score > 2.0) {
                    rs.add_lazy(entry.primkey, score + ClipboardManager.plg.bonus, () => {
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
    }

    public class ClipboardManagerPlugin : SearchAction {
        private static Clipboard.Database db;
        private static WaylandClipboard.Manager? wlc;
        private static GenericArray<BobLauncher.Action> actions;
        private static ClipboardHash.Table recent_entries;  // New table for recent items
        private const int MAX_RECENT = 50;

        construct {
            icon_name = "edit-paste";
            recent_entries = new ClipboardHash.Table(MAX_RECENT);
            ClipboardManager.plg = this;
        }

        public static unowned Gdk.Wayland.Display? wayland_display() {
            unowned Gdk.Wayland.Display? display = Gdk.Display.get_default() as Gdk.Wayland.Display;
            return display;
        }

        protected override bool activate(Cancellable current_cancellable) {
            unowned Gdk.Wayland.Display gdk_wayland_display = wayland_display();

            if (gdk_wayland_display == null) {
                warning("failed to get wayland display");
                return false;
            }

            if (!gdk_wayland_display.query_registry("zwlr_data_control_manager_v1")) {
                warning("you don't have support for the zwlr_data_control protocol, not enabling clipboard manager");
                return false;
            }

            db = new Clipboard.Database(this);
            ClipboardTreeManager.initialize(128);
            base.shard_count = 128;

            // Load recent entries first
            unowned Sqlite.Statement latest_stmt = db.get_latest_stmt();
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

            // Then load all entries into tree
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
            string? text = null;
            string? top_mime = null;
            GLib.Bytes? top_bytes = null;
            bool has_file_transfer = false;


            content.foreach((bytes, mime_types) => {
                foreach (string mime_type in mime_types) {
                    foreach (string file_type in possible_files) {
                        if (mime_type == file_type) {
                            has_file_transfer = true;
                            return;
                        }
                    }
                }
            });

            foreach (string preferred_mime in ClipboardManager.PREFERRED_MIME_TYPES) {
                bool found = false;

                content.foreach((bytes, mime_types) => {
                    if (found) return;

                    foreach (string mime_type in mime_types) {
                        if (mime_type == preferred_mime) {
                            top_mime = mime_type;
                            top_bytes = bytes;
                            found = true;
                            return;
                        }
                    }
                });

                if (found) {
                    break; // We found a match, stop searching
                }
            }

            // Don't record the entry if we didn't find any MIME type
            if (top_mime == null) return;

            // Extract text if it's a text-based MIME type
            if (top_mime.has_prefix("text") ||
                top_mime == "UTF8_STRING" ||
                top_mime == "STRING") {
                text = (string)top_bytes.get_data();
            }

            // Handle file paths if this is a file transfer and we have text
            string best_mime_type = top_mime;
            if (has_file_transfer && text != null) {
                // Check if the text is a valid file path
                if (FileUtils.test(text, FileTest.EXISTS)) {
                    var file = File.new_for_path(text);
                    try {
                        best_mime_type = file.query_info(FileAttribute.STANDARD_CONTENT_TYPE, 0).get_content_type();
                    } catch (Error e) { }
                }
            }

            // Use text for display if available, otherwise use the MIME type
            string display_text = text ?? top_mime;

            int64 now = get_current_time();
            ClipboardTreeManager.add_entry(primkey, display_text, now, best_mime_type);
            recent_entries.insert_shift(primkey, display_text, now, best_mime_type);
            db.insert_item(content, hash, best_mime_type, display_text);
        }

        protected override void deactivate() {
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
            db.update_timestamp(match.primkey);
            wlc.set_clipboard(content);
            return true;
        }

        internal bool delete_item(ClipboardMatch match) {
            if (db.delete_item(match.primkey)) {
                ClipboardTreeManager.remove_entry(match.primkey);
                recent_entries.remove(match.primkey);
                return true;
            }
            return false;
        }

        protected override void search_shard(ResultContainer rs, uint shard_id) {
            if (rs.get_query() == "") {
                if (shard_id != 0) return;
                unowned ClipboardHash.Entry[] recent_array = recent_entries.get_entries();
                for (int i = 0; i < recent_array.length; i++) {
                    unowned var entry = recent_array[i];
                    rs.add_lazy_unique(MatchScore.ABOVE_THRESHOLD + ClipboardManager.plg.bonus, () =>
                        new ClipboardMatch(
                            entry.primkey,
                            entry.text,
                            entry.timestamp,
                            entry.content_type
                        )
                    );
                }
            } else {
                ClipboardTreeManager.search_shard(rs, shard_id);
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
