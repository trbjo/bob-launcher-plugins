namespace BobLauncher {
    public class ClipboardMatch : Match, IRichDescription {
        public uint32 primkey { get; construct; }
        public string icon_type { get; construct; }
        private int max_tooltip_length = 3000;
        private string title;
        private string content;
        private string timestamp_text;
        private int character_count = 0;
        public string content_type;

        private Description? _cached_description = null;

        public override string get_title() {
            return title;
        }

        public override string get_description() {
            assert_not_reached();
        }

        public override string get_icon_name() {
            return icon_type;
        }

        public unowned Description get_rich_description(Levensteihn.StringInfo si) {
            if (_cached_description == null) {
                _cached_description = build_rich_description();
            }
            return _cached_description;
        }

        private Description build_rich_description() {
            var root = new Description.container("clipboard-description");

            var timestamp_group = new Description.container("timestamp-group", Gtk.Orientation.HORIZONTAL);

            var separator = new Description("tools-timer-symbolic", "timestamp-image", FragmentType.IMAGE, null);
            timestamp_group.add_child(separator);

            var time_desc = new Description(timestamp_text, "timestamp", FragmentType.TEXT, null);
            timestamp_group.add_child(time_desc);

            root.add_child(timestamp_group);

            if (character_count > 0) {
                var count_group = new Description.container("count-group", Gtk.Orientation.HORIZONTAL);

                var count_icon = new Description("text-x-generic-symbolic", "count-image", FragmentType.IMAGE, null);
                count_group.add_child(count_icon);

                var count_desc = new Description("%d characters".printf(character_count), "count-text", FragmentType.TEXT, null);
                count_group.add_child(count_desc);

                root.add_child(count_group);
            }

            return root;
        }

        public class ColorPreview : Gtk.Widget {
            private string _color_string;
            private Gdk.RGBA? _color = null;

            public ColorPreview(string color_string) {
                Object();
                _color_string = color_string;
                _color = Gdk.RGBA();
                _color.parse(color_string);
            }

            construct {
                overflow = Gtk.Overflow.HIDDEN;
                css_classes = {"tooltip-color"};
            }

            public override Gtk.SizeRequestMode get_request_mode() {
                return Gtk.SizeRequestMode.CONSTANT_SIZE;
            }

            public override void snapshot(Gtk.Snapshot snapshot) {
                var width = get_width();
                var height = get_height();

                var color_rect = Graphene.Rect();
                color_rect.init(0, 0, width, height);

                var color_rounded = Gsk.RoundedRect();
                color_rounded.init_from_rect(color_rect, 0);
                snapshot.push_rounded_clip(color_rounded);
                snapshot.append_color(_color, color_rect);
                snapshot.pop();

                var text_color = contrast_color(_color);
                var layout = create_pango_layout(_color_string);
                var font = Pango.FontDescription.from_string("Sans 10");
                layout.set_font_description(font);

                int text_width, text_height;
                layout.get_size(out text_width, out text_height);

                var text_x = (width - text_width / Pango.SCALE) / 2;
                var text_y = (height - text_height / Pango.SCALE) / 2;

                snapshot.save();
                snapshot.translate(Graphene.Point().init(text_x, text_y));
                snapshot.append_layout(layout, text_color);
                snapshot.restore();
            }


            private Gdk.RGBA contrast_color(Gdk.RGBA bg) {
                double luminance = 0.299 * bg.red + 0.587 * bg.green + 0.114 * bg.blue;

                if (luminance > 0.5) {
                    return Gdk.RGBA(){red=0, green=0, blue=0, alpha=1.0f};
                } else {
                    return Gdk.RGBA(){red=1, green=1, blue=1, alpha=1.0f};
                }
            }
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

                double width_scale = width > MAX_WIDTH ? (double)MAX_WIDTH / width : 1.0;
                double height_scale = height > MAX_HEIGHT ? (double)MAX_HEIGHT / height : 1.0;

                double scale = double.min(width_scale, height_scale);

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

        public override unowned Gtk.Widget? get_tooltip() {
            if (_tooltip_widget != null) {
                return _tooltip_widget;
            }

            // Check for hex color format
            string trimmed_content = content.strip();
            if ((trimmed_content.has_prefix("#") && (trimmed_content.length == 7 || trimmed_content.length == 9)) ||
                ((trimmed_content.length == 6 || trimmed_content.length == 8) &&
                 trimmed_content.down().chug().chomp().get_char(0).isxdigit())) {

                string color_string = trimmed_content;
                if (!color_string.has_prefix("#")) {
                    color_string = "#" + color_string;
                }

                Gdk.RGBA rgba = Gdk.RGBA();
                if (rgba.parse(color_string)) {
                    _tooltip_widget = new ColorPreview(color_string);
                    return _tooltip_widget;
                }
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
                xalign = 0.0f,
                yalign = 0.0f,
                ellipsize = Pango.EllipsizeMode.END,
                wrap_mode = Pango.WrapMode.CHAR,
                // natural_wrap_mode = Gtk.NaturalWrapMode.NONE,
                // max_width_chars = 70,
            };
            return _tooltip_widget;
        }

        public ClipboardMatch(uint primkey, string? text, int64 timestamp, string content_type) {
            if (text == null) {
                error("text is null");
            }

            var icon_type = IconCacheService.best_icon_name_for_mime_type(content_type);

            Object(primkey: primkey, icon_type: icon_type);
            this.content_type = content_type;

            var date_time = new DateTime.from_unix_utc(timestamp / 1000000);
            var now = new DateTime.now_local();

            string new_text = text.chug();
            string append_ellipsis = new_text.length > 200 ? "…" : "";

            int max_length = int.min(200, new_text.length);
            this.title = new_text.slice(0, max_length) + append_ellipsis;
            this.content = text;

            string time_str = BobLauncher.Utils.format_modification_time(now, date_time);
            this.timestamp_text = time_str;

            if (this.content_type.down().contains("text")) {
                this.character_count = text.length;
            }
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
            if (!(m is ClipboardMatch)) return MatchScore.BELOW_THRESHOLD;
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
            if (!(match is ClipboardMatch)) return MatchScore.BELOW_THRESHOLD;
            return MatchScore.VERY_GOOD;
        }

        protected override bool do_execute(Match match, Match? target = null) {
            if (!(match is ClipboardMatch)) return false;
            return ClipboardManager.plg.set_clipboard((ClipboardMatch)match);
        }
    }
}
