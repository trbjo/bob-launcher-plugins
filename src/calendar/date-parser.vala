namespace BobLauncher {
    namespace Calendar {
        namespace Utils {
            internal const string[] DAYS = {
                "sunday", "monday", "tuesday", "wednesday",
                "thursday", "friday", "saturday"
            };

            // Locale-aware month names will be loaded at runtime
            private static string[]? month_names_long = null;
            private static string[]? month_names_short = null;

            private static void init_locale_months() {
                if (month_names_long != null) return;

                month_names_long = new string[12];
                month_names_short = new string[12];

                for (int i = 0; i < 12; i++) {
                    var date = new DateTime.local(2025, i + 1, 1, 0, 0, 0);
                    month_names_long[i] = date.format("%B").down();
                    month_names_short[i] = date.format("%b").down();
                }
            }

            private static int skip_separators(string str, int pos) {
                while (pos < str.length) {
                    unichar c = str.get_char(pos);
                    if (!c.isspace() && c != '-' && c != ',' && c != ':') {
                        break;
                    }
                    pos = str.index_of_nth_char(str.char_count(pos) + 1);
                }
                return pos;
            }

            private static void parse_date(string query, int start_pos, out int consumed, out DateTime? result) {
                consumed = 0;
                result = null;

                if (start_pos >= query.length) return;

                var remaining = query.substring(start_pos);
                var lower = remaining.down();
                var now = new DateTime.now_local();

                // Try keywords
                if (lower.has_prefix("today")) {
                    result = new DateTime.local(now.get_year(), now.get_month(), now.get_day_of_month(), 0, 0, 0);
                    consumed = "today".length;
                    return;
                }

                if (lower.has_prefix("tomorrow")) {
                    var tomorrow = now.add_days(1);
                    result = new DateTime.local(tomorrow.get_year(), tomorrow.get_month(), tomorrow.get_day_of_month(), 0, 0, 0);
                    consumed = "tomorrow".length;
                    return;
                }

                if (lower.has_prefix("tonight")) {
                    result = new DateTime.local(now.get_year(), now.get_month(), now.get_day_of_month(), 0, 0, 0);
                    consumed = "tonight".length;
                    return;
                }

                // Try day names
                foreach (var day in DAYS) {
                    if (lower.has_prefix(day)) {
                        int target_day = -1;
                        for (int i = 0; i < DAYS.length; i++) {
                            if (DAYS[i] == day) {
                                target_day = i;
                                break;
                            }
                        }

                        int current_day = now.get_day_of_week() % 7;
                        int days_ahead = (target_day - current_day + 7) % 7;
                        if (days_ahead == 0) days_ahead = 7;

                        var target_date = now.add_days(days_ahead);
                        result = new DateTime.local(
                            target_date.get_year(),
                            target_date.get_month(),
                            target_date.get_day_of_month(),
                            0, 0, 0
                        );
                        consumed = day.length;
                        return;
                    }
                }

                // Try month + day (e.g., "oct 7", "7 oct")
                MatchInfo match_info;
                try {
                    // "7 oct" or "oct 7"
                    var regex = new Regex("^([0-9]{1,2})\\s+([a-z]+)|^([a-z]+)\\s+([0-9]{1,2})", RegexCompileFlags.CASELESS);
                    if (regex.match(lower, 0, out match_info)) {
                        int day = 0;
                        string month_str = null;

                        if (match_info.fetch(1) != null && match_info.fetch(1).length > 0) {
                            day = int.parse(match_info.fetch(1));
                            month_str = match_info.fetch(2);
                        } else {
                            month_str = match_info.fetch(3);
                            day = int.parse(match_info.fetch(4));
                        }

                        int month = parse_month_name(month_str);
                        if (month > 0 && day >= 1 && day <= 31) {
                            var year = now.get_year();
                            result = new DateTime.local(year, month, day, 0, 0, 0);
                            consumed = match_info.fetch(0).length;
                            return;
                        }
                    }
                } catch (RegexError e) {
                    warning("Regex error: %s", e.message);
                }

                // Try full numeric date with year (e.g., "22.08.2026", "22/08/2026", "2026-08-22")
                try {
                    var regex = new Regex("^([0-9]{1,4})[/.-]([0-9]{1,2})[/.-]([0-9]{1,4})");
                    if (regex.match(lower, 0, out match_info)) {
                        int num1 = int.parse(match_info.fetch(1));
                        int num2 = int.parse(match_info.fetch(2));
                        int num3 = int.parse(match_info.fetch(3));

                        int day, month, year;

                        // Determine which number is the year (the one with 4 digits or > 31)
                        if (num1 > 31 || match_info.fetch(1).length == 4) {
                            // Format: YYYY-MM-DD or YYYY/MM/DD or YYYY.MM.DD
                            year = num1;
                            month = num2;
                            day = num3;
                        } else if (num3 > 31 || match_info.fetch(3).length == 4) {
                            // Format: DD-MM-YYYY or DD/MM/YYYY or DD.MM.YYYY (or MM-DD-YYYY)
                            bool day_first = is_locale_day_first();
                            day = day_first ? num1 : num2;
                            month = day_first ? num2 : num1;
                            year = num3;
                        } else {
                            // No year found, skip this match
                            return;
                        }

                        if (month >= 1 && month <= 12 && day >= 1 && day <= 31 && year >= 1900 && year <= 9999) {
                            result = new DateTime.local(year, month, day, 0, 0, 0);
                            consumed = match_info.fetch(0).length;
                            return;
                        }
                    }
                } catch (RegexError e) {
                    warning("Regex error: %s", e.message);
                }

                // Try numeric date without year (e.g., "6/10", "10-6", "22.08")
                try {
                    var regex = new Regex("^([0-9]{1,2})[/.-]([0-9]{1,2})");
                    if (regex.match(lower, 0, out match_info)) {
                        int num1 = int.parse(match_info.fetch(1));
                        int num2 = int.parse(match_info.fetch(2));

                        bool day_first = is_locale_day_first();
                        int day = day_first ? num1 : num2;
                        int month = day_first ? num2 : num1;

                        if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
                            var year = now.get_year();
                            result = new DateTime.local(year, month, day, 0, 0, 0);
                            consumed = match_info.fetch(0).length;
                            return;
                        }
                    }
                } catch (RegexError e) {
                    warning("Regex error: %s", e.message);
                }
            }

            private static void parse_time(string query, int start_pos, out int consumed, out int hour, out int minute) {
                consumed = 0;
                hour = 0;
                minute = 0;

                if (start_pos >= query.length) return;

                var remaining = query.substring(start_pos);
                var lower = remaining.down();

                MatchInfo match_info;
                try {
                    // Match "2:30pm", "14:30", "2pm", etc.
                    var regex = new Regex("^([0-9]{1,2}):([0-9]{2})\\s*(am|pm)?|^([0-9]{1,2})\\s*(am|pm)", RegexCompileFlags.CASELESS);
                    if (regex.match(lower, 0, out match_info)) {
                        string hour_str;
                        string minute_str = null;
                        string period = null;

                        if (match_info.fetch(1) != null && match_info.fetch(1).length > 0) {
                            // Format with colon
                            hour_str = match_info.fetch(1);
                            minute_str = match_info.fetch(2);
                            period = match_info.fetch(3);
                        } else {
                            // Format without colon
                            hour_str = match_info.fetch(4);
                            period = match_info.fetch(5);
                        }

                        hour = int.parse(hour_str);
                        if (minute_str != null && minute_str.length > 0) {
                            minute = int.parse(minute_str);
                        }

                        if (period != null) {
                            var period_lower = period.down();
                            if (period_lower == "pm" && hour < 12) {
                                hour += 12;
                            } else if (period_lower == "am" && hour == 12) {
                                hour = 0;
                            }
                        }

                        consumed = match_info.fetch(0).length;
                    }
                } catch (RegexError e) {
                    warning("Regex error: %s", e.message);
                }
            }

            internal static void parse_datetime_range(string query, out DateTime? start, out DateTime? end, out int consumed) {
                init_locale_months();

                start = null;
                end = null;
                consumed = 0;

                DateTime? start_date = null;
                int start_hour = -1;
                int start_minute = 0;

                DateTime? end_date = null;
                int end_hour = -1;
                int end_minute = 0;

                var now = new DateTime.now_local();
                int pos = 0;

                // State machine: parse in order
                // 1. start date
                // 2. start time
                // 3. end date
                // 4. end time

                while (pos < query.length) {
                    pos = skip_separators(query, pos);
                    if (pos >= query.length) break;

                    int chars_consumed;

                    if (start_date == null) {
                        parse_date(query, pos, out chars_consumed, out start_date);
                        if (chars_consumed > 0) {
                            pos += chars_consumed;
                            continue;
                        }
                    }

                    if (start_hour == -1) {
                        int h, m;
                        parse_time(query, pos, out chars_consumed, out h, out m);
                        if (chars_consumed > 0) {
                            start_hour = h;
                            start_minute = m;
                            pos += chars_consumed;
                            continue;
                        }
                    }

                    if (end_date == null) {
                        parse_date(query, pos, out chars_consumed, out end_date);
                        if (chars_consumed > 0) {
                            pos += chars_consumed;
                            continue;
                        }
                    }

                    if (end_hour == -1) {
                        int h, m;
                        parse_time(query, pos, out chars_consumed, out h, out m);
                        if (chars_consumed > 0) {
                            end_hour = h;
                            end_minute = m;
                            pos += chars_consumed;
                            continue;
                        }
                    }

                    // Nothing matched, stop parsing
                    break;
                }

                // Record how many characters we consumed
                consumed = pos;

                // Build final DateTimes with inheritance logic
                if (start_date == null) return;

                // Apply next occurrence logic to start date
                if (start_date.compare(now) < 0) {
                    start_date = start_date.add_years(1);
                }

                // Build start datetime
                if (start_hour >= 0) {
                    start = new DateTime.local(
                        start_date.get_year(),
                        start_date.get_month(),
                        start_date.get_day_of_month(),
                        start_hour, start_minute, 0
                    );
                } else {
                    start = start_date;
                }

                // Build end datetime with inheritance
                bool has_end = (end_date != null || end_hour >= 0);

                if (!has_end) {
                    // No end specified
                    if (start_hour >= 0) {
                        // Has time - default to +1 hour
                        end = start.add_hours(1);
                    } else {
                        // No time - all day (same day)
                        end = start;
                    }
                } else {
                    // End specified - apply inheritance
                    DateTime base_end_date;

                    if (end_date != null) {
                        // Apply next occurrence to end date if needed
                        base_end_date = end_date;
                        if (base_end_date.compare(now) < 0) {
                            base_end_date = base_end_date.add_years(1);
                        }
                    } else {
                        // No end date - inherit from start
                        base_end_date = start_date;
                    }

                    int final_hour, final_minute;
                    if (end_hour >= 0) {
                        // End has explicit time
                        final_hour = end_hour;
                        final_minute = end_minute;
                    } else if (start_hour >= 0 && end_date != null) {
                        // End has date but no time, start has time - inherit time
                        final_hour = start_hour;
                        final_minute = start_minute;
                    } else {
                        // No time specified
                        final_hour = 0;
                        final_minute = 0;
                    }

                    end = new DateTime.local(
                        base_end_date.get_year(),
                        base_end_date.get_month(),
                        base_end_date.get_day_of_month(),
                        final_hour, final_minute, 0
                    );
                }
            }


            private static bool is_locale_day_first() {
                var locale = Environment.get_variable("LC_TIME") ?? Environment.get_variable("LANG") ?? "";

                if (locale.has_prefix("en_US") || locale.has_prefix("en_CA")) {
                    return false;
                }

                return true;
            }

            private static int parse_month_name(string text) {

                var lower = text.down();

                for (int i = 0; i < 12; i++) {
                    if (month_names_long[i] == lower) {
                        return i + 1;
                    }
                }

                for (int i = 0; i < 12; i++) {
                    if (month_names_short[i] == lower || lower.has_prefix(month_names_short[i])) {
                        return i + 1;
                    }
                }

                return 0;
            }
        }
    }
}
