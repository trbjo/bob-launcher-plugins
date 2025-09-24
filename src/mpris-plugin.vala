[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.MprisPlugin);
}


namespace BobLauncher {
    public class MprisPlugin : SearchBase {
        construct {
            icon_name = "media-playback-start";
        }

        private GLib.DBusConnection connection;

        public override bool activate() {
            try {
                string? address = Environment.get_variable("DBUS_SESSION_BUS_ADDRESS");
                if (address == null) {
                    warning("Could not get session bus address");
                    return false;
                }

                connection = new DBusConnection.for_address_sync(
                    address,
                    DBusConnectionFlags.AUTHENTICATION_CLIENT | DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
                    null,
                    null
                );

                return true;
            } catch (Error e) {
                warning("Failed to establish private D-Bus connection: %s", e.message);
                return false;
            }
        }

        public override void deactivate() {
            if (connection != null) {
                try {
                    connection.close_sync();
                } catch (Error e) {
                    warning("Error closing D-Bus connection: %s", e.message);
                }
            }
        }

        public abstract class MPrisAction : Match {

            public override string get_title() {
                return this.title;
            }

            public override string get_description() {
                return this.description;
            }

            public override string get_icon_name() {
                return this.icon_name;
            }

            public string player_name { get; construct set; }
            public string title { get; construct set; }
            public string description { get; construct set; }
            public string icon_name { get; construct set; }
            public string pretty_name { get; construct set; }
        }


        private class PlayAction : MPrisAction, IActionMatch {
            public PlayAction(string player_name, string pretty_name, string track_info) {
                Object(player_name: player_name, pretty_name: pretty_name,
                       title: "Play " + track_info + " on " + pretty_name,
                       description: "Start playing media on " + pretty_name,
                       icon_name: "media-playback-start");
            }

            public bool do_action() {
                return execute_mpris_action("Play");
            }

            private bool execute_mpris_action(string method) {
                try {
                    // Create private connection for each action
                    string? address = Environment.get_variable("DBUS_SESSION_BUS_ADDRESS");
                    if (address == null) {
                        warning("Could not get session bus address");
                        return false;
                    }

                    var action_connection = new DBusConnection.for_address_sync(
                        address,
                        DBusConnectionFlags.AUTHENTICATION_CLIENT | DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
                        null,
                        null
                    );

                    action_connection.call_sync(
                        player_name,
                        "/org/mpris/MediaPlayer2",
                        "org.mpris.MediaPlayer2.Player",
                        method,
                        null,
                        null,
                        DBusCallFlags.NONE,
                        -1
                    );

                    action_connection.close_sync();
                    return true;
                } catch (Error err) {
                    warning("%s", err.message);
                    return false;
                }
            }
        }

        private class PreviousAction : MPrisAction, IActionMatch {
            public PreviousAction(string player_name, string pretty_name, string track_info) {
                Object(player_name: player_name, pretty_name: pretty_name,
                                title: "Previous " + track_info + " on " + pretty_name,
                                description: "Go back to the previous track on " + pretty_name,
                                icon_name: "media-skip-backward");
            }

            public bool do_action() {
                return execute_mpris_action("Previous");
            }

            private bool execute_mpris_action(string method) {
                try {
                    string? address = Environment.get_variable("DBUS_SESSION_BUS_ADDRESS");
                    if (address == null) return false;

                    var action_connection = new DBusConnection.for_address_sync(
                        address,
                        DBusConnectionFlags.AUTHENTICATION_CLIENT | DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
                        null,
                        null
                    );

                    action_connection.call_sync(
                        player_name,
                        "/org/mpris/MediaPlayer2",
                        "org.mpris.MediaPlayer2.Player",
                        method,
                        null,
                        null,
                        DBusCallFlags.NONE,
                        -1
                    );

                    action_connection.close_sync();
                    return true;
                } catch (Error err) {
                    warning("%s", err.message);
                    return false;
                }
            }
        }

        private class NextAction : MPrisAction, IActionMatch {
            public NextAction(string player_name, string pretty_name, string track_info) {
                Object(player_name: player_name, pretty_name: pretty_name,
                                title: "Next " + track_info + " on " + pretty_name,
                                description: "Skip to the next track on " + pretty_name,
                                icon_name: "media-skip-forward");
            }

            public bool do_action() {
                return execute_mpris_action("Next");
            }

            private bool execute_mpris_action(string method) {
                try {
                    string? address = Environment.get_variable("DBUS_SESSION_BUS_ADDRESS");
                    if (address == null) return false;

                    var action_connection = new DBusConnection.for_address_sync(
                        address,
                        DBusConnectionFlags.AUTHENTICATION_CLIENT | DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
                        null,
                        null
                    );

                    action_connection.call_sync(
                        player_name,
                        "/org/mpris/MediaPlayer2",
                        "org.mpris.MediaPlayer2.Player",
                        method,
                        null,
                        null,
                        DBusCallFlags.NONE,
                        -1
                    );

                    action_connection.close_sync();
                    return true;
                } catch (Error err) {
                    warning("%s", err.message);
                    return false;
                }
            }
        }

