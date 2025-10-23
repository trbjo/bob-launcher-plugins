namespace BobLauncher {
    namespace Calendar {
        internal class CalendarMatchHelper : Match, IRichIcon {
            internal CalendarIcon? _icon = null;
            public string summary { get; construct; }
            public string calendar_name { get; construct; }
            public string calendar_color { get; construct; }
            public DateTime? start { get; construct; default = null; }
            public DateTime? end { get; construct; default = null; }

            internal CalendarMatchHelper(string summary, string calendar_name, string color, DateTime? start, DateTime? end) {
                Object(summary: summary, calendar_name:calendar_name, calendar_color: color, start: start, end: end);
            }

            internal CalendarMatchHelper.for_text(string text, string calendar_name, string color) {
                Object(summary: text, calendar_name: calendar_name, calendar_color: color, start: null, end: null);
            }


            public override string get_title() {
                return summary;
            }

            public override string get_description() {
                if (start == null) {
                    return "Enter start date for the event";
                } else if (end == null) {
                    return "Enter end date for the event";
                }
                return "Create event";
            }

            public override string get_icon_name() {
                assert_not_reached();
                return "event-new";
            }

            public unowned Gtk.Widget get_rich_icon() {
                if (_icon == null) {
                    _icon = new CalendarIcon();
                    Gdk.RGBA color = Gdk.RGBA();
                    color.parse(calendar_color);
                    if (start == null) {
                        _icon.set_custom("NEW", "??", color);
                    } else {
                        _icon.set_date(start, color);
                    }
                }
                return _icon;
            }
        }
    }
}
