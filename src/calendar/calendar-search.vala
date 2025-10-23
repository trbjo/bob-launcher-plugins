namespace StyleProvider {
    // TODO: Remove when merged
    // https://gitlab.gnome.org/GNOME/vala/-/merge_requests/312/
    [CCode (cname = "gtk_style_context_add_provider_for_display")]
    extern static void add_provider_for_display(Gdk.Display display, Gtk.StyleProvider provider, uint priority);

    // https://gitlab.gnome.org/GNOME/vala/-/merge_requests/312/
    [CCode (cname = "gtk_style_context_remove_provider_for_display")]
    extern static void remove_provider_for_display(Gdk.Display display, Gtk.StyleProvider provider);
}

[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.Calendar.Plugin);
}

namespace BobLauncher {
    namespace Calendar {
        public class Plugin : SearchBase {
            private void spinlock() {
                while (Threading.atomic_exchange(ref lock_token, 1) == 1) {
                    Threading.pause();
                }
            }

            private void spin_unlock() {
                Threading.atomic_store(ref lock_token, 0);
            }

            private int lock_token;

            private HashTable<string, string> calendar_colors;
            private GenericArray<CalendarMatch> agenda;
            private HashTable<string, GenericArray<CalendarService.Event?>> calendar_events;
            internal CalendarService.Service? service;

            private DeleteCalenderEvent delete_action;
            private HashTable<string, EditCalendarEventTitle> edit_title_actions;
            private HashTable<string, EditCalendarEventDescription> edit_description_actions;

            construct {
                icon_name = "calendar";
                agenda = new GenericArray<CalendarMatch>();
                calendar_colors = new HashTable<string, string>(str_hash, str_equal);
                calendar_events = new HashTable<string, GenericArray<CalendarService.Event?>>(str_hash, str_equal);

                delete_action = new DeleteCalenderEvent(this);
                edit_title_actions = new HashTable<string, EditCalendarEventTitle>(str_hash, str_equal);
                edit_description_actions = new HashTable<string, EditCalendarEventDescription>(str_hash, str_equal);
            }

            internal bool delete(string cal_name, string uid) {
                if (service == null) error("deleting when not having service!");
                unowned CalendarService.Calendar cal = service.get_calendar(cal_name);
                return cal.delete_event(uid);
            }

            private void on_calendar_changed(ref CalendarService.CalendarInfo cal_info, CalendarService.Event[] new_events) {
                string cal_name = ((string) cal_info.name).dup();
                string color = ((string) cal_info.color).dup();
                time_t now = (time_t) new DateTime.now_local().to_unix();

                var events_array = new GenericArray<CalendarService.Event?>();
                for (int i = 0; i < new_events.length; i++) {
                    if (new_events[i].time.end > now) {
                        events_array.add(new_events[i]);
                    }
                }

                spinlock();
                calendar_colors[cal_name] = color;
                calendar_events[cal_name] = events_array;

                // Create edit actions for this calendar if they don't exist
                if (!edit_title_actions.contains(cal_name)) {
                    edit_title_actions[cal_name] = new EditCalendarEventTitle(this, cal_name, color);
                }
                if (!edit_description_actions.contains(cal_name)) {
                    edit_description_actions[cal_name] = new EditCalendarEventDescription(this, cal_name, color);
                }

                var temp_matches = new GenericArray<CalendarMatch>();

                calendar_events.foreach((calendar_name, cal_events) => {
                    string cal_color = calendar_colors[calendar_name];

                    int count = 0;
                    for (int i = (int)cal_events.length - 1; i >= 0 && count < 10; i--) {
                        var match = new CalendarMatch(
                            cal_events[i],
                            calendar_name,
                            cal_color
                        );
                        temp_matches.add(match);
                        count++;
                    }
                });

                temp_matches.sort((a, b) => {
                    CalendarMatch match_a = (CalendarMatch) a;
                    CalendarMatch match_b = (CalendarMatch) b;
                    return (int)(match_b.event_time.start - match_a.event_time.start);
                });

                agenda = new GenericArray<CalendarMatch>();
                for (uint i = 0; i < temp_matches.length && i < 10; i++) {
                    agenda.add(temp_matches[i]);
                }
                spin_unlock();
            }

            public override bool activate() {
                service = new CalendarService.Service("icloud", on_calendar_changed);
                if (service == null) {
                    return false;
                }

                service.start();
                return true;
            }

            public override void deactivate() {
                if (service != null) {
                    service.stop();
                    service = null;
                }
                calendar_colors.remove_all();
                calendar_events.remove_all();
                edit_title_actions.remove_all();
                edit_description_actions.remove_all();
            }

            public override void find_for_match(Match match, ActionSet rs) {
                var cal_match = match as CalendarMatch;
                if (cal_match != null) {
                    rs.add_action(delete_action);

                    // Add edit actions for this calendar
                    var edit_title = edit_title_actions[cal_match.calendar_name];
                    if (edit_title != null) {
                        rs.add_action(edit_title);
                    }

                    var edit_desc = edit_description_actions[cal_match.calendar_name];
                    if (edit_desc != null) {
                        rs.add_action(edit_desc);
                    }
                    return;
                }

                var cc = match as CalendarMatchCreate;
                if (cc == null) return;

                calendar_events.foreach((cal_name, events) => {
                    string color = calendar_colors[cal_name];
                    rs.add_action(new CalendarActionTarget(this, cal_name, color, cc.summary));
                });
            }

            public static bool is_supported(Match m) {
                return m.get_type() == typeof(CalendarMatchCreate);
            }

            public override void search(ResultContainer rs) {
                spinlock();
                bool query_empty = rs.get_query().char_count() == 0;

                if (query_empty) {
                    for (int i = 0; i < agenda.length; i++) {
                        rs.add_lazy_unique(MatchScore.ABOVE_THRESHOLD, agenda[i].self);
                    }
                } else {
                    calendar_events.foreach((cal_name, events) => {
                        string color = calendar_colors[cal_name];

                        for (int i = 0; i < events.length; i++) {
                            var event = events[i];
                            if (rs.has_match(event.summary)) {
                                rs.add_lazy_unique(MatchScore.ABOVE_THRESHOLD, () => new CalendarMatch(event, cal_name, color));
                            }
                        }
                    });

                    string query = rs.get_query();
                    rs.add_lazy_unique(MatchScore.ABOVE_THRESHOLD, () => new CalendarMatchCreate(query));
                }
                spin_unlock();
            }
        }
    }
}