        private class PreviousChapter : MPrisAction, IActionMatch {
            public PreviousChapter(string player_name, string pretty_name, string track_info) {
                Object(player_name: player_name, pretty_name: pretty_name,
                                title: "Previous chapter" + track_info + " on " + pretty_name,
                                description: "Skip to the previous chapter on " + pretty_name,
                                icon_name: "media-skip-backward");
            }

            public bool do_action() {
                return execute_mpris_action("PreviousChapter");
            }

            private bool execute_mpris_action(string method) {
                try {
                    string? address = Environment.get_variable("DBUS_SESSION_BUS_ADDRESS");
                    if (address == null) return false;

                    var action_connection = new DBusConnection.for_address_sync(
                        address,
                        DBusConnectionFlags.AUTHENTICATION_CLIENT | DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
                        null,
                        null
                    );

                    action_connection.call_sync(
                        player_name,
                        "/org/mpris/MediaPlayer2",
                        "org.mpris.MediaPlayer2.Player",
                        method,
                        null,
                        null,
                        DBusCallFlags.NONE,
                        -1
                    );

                    action_connection.close_sync();
                    return true;
                } catch (Error err) {
                    warning("%s", err.message);
                    return false;
                }
            }
        }

        private class NextChapter : MPrisAction, IActionMatch {
            public NextChapter(string player_name, string pretty_name, string track_info) {
                Object(player_name: player_name, pretty_name: pretty_name,
                                title: "Next chapter" + track_info + " on " + pretty_name,
                                description: "Skip to the next chapter on " + pretty_name,
                                icon_name: "media-skip-forward");
            }

            public bool do_action() {
                return execute_mpris_action("NextChapter");
            }

            private bool execute_mpris_action(string method) {
                try {
                    string? address = Environment.get_variable("DBUS_SESSION_BUS_ADDRESS");
                    if (address == null) return false;

                    var action_connection = new DBusConnection.for_address_sync(
                        address,
                        DBusConnectionFlags.AUTHENTICATION_CLIENT | DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
                        null,
                        null
                    );

                    action_connection.call_sync(
                        player_name,
                        "/org/mpris/MediaPlayer2",
                        "org.mpris.MediaPlayer2.Player",
                        method,
                        null,
                        null,
                        DBusCallFlags.NONE,
                        -1
                    );

                    action_connection.close_sync();
                    return true;
                } catch (Error err) {
                    warning("%s", err.message);
                    return false;
                }
            }
        }

        private class StopAction : MPrisAction, IActionMatch {
            public StopAction(string player_name, string pretty_name, string track_info) {
                Object(player_name: player_name, pretty_name: pretty_name,
                                title: "Stop " + track_info + " on " + pretty_name,
                                description: "Stop the current track " + pretty_name,
                                icon_name: "media-playback-stop");
            }

            public bool do_action() {
                return execute_mpris_action("Stop");
            }

            private bool execute_mpris_action(string method) {
                try {
                    string? address = Environment.get_variable("DBUS_SESSION_BUS_ADDRESS");
                    if (address == null) return false;

                    var action_connection = new DBusConnection.for_address_sync(
                        address,
                        DBusConnectionFlags.AUTHENTICATION_CLIENT | DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
                        null,
                        null
                    );

                    action_connection.call_sync(
                        player_name,
                        "/org/mpris/MediaPlayer2",
                        "org.mpris.MediaPlayer2.Player",
                        method,
                        null,
                        null,
                        DBusCallFlags.NONE,
                        -1
                    );

                    action_connection.close_sync();
                    return true;
                } catch (Error err) {
                    warning("%s", err.message);
                    return false;
                }
            }
        }


        private class PauseAction : MPrisAction, IActionMatch {
            public PauseAction(string player_name, string pretty_name, string track_info) {
                Object(player_name: player_name, pretty_name: pretty_name,
                       title: "Pause " + track_info + " on " + pretty_name,
                       description: "Pause media playback on " + pretty_name,
                       icon_name: "media-playback-pause");
            }

            public bool do_action() {
                return execute_mpris_action("Pause");
            }

            private bool execute_mpris_action(string method) {
                try {
                    string? address = Environment.get_variable("DBUS_SESSION_BUS_ADDRESS");
                    if (address == null) return false;

                    var action_connection = new DBusConnection.for_address_sync(
                        address,
                        DBusConnectionFlags.AUTHENTICATION_CLIENT | DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
                        null,
                        null
                    );

                    action_connection.call_sync(
                        this.player_name,
                        "/org/mpris/MediaPlayer2",
                        "org.mpris.MediaPlayer2.Player",
                        method,
                        null,
                        null,
                        DBusCallFlags.NONE,
                        -1
                    );

                    action_connection.close_sync();
                    return true;
                } catch (Error err) {
                    warning("%s", err.message);
                    return false;
                }
            }
        }


