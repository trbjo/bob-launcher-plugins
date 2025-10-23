namespace BobLauncher {
    namespace Calendar {
        private class EditCalendarEventTitle : ActionTarget {
            private unowned Plugin plg;
            private string calendar_name;
            private string calendar_color;

            public override string get_title() {
                return "Change event title";
            }

            public override string get_description() {
                return "Edit the title of this event";
            }

            public override string get_icon_name() {
                return "edit-symbolic";
            }

            internal EditCalendarEventTitle(Plugin _plg, string cal_name, string color) {
                Object();
                plg = _plg;
                calendar_name = cal_name;
                calendar_color = color;
            }

            public override Score get_relevancy(Match match) {
                if (!(match is CalendarMatch)) {
                    return MatchScore.LOWEST;
                }
                return MatchScore.ABOVE_THRESHOLD;
            }

            public override bool do_execute(Match source, Match? target = null) {
                if (!(source is CalendarMatch) || target == null) {
                    return false;
                }

                var cal_match = (CalendarMatch)source;
                var helper = target as CalendarMatchHelper;
                if (helper == null) {
                    return false;
                }

                string new_title = helper.summary;

                if (new_title.strip().length == 0) {
                    warning("Event title cannot be empty");
                    return false;
                }

                if (plg.service == null) {
                    warning("Calendar service not available");
                    return false;
                }

                unowned var calendar = plg.service.get_calendar(cal_match.calendar_name);
                if (calendar == null) {
                    warning("Calendar not found");
                    return false;
                }

                bool success = calendar.update_event(
                    cal_match.uid,
                    new_title,
                    null,
                    null,
                    null,
                    null
                );

                if (success) {
                    calendar.save_and_sync();
               }

                return success;
            }

            public override Match target_match(string query) {
                return new CalendarMatchHelper.for_text(query, calendar_name, calendar_color);
            }
        }
    }
}
