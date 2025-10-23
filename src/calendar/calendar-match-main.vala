namespace BobLauncher {
    namespace Calendar {
        internal class CalendarMatch : Match, IRichIcon, IRichDescription {
            internal CalendarIcon? _icon = null;
            internal string calendar_color;
            internal string calendar_name;
            private Description? rich_description = null;

            internal CalendarService.CalendarEventTime event_time;
            internal string? location;
            internal string? uid;
            internal string? description;
            internal string? url;

            public unowned Gtk.Widget get_rich_icon() {
                if (_icon == null) {
                    _icon = new CalendarIcon();
                    Gdk.RGBA color = Gdk.RGBA();
                    color.parse(calendar_color ?? "#4CAF50");
                    var dt = new GLib.DateTime.from_unix_local(event_time.start);
                    _icon.set_date(dt, color);
                }
                return _icon;
            }

            private Gtk.Widget? _tooltip_widget = null;

            public override unowned Gtk.Widget? get_tooltip() {
                if (_tooltip_widget == null && this.description != null) {
                    _tooltip_widget = new CalendarEventTooltip(description);
                }
                return _tooltip_widget;
            }

            public unowned Description get_rich_description(Levensteihn.StringInfo si) {
                if (rich_description == null) {
                    rich_description = generate_calendar_description();
                }
                return rich_description;
            }

            private static string pluralize(int64 n, string singular, string plural) {
                return n == 1 ? @"1 $(singular)" : @"$(n) $(plural)";
            }

            private static string format_duration(CalendarService.CalendarEventTime event_time) {
                if (event_time.start == 0) {
                    return "Unknown duration";
                }

                time_t end = event_time.end;

                // Handle missing or invalid end time per iCalendar spec
                if (end == 0 || end <= event_time.start) {
                    if (event_time.is_all_day) {
                        // All-day events without DTEND span 1 day
                        end = event_time.start + 86400;
                    } else {
                        // Timed events without DTEND are instants
                        return "Instant";
                    }
                }

                int64 duration_seconds = end - event_time.start;
                int64 days = duration_seconds / 86400;

                if (event_time.is_all_day) {
                    days -= 1;  // End date is exclusive for all-day events
                    return days == 0 ? "All day" : pluralize(days, "day", "days");
                }

                // Timed events: use most appropriate unit
                if (days >= 1) return pluralize(days, "day", "days");

                int64 hours = duration_seconds / 3600;
                if (hours >= 1) return pluralize(hours, "hour", "hours");

                int64 minutes = duration_seconds / 60;
                return pluralize(minutes, "minute", "minutes");
            }

            private Description generate_calendar_description() {
                var root = new Description.container("calendar-description", Gtk.Orientation.HORIZONTAL);

                var start = new DateTime.from_unix_local(event_time.start);

                time_t end_time = event_time.end;
                if (end_time == 0 || end_time <= event_time.start) {
                    if (event_time.is_all_day) {
                        end_time = event_time.start + 86400;
                    } else {
                        end_time = event_time.start;
                    }
                }

                var end = new DateTime.from_unix_local(end_time);

                // For all-day events, end date is exclusive - subtract one day
                if (event_time.is_all_day) {
                    end = end.add_days(-1);
                }

                bool is_multi_day = start.format("%Y-%m-%d") != end.format("%Y-%m-%d");

                var time_group = new Description.container("time-group", Gtk.Orientation.HORIZONTAL);

                string icon_name = is_multi_day ? "x-office-calendar-symbolic" : "appointment-new-symbolic";
                var time_icon = new Description(icon_name, "image", FragmentType.IMAGE);
                time_group.add_child(time_icon);

                string time_text = format_time_range(event_time);
                var time_desc = new Description(time_text, "time-text", FragmentType.TEXT);
                time_group.add_child(time_desc);

                root.add_child(time_group);

                var duration_container = new Description.container("duration-container");
                string duration_text = format_duration(event_time);
                var duration_badge = new Description(duration_text, "duration-badge", FragmentType.TEXT);
                duration_container.add_child(duration_badge);
                root.add_child(duration_container);

                if (location != null && location.length > 0) {
                    string maps_url = @"https://maps.apple.com/?q=$(Uri.escape_string(location))";
                    var loc_icon = new Description("mark-location-symbolic", "location-icon", FragmentType.IMAGE);

                    var location_group = new Description.container("location-group", Gtk.Orientation.HORIZONTAL);
                    location_group.add_child(loc_icon);

                    var loc_text = new Description(location, "location-text", FragmentType.TEXT,
                                                   () => BobLaunchContext.get_instance().launch_uri(maps_url), null);
                    location_group.add_child(loc_text);
                    root.add_child(location_group);
                }

                if (url != null && url.length > 0) {
                    var url_group = new Description.container("url-group", Gtk.Orientation.HORIZONTAL);
                    var url_icon = new Description("adw-external-link-symbolic", "image", FragmentType.IMAGE);
                    var url_text = new Description(url, "location-text", FragmentType.TEXT, () => BobLaunchContext.get_instance().launch_uri(url), null);

                    url_group.add_child(url_icon);
                    url_group.add_child(url_text);
                    root.add_child(url_group);
                }

                return root;
            }

            private static string format_day_prefix(DateTime dt) {
                var now = new DateTime.now_local();

                // Normalize to midnight for proper day comparison
                var dt_date = new DateTime.local(dt.get_year(), dt.get_month(), dt.get_day_of_month(), 0, 0, 0);
                var now_date = new DateTime.local(now.get_year(), now.get_month(), now.get_day_of_month(), 0, 0, 0);

                int days_until = (int)((dt_date.to_unix() - now_date.to_unix()) / 86400);

                if (days_until == 0) {
                    return "Today";
                } else if (days_until == 1) {
                    return "Tomorrow";
                } else if (days_until > 1 && days_until < 7) {
                    return dt.format("%A"); // Day name
                } else {
                    return dt.format("%b %d");
                }
            }

            private static string format_time_range(CalendarService.CalendarEventTime event_time) {
                if (event_time.start == 0) {
                    return "Unknown time";
                }

                var start = new DateTime.from_unix_local(event_time.start);

                time_t end_time = event_time.end;
                if (end_time == 0 || end_time <= event_time.start) {
                    if (event_time.is_all_day) {
                        end_time = event_time.start + 86400;
                    } else {
                        end_time = event_time.start;
                    }
                }

                var end = new DateTime.from_unix_local(end_time);

                // For all-day events, end date is exclusive - subtract one day for display
                if (event_time.is_all_day) {
                    end = end.add_days(-1);
                }

                bool is_multi_day = start.format("%Y-%m-%d") != end.format("%Y-%m-%d");

                if (event_time.is_all_day) {
                    if (is_multi_day) {
                        return @"$(format_day_prefix(start)) – $(format_day_prefix(end))";
                    } else {
                        return format_day_prefix(start);
                    }
                }

                if (is_multi_day) {
                    return @"$(format_day_prefix(start)) $(start.format("%H:%M")) – $(format_day_prefix(end)) $(end.format("%H:%M"))";
                }

                return @"$(format_day_prefix(start)) $(start.format("%H:%M")) – $(end.format("%H:%M"))";
            }

            internal CalendarMatch self() {
                return this;
            }

            private string title;
            public override string get_title() {
                return title;
            }

            public override string get_description() {
                assert_not_reached();
            }

            public override string get_icon_name() {
                return "calendar";
            }

            public CalendarMatch(CalendarService.Event event, string calendar_name, string calendar_color) {
                Object();
                title = event.summary;
                description = event.description;
                this.calendar_name = calendar_name;
                this.calendar_color = calendar_color;

                event_time = event.time;

                // Copy location if present, replacing newlines with commas
                location = (event.location != null && event.location.length > 0) ?
                          event.location.replace("\n", ", ") : null;

                uid = event.uid;

                url = (event.url != null && event.url.length > 0) ? event.url : null;
            }
        }
    }
}