        private GenericArray<MPrisAction> get_mpris_actions() {
            var actions = new GenericArray<MPrisAction>();
            try {
                var reply = this.connection.call_sync("org.freedesktop.DBus", "/", "org.freedesktop.DBus",
                                                 "ListNames", null, null, DBusCallFlags.NONE, -1);
                var names = (string[])reply.get_child_value(0);
                foreach (var player_name in names) {
                    if (player_name.has_prefix("org.mpris.MediaPlayer2.")) {
                        string pretty_name = get_player_pretty_name(connection, player_name);

                        var playback_status = get_player_playback_status(connection, player_name);
                        string track_info = get_current_track_info(connection, player_name);

                        if (get_can_go(connection, player_name, "CanGoNext")) {
                            actions.add(new NextAction(player_name, pretty_name, track_info));
                        }

                        if (get_can_go(connection, player_name, "CanGoPrevious")) {
                            actions.add(new PreviousAction(player_name, pretty_name, track_info));
                        }

                        if (playback_status == "Playing") {
                            actions.add(new PauseAction(player_name, pretty_name, track_info));
                            actions.add(new StopAction(player_name, pretty_name, track_info));
                        } else if (playback_status == "Paused") {
                            actions.add(new PlayAction(player_name, pretty_name, track_info));
                            actions.add(new StopAction(player_name, pretty_name, track_info));
                        } else if (playback_status == "Stopped") {
                            actions.add(new PlayAction(player_name, pretty_name, track_info));
                        }
                    }
                }
            } catch (Error err) {
                warning("%s", err.message);
            }
            return actions;
        }

        private bool get_can_go(GLib.DBusConnection connection, string player_name, string action) {
            try {
                var reply = connection.call_sync(
                    player_name,
                    "/org/mpris/MediaPlayer2",
                    "org.freedesktop.DBus.Properties",
                    "Get",
                    new Variant("(ss)", "org.mpris.MediaPlayer2.Player", action),
                    new VariantType("(v)"),
                    DBusCallFlags.NONE,
                    -1
                );
                return reply.get_child_value(0).get_child_value(0).get_boolean();
            } catch (Error e) {
                warning("Failed to get %s property for player %s: %s", action, player_name, e.message);
                return false;
            }
        }

        private string? get_player_playback_status(GLib.DBusConnection connection, string player_name) {
            try {
                var reply = connection.call_sync(
                    player_name,
                    "/org/mpris/MediaPlayer2",
                    "org.freedesktop.DBus.Properties",
                    "Get",
                    new Variant("(ss)", "org.mpris.MediaPlayer2.Player", "PlaybackStatus"),
                    new VariantType("(v)"),
                    DBusCallFlags.NONE,
                    -1
                );
                return reply.get_child_value(0).get_child_value(0).get_string();
            } catch (Error e) {
                warning("Failed to get playback status for player %s: %s", player_name, e.message);
                return null;
            }
        }

        private string get_current_track_info(GLib.DBusConnection connection, string player_name) {
            try {
                var reply = connection.call_sync(
                    player_name,
                    "/org/mpris/MediaPlayer2",
                    "org.freedesktop.DBus.Properties",
                    "Get",
                    new Variant("(ss)", "org.mpris.MediaPlayer2.Player", "Metadata"),
                    new VariantType("(v)"),
                    DBusCallFlags.NONE,
                    -1
                );
                var metadata = reply.get_child_value(0).get_child_value(0);

                var title_variant = metadata.lookup_value("xesam:title", VariantType.STRING);
                string? title = title_variant != null ? title_variant.get_string() : null;
                var artist_variant = metadata.lookup_value("xesam:artist", new VariantType("as"));
                string? artist = artist_variant != null ? artist_variant.get_strv()[0] : null;
                if (title != null && artist != null) {
                    return title + " – " + artist;
                } else if (title != null && artist == null) {
                    return title;
                } else if (title == null && artist != null) {
                    return artist;
                }
            } catch (Error e) {
                warning("Failed to get current track info for player %s: %s", player_name, e.message);
            }
            return "";
        }

        private string get_player_pretty_name(GLib.DBusConnection connection, string player_name) {
            try {
                var reply = connection.call_sync(
                    player_name,
                    "/org/mpris/MediaPlayer2",
                    "org.freedesktop.DBus.Properties",
                    "Get",
                    new Variant("(ss)", "org.mpris.MediaPlayer2", "Identity"),
                    new VariantType("(v)"),
                    DBusCallFlags.NONE,
                    -1,
                    null
                );

                var temp_name = reply.get_child_value(0).get_child_value(0).get_string();
                return temp_name ?? player_name;
            } catch (Error e) {
                warning("Failed to get pretty name for player %s: %s", player_name, e.message);
                return player_name;
            }
        }

        public override void search(ResultContainer rs) {
            var actions = get_mpris_actions();
            if (rs.is_cancelled()) return;
            foreach (var action in actions) {
                Score score;
                if (rs.has_match(action.get_title())) {
                    score = rs.match_score(action.get_title()) * MatchScore.INCREMENT_HUGE;
                } else if (rs.has_match(action.pretty_name)) {
                    score = rs.match_score(action.pretty_name) * MatchScore.INCREMENT_HUGE;
                } else {
                    continue;
                }

                rs.add_lazy_unique(score, () => action);
            }
        }
    }
}
