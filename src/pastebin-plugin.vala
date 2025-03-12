[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.PastebinPlugin);
}


namespace BobLauncher {
    public class PastebinPlugin : PluginBase {
        construct {
            icon_name = "document-send";
        }

        private static PastebinAction action = new PastebinAction();

        private class PastebinAction: Action {
            private const string PASTE_URL = "https://paste.c-net.org/";

            public override string get_title() { return "Paste to c-net"; }
            public override string get_description() { return "Upload selection to paste.c-net.org"; }
            public override string get_icon_name() { return "document-send"; }

            protected async string? pastebin_file(File file) throws Error {
                string? etag;
                var data = yield file.load_bytes_async(null, out etag);

                return yield pastebin_data(data);
            }


            protected async string? pastebin_text(string content) throws Error {
                var data = new Bytes(content.data);
                return yield pastebin_data(data);
            }

            private async string? pastebin_data(Bytes data) throws Error {
                var req = new Soup.Message("POST", PASTE_URL);
                req.set_request_body_from_bytes("text/plain", data);
                var session = new Soup.Session();

                try {
                    var input_stream = yield session.send_async(req, GLib.Priority.DEFAULT, null);
                    if (req.status_code != Soup.Status.OK) {
                        throw new IOError.FAILED("HTTP Error: %u %s", req.status_code, req.reason_phrase);
                    }

                    var response = yield input_stream.read_bytes_async(int.MAX);
                    return (string)response.get_data();
                } catch (Error e) {
                    throw new IOError.FAILED("Failed to upload to paste.c-net.org: %s", e.message);
                }
            }

            protected virtual void process_pastebin_result(string? url, Match? target = null) {
                string notify_text;
                if (url != null) {
                    Gdk.Display.get_default().get_clipboard().set_text(url);
                    notify_text = "The selection was successfully uploaded and its URL was copied to clipboard.";
                } else {
                    notify_text = "An error occurred during upload, please check the log for more information.";
                }

                try {
                    var notification = new Notify.Notification("BobLauncher - Paste to c-net", notify_text, "BobLauncher");
                    notification.set_timeout(10000);
                    notification.show();
                } catch (Error err) {
                    warning("%s", err.message);
                }
            }

            protected override bool do_execute(Match match, Match? target = null) {
                if (match is IFile) {
                    File file = ((IFile)match).get_file();
                    pastebin_file.begin(file, (obj, res) => {
                        try {
                            string? url = pastebin_file.end(res);
                            process_pastebin_result(url, target);
                        } catch (Error e) {
                            warning("Failed to upload file: %s", e.message);
                            process_pastebin_result(null, target);
                        }
                    });
                    return true;
                } else if (match is ITextMatch) {
                    string content = match.get_text();
                    pastebin_text.begin(content, (obj, res) => {
                        try {
                            string? url = pastebin_text.end(res);
                            process_pastebin_result(url, target);
                        } catch (Error e) {
                            warning("Failed to upload text: %s", e.message);
                            process_pastebin_result(null, target);
                        }
                    });
                    return true;
                } else {
                    return false;
                }
            }

            public override Score get_relevancy(Match match) {
                if (match is ITextMatch) {
                    return MatchScore.AVERAGE;
                }

                if (match is IFile && ContentType.is_a(((IFile)match).get_mime_type(), "text/*")) {
                    return MatchScore.AVERAGE;
                }
                return MatchScore.LOWEST;
            }
        }

        public override void find_for_match(Match match, ActionSet rs) {
            rs.add_action(action);
        }
    }
}
