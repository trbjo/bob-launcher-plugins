[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.UrlShortenerPlugin);
}


namespace BobLauncher {
    public class UrlShortenerPlugin : PluginBase {
        public const string success_msg = "The selection was successfully uploaded and its URL was copied to clipboard.";
        public const string error_msg = "An error occurred during upload, please check the log for more information.";

        private class ShortenUrl : Action {
            protected override bool do_execute(Match match, Match? target = null) {
                if (match is IURLMatch) {
                    shorten_url.begin(((IURLMatch)match).get_url());
                    return true;
                }
                return false;
            }

            public override Score get_relevancy(Match m) {
                if (m is IURLMatch) {
                    return MatchScore.AVERAGE;
                }
                return MatchScore.LOWEST;
            }

            public override string get_title() {
                return "Shorten URL";
            }
            public override string get_description() {
                return "Shorten the provided URL";
            }
            public override string get_icon_name() {
                return "edit-cut-symbolic";
            }

            private async void shorten_url(string url) {
                var session = new Soup.Session();
                var message = new Soup.Message("GET", "https://is.gd/create.php?format=simple&url=" + Uri.escape_string(url));
                bool success = false;

                try {
                    var input_stream = yield session.send_async(message, GLib.Priority.DEFAULT, null);
                    var data_input_stream = new DataInputStream(input_stream);
                    var shortened_url = yield data_input_stream.read_line_async();

                    if (message.status_code == 200 && shortened_url != null) {
                        Gdk.Display.get_default().get_clipboard().set_text(shortened_url);
                        success = true;
                    } else {
                        warning("Failed to shorten URL");
                    }
                } catch (Error e) {
                    warning("Error shortening URL: %s", e.message);
                }
                notify_user("URL Shortener", success ? success_msg : error_msg);
            }
        }

        public static void notify_user(string title, string msg) {
            try {
                var notification = new Notify.Notification(title, msg, BOB_LAUNCHER_APP_ID);
                notification.set_timeout(10000);
                notification.show();
            } catch (Error err) {
                warning("%s", err.message);
            }
        }

        private static ShortenUrl action;

        static construct {
            action = new ShortenUrl();
        }

        construct {
            Notify.init(BOB_LAUNCHER_APP_ID);
            icon_name = "insert-link";
        }

        public override void find_for_match(Match match, ActionSet rs) {
            rs.add_action(action);
        }
    }
}
