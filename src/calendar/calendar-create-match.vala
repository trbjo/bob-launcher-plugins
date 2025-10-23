namespace BobLauncher {
    namespace Calendar {
        internal class CalendarMatchCreate : Match {
            public string summary { get; construct; }

            internal CalendarMatchCreate(string summary) {
                Object(summary: summary);
            }

            public override string get_title() {
                return "Create event: \""+summary+"\"";
            }

            public override string get_description() {
                return "Create a new calendar event";
            }
            public override string get_icon_name() {
                return "event-new";
            }
        }

    }
}
