namespace BobLauncher {
    namespace Calendar {
        private class DeleteCalenderEvent : Action {
            private unowned Plugin plg;

            public override string get_title() {
                return "Delete this event";
            }

            public override string get_description() {
                return "Delete this event permanently";
            }

            public override string get_icon_name() {
                return "edit-delete";
            }

            internal DeleteCalenderEvent(Plugin _plg) {
                Object();
                plg = _plg;
            }

            public override Score get_relevancy(Match match) {
                if (!(match is CalendarMatch)) {
                    return MatchScore.LOWEST;
                }
                return MatchScore.ABOVE_THRESHOLD;
            }

            public override bool do_execute(Match source, Match? target = null) {
                if (!(source is CalendarMatch) || (target != null)) {
                    return false;
                }

                var cal_match = (CalendarMatch)source;
                return plg.delete(cal_match.calendar_name, cal_match.uid);
            }
        }

    }
}
