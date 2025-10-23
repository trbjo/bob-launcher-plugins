namespace BobLauncher {
    namespace Calendar {
        public class CalendarIcon : Gtk.Box {
            private ColoredHeader header;
            private Gtk.Label date_label;

            private static Gtk.CssProvider css_provider;

            private const string CALENDAR_ICON_CSS = """
                .calendar-icon {
                    border-radius: 6px;
                    margin: 2px;
                    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.12),
                                0 1px 2px rgba(0, 0, 0, 0.08);
                    border: 0.5px solid rgba(0, 0, 0, 0.1);
                }

                .calendar-month {
                    font-size: 0.7em;
                    font-weight: 700;
                    padding: 1px 0;
                    color: @theme_text_color;
                }

                .calendar-date {
                    color: black;
                    background: white;
                    font-size: 1em;
                    font-weight: 600;
                }

                .duration-container {
                    font-size: 0.8em;
                    border: 1px solid @borders;
                    color: @unmatched_color;
                    border-radius: 4px;
                    font-weight: 500;
                    background: alpha(@unmatched_color, 0.1);
                }
            """;

            static construct {
                css_provider = new Gtk.CssProvider();
                css_provider.load_from_string(CALENDAR_ICON_CSS);
                StyleProvider.add_provider_for_display(
                    Gdk.Display.get_default(),
                    css_provider,
                    Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
                );
            }

            private class ColoredHeader : Gtk.Widget {
                private Gtk.Label month_label;
                private Gdk.RGBA bg_color;

                static construct {
                    set_css_name("calendar-header");
                }

                construct {
                    month_label = new Gtk.Label("");
                    month_label.add_css_class("calendar-month");
                    month_label.set_parent(this);
                }

                public void set_color(Gdk.RGBA color) {
                    bg_color = color;
                    queue_draw();
                }

                public void set_month(string month) {
                    month_label.set_label(month);
                }

                protected override void dispose() {
                    month_label.unparent();
                    base.dispose();
                }

                protected override void measure(Gtk.Orientation orientation, int for_size,
                                               out int minimum, out int natural,
                                               out int minimum_baseline, out int natural_baseline) {
                    month_label.measure(orientation, for_size, out minimum, out natural,
                                       out minimum_baseline, out natural_baseline);
                }

                protected override void size_allocate(int width, int height, int baseline) {
                    month_label.allocate(width, height, baseline, null);
                }

                protected override void snapshot(Gtk.Snapshot snapshot) {
                    snapshot.append_color(bg_color, Graphene.Rect() {
                        origin = { 0, 0 },
                        size = { get_width(), get_height() }
                    });

                    snapshot_child(month_label, snapshot);
                }
            }

            construct {
                orientation = Gtk.Orientation.VERTICAL;
                spacing = 0;
                overflow = Gtk.Overflow.HIDDEN;
                add_css_class("calendar-icon");

                header = new ColoredHeader();
                append(header);

                var date_container = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
                date_container.set_vexpand(true);

                date_label = new Gtk.Label("");
                date_label.add_css_class("calendar-date");
                date_label.set_hexpand(true);
                date_label.set_vexpand(true);
                date_container.append(date_label);

                append(date_container);
            }

            public void set_custom(string month, string date, Gdk.RGBA color) {
                header.set_month(month);
                header.set_color(color);
                date_label.set_label(date);
            }

            public void set_date(GLib.DateTime date, Gdk.RGBA color) {
                header.set_month(date.format("%b").up());
                header.set_color(color);
                date_label.set_label(date.get_day_of_month().to_string());
            }
        }
    }
}
