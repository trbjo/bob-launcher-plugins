namespace BobLauncher {
    public class ClipboardMatch : Match {
        public uint32 primkey { get; construct; }
        public string icon_type { get; construct; }
        private int max_tooltip_length = 3000;
        private string title;
        private string content;
        private string description;
        private string content_type;

        public override string get_title() {
            return title;
        }

        public class ImagePreview : Gtk.Widget {
            private Gdk.Paintable? _paintable = null;
            private const int MAX_WIDTH = 800;
            private const int MAX_HEIGHT = 600;

            public ImagePreview(Gdk.Paintable paintable) {
                Object();
                _paintable = paintable;
            }

            construct {
                css_classes = {"tooltip-image"};
                overflow = Gtk.Overflow.HIDDEN;
            }

            public override void measure(Gtk.Orientation orientation, int for_size,
                                       out int minimum, out int natural,
                                       out int minimum_baseline, out int natural_baseline) {
                minimum_baseline = natural_baseline = -1;

                if (_paintable == null) {
                    minimum = natural = 0;
                    return;
                }

                int width = _paintable.get_intrinsic_width();
                int height = _paintable.get_intrinsic_height();

                // Calculate scale factors for both dimensions
                double width_scale = width > MAX_WIDTH ? (double)MAX_WIDTH / width : 1.0;
                double height_scale = height > MAX_HEIGHT ? (double)MAX_HEIGHT / height : 1.0;

                // Use the smaller scale to maintain aspect ratio
                double scale = double.min(width_scale, height_scale);

                // Round up instead of truncating
                width = (int)Math.ceil(width * scale);
                height = (int)Math.ceil(height * scale);

                if (orientation == Gtk.Orientation.HORIZONTAL) {
                    minimum = natural = width;
                } else {
                    minimum = natural = height;
                }
            }

            public override Gtk.SizeRequestMode get_request_mode() {
                return Gtk.SizeRequestMode.CONSTANT_SIZE;
            }

            public override void snapshot(Gtk.Snapshot snapshot) {
                if (_paintable == null) return;

                int width = _paintable.get_intrinsic_width();
                int height = _paintable.get_intrinsic_height();

                double width_scale = width > MAX_WIDTH ? (double)MAX_WIDTH / width : 1.0;
                double height_scale = height > MAX_HEIGHT ? (double)MAX_HEIGHT / height : 1.0;
                double scale = double.min(width_scale, height_scale);

                width = (int)Math.ceil(width * scale);
                height = (int)Math.ceil(height * scale);

                _paintable.snapshot(snapshot, width, height);
            }
        }

        private Gtk.Widget? _tooltip_widget = null;
        public override Gtk.Widget? get_tooltip() {
            if (_tooltip_widget != null) {
                return _tooltip_widget;
            }

            if ("image" in content_type) {
                var full_content = ClipboardManager.plg.get_content(primkey);

                foreach (var bytes in full_content.get_keys()) {
                    var mime_types = full_content[bytes];
                    foreach (var mime in mime_types) {
                        if (mime.has_prefix("image/")) {
                            try {
                                var texture = Gdk.Texture.from_bytes(bytes);
                                _tooltip_widget = new ImagePreview(texture);
                                return _tooltip_widget;
                            } catch (Error e) {
                                warning("Failed to load image: %s", e.message);
                                continue;
                            }
                        }
                    }
                }
            }

            if (FileUtils.test(content, FileTest.EXISTS)) {
                try {
                    var file = File.new_for_path(content);
                    var info = file.query_info("standard::content-type", FileQueryInfoFlags.NONE);
                    var file_content_type = info.get_content_type();
                    if (file_content_type != null && file_content_type.has_prefix("image/")) {
                        // It's an image file, load it directly
                        var texture = Gdk.Texture.from_file(file);
                        _tooltip_widget = new ImagePreview(texture);
                        return _tooltip_widget;
                    }
                } catch (Error e) {
                    warning("Failed to check file type: %s", e.message);
                }

                // Check for a thumbnail
                string thumb_path = Utils.get_thumbnail_path(content, 512);
                if (FileUtils.test(thumb_path, FileTest.EXISTS)) {
                    try {
                        var file = File.new_for_path(thumb_path);
                        var texture = Gdk.Texture.from_file(file);
                        _tooltip_widget = new ImagePreview(texture);
                        return _tooltip_widget;
                    } catch (Error e) {
                        warning("Failed to load thumbnail: %s", e.message);
                    }
                }
            }

            // Fallback to text label
            string label_text = content.length > max_tooltip_length ? content.slice(0, max_tooltip_length) + "…" : content;
            _tooltip_widget = new Gtk.Label(label_text) {
                css_classes = {"tooltip-label"},
                use_markup = false,
                overflow = Gtk.Overflow.HIDDEN,
                wrap = true,
                max_width_chars = 70,
            };
            return _tooltip_widget;
        }


        public override string get_description() {
            return description;
        }

        public override string get_icon_name() {
            return icon_type;
        }

        public ClipboardMatch(uint primkey, string? text, int64 timestamp, string content_type) {
            if (text == null) {
                error("text is null");
            }

            var icon_type = BobLauncher.IconCacheService.best_icon_name_for_mime_type(content_type);

            Object(primkey: primkey, icon_type: icon_type);
            this.content_type = content_type;

            var date_time = new DateTime.from_unix_utc(timestamp / 1000000);
            var now = new DateTime.now_local();

            string new_text = text.chug();
            string append_ellipsis = new_text.length > 200 ? "…" : "";

            int max_length = int.min(200, new_text.length);
            this.title = new_text.slice(0, max_length) + append_ellipsis;
            this.content = text;
            this.description = BobLauncher.Utils.format_modification_time(now, date_time);
        }
    }

    public class ClipboardDelete : BobLauncher.Action {
        public override string get_title() {
            return "Delete from Clipboard History";
        }

        public override string get_description() {
            return "Delete from Clipboard History";
        }

        public override string get_icon_name() {
            return "edit-delete";
        }

        public override Score get_relevancy(Match m) {
            if (!(m is ClipboardMatch)) return MatchScore.NONE;
            return MatchScore.ABOVE_THRESHOLD;
        }

        protected override bool do_execute(Match match, Match? target = null) {
            if (!(match is ClipboardMatch)) return false;
            return ClipboardManager.plg.delete_item((ClipboardMatch)match);
        }
    }

    public class ClipboardCopy : BobLauncher.Action {
        public override string get_title() {
            return "Copy to Clipboard";
        }

        public override string get_description() {
            return "Copy clipboard item";
        }

        public override string get_icon_name() {
            return "insert-link";
        }

        public override Score get_relevancy(Match match) {
            if (!(match is ClipboardMatch)) return MatchScore.NONE;
            return MatchScore.VERY_GOOD;
        }

        protected override bool do_execute(Match match, Match? target = null) {
            if (!(match is ClipboardMatch)) return false;
            return ClipboardManager.plg.set_clipboard((ClipboardMatch)match);
        }
    }
}
