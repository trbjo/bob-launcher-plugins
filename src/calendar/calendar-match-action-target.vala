namespace BobLauncher {
    namespace Calendar {
        public class CalendarActionTarget : ActionTarget, IRichIcon {
            internal CalendarIcon? _icon = null;

            private unowned Plugin plg;
            public string summary { get; construct; }
            public string calendar_name { get; construct; }
            private string calendar_color;

            internal CalendarActionTarget(Plugin _plg, string calendar_name, string color, string summary) {
                Object(summary: summary, calendar_name: calendar_name);
                plg = _plg;
                calendar_color = color;
            }

            public override Score get_relevancy(Match match) {
                if (Plugin.is_supported(match)) {
                    return MatchScore.BELOW_AVERAGE;
                }
                return MatchScore.LOWEST;
            }

            public unowned Gtk.Widget get_rich_icon() {
                if (_icon == null) {
                    _icon = new CalendarIcon();
                    Gdk.RGBA color = Gdk.RGBA();
                    color.parse(calendar_color ?? "#4CAF50");
                    _icon.set_custom("NEW", "??", color);
                }
                return _icon;
            }

            public override string get_title() {
                return "Create a new calendar entry in " + calendar_name;
            }

            public override string get_description() {
                return summary;
            }

            public override string get_icon_name() {
                return "event-new";
            }

            public override bool do_execute(Match source, Match? target = null) {
                if (target == null) return false;

                // Check if the target match is an error/unknown match
                unowned UnknownMatch? unknown = target as UnknownMatch;
                if (unknown != null) {
                    warning("Cannot create event: %s", unknown.get_description());
                    return false;
                }

                unowned CalendarMatch? cal_match = target as CalendarMatch;
                if (cal_match == null) {
                    warning("Target is not a valid calendar match");
                    return false;
                }

                if (summary.strip().length == 0) {
                    warning("Event summary cannot be empty");
                    return false;
                }

                // Get the calendar to add to
                unowned var calendar = plg.service.get_calendar(this.calendar_name);
                if (calendar == null) {
                    warning("Calendar not found");
                    return false;
                }

                CalendarService.CalendarEventTime event_time = {
                    cal_match.event_time.start,
                    cal_match.event_time.end != 0 ? cal_match.event_time.end : cal_match.event_time.start + 3600,
                    false  // is_all_day - could enhance parser to detect this
                };

                bool success = calendar.add_event(
                    summary,
                    event_time,
                    null,   // location - could be added to parser
                    null,   // description
                    null    // url
                );

                if (success) {
                    calendar.save_and_sync();
                    return true;
                } else {
                    warning("Failed to create event '%s'", summary);
                    return false;
                }
            }

            public override Match target_match(string query) {
                var normalized = query.strip().down();

                DateTime? start_dt = null;
                DateTime? end_dt = null;
                int consumed = 0;

                Utils.parse_datetime_range(normalized, out start_dt, out end_dt, out consumed);
                if (start_dt == null || end_dt == null) {
                    return new CalendarMatchHelper(summary, this.calendar_name, this.calendar_color, start_dt, end_dt);
                }

                // Extract the remaining text as the event description
                // Use original query to preserve case
                string event_description = "";
                if (consumed < query.length) {
                    event_description = query.substring(consumed).strip();
                }

                CalendarService.Event event = CalendarService.Event() {
                    uid = "",
                    summary = summary,
                    time = {
                        (time_t)start_dt.to_unix(),
                        end_dt != null ? (time_t)end_dt.to_unix() : (time_t)start_dt.add_hours(1).to_unix(),
                        false  // Could enhance parser to detect all-day events
                    },
                    timezone = "",
                    location = "",
                    description = event_description,
                    url = ""
                };

                return new CalendarMatch(event, this.calendar_name, this.calendar_color);
            }
        }
    }
}
