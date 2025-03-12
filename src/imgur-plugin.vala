[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.ImgurPlugin);
}


namespace BobLauncher {
    errordomain UploadError {
        LIMIT_REACHED,
        UNKNOWN_ERROR
    }

    public class ImgurPlugin : PluginBase {
        construct {
            icon_name = "image";
        }

        public string client_id { get; set; default = ""; }
        private ImgUrAction action;

        public override void on_setting_initialized(string key, GLib.Variant value) {
            if (key == "client-id") {
                client_id = value.get_string();
                if (action != null)  {
                    action.update_client_id(client_id);
                }
            }
        }

        public override SettingsCallback? on_setting_changed(string key, GLib.Variant value) {
            if (key == "client-id") {
                return (cancellable) => {
                    client_id = value.get_string();
                    if (action != null)  {
                        action.update_client_id(client_id);
                    }
                };
            }
            return null;
        }

        protected override bool activate(Cancellable current_cancellable) {
            action = new ImgUrAction(client_id);
            return true;
        }

        protected override void deactivate() {
            action = null;
        }

        private class ImgUrAction: Action {
            private string client_id;

            public override string get_title() {
                return "Upload to imgur";
            }

            public override string get_description() {
                return "Upload selection to imgur image sharer";
            }

            public override string get_icon_name() {
                return "image";
            }

            public override Score get_relevancy(Match match) {
                if (!(match is IFile)) {
                    return MatchScore.LOWEST;
                }

                if (ContentType.is_a(((IFile)match).get_mime_type(), "image/*")) {
                    return MatchScore.AVERAGE;
                }
                if (ContentType.is_a(((IFile)match).get_mime_type(), "video/*")) {
                    return MatchScore.AVERAGE;
                }
                return MatchScore.LOWEST;
            }


            public ImgUrAction(string client_id) {
                this.client_id = client_id;
            }

            private Soup.Session session;

            construct {
                session = new Soup.Session();
                session.timeout = 30;
                session.idle_timeout = 30;
            }

            public void update_client_id(string new_client_id) {
                this.client_id = new_client_id;
            }

            private async string? upload_file(File file) throws Error {
                try {
                    var file_info = yield file.query_info_async(
                        FileAttribute.STANDARD_CONTENT_TYPE,
                        FileQueryInfoFlags.NONE
                    );
                    var content_type = file_info.get_content_type();
                    var is_video = content_type.has_prefix("video/");

                    var input = yield file.read_async(Priority.DEFAULT, null);
                    var bytes = yield input.read_bytes_async(10 * 1024 * 1024);

                    var msg = new Soup.Message("POST", "https://api.imgur.com/3/upload");
                    msg.request_headers.append("Authorization", "Client-ID %s".printf(client_id));

                    var multipart = new Soup.Multipart(Soup.FORM_MIME_TYPE_MULTIPART);

                    if (is_video) {
                        multipart.append_form_file("video", file.get_path(), content_type, new GLib.Bytes(bytes.get_data()));
                    } else {
                        var encoded = yield base64_encode_file(input);
                        multipart.append_form_string("image", encoded);
                    }

                    GLib.Bytes body;
                    multipart.to_message(msg.get_request_headers(), out body);
                    msg.set_request_body_from_bytes(null, body);

                    var input_stream = yield session.send_async(msg, GLib.Priority.DEFAULT, null);

                    if (msg.status_code != Soup.Status.OK) {
                        throw new UploadError.UNKNOWN_ERROR(@"HTTP Error: $(msg.status_code) $(msg.reason_phrase)");
                    }

                    var parser = new Json.Parser();
                    yield parser.load_from_stream_async(input_stream, null);

                    var root = parser.get_root().get_object();

                    if (root != null && root.get_boolean_member("success")) {
                        var data_obj = root.get_object_member("data");
                        return data_obj.get_string_member("link");
                    } else {
                        throw new UploadError.UNKNOWN_ERROR("Upload failed: " + (root != null ? root.get_string_member("data") : "Unknown error"));
                    }
                } catch (Error e) {
                    throw new UploadError.UNKNOWN_ERROR(e.message);
                }
            }

            private async string base64_encode_file(InputStream input) throws Error {
                int chunk_size = 128*1024;
                uint8[] buffer = new uint8[chunk_size];
                char[] encode_buffer = new char[(chunk_size / 3 + 1) * 4 + 4];
                size_t read_bytes;
                int state = 0;
                int save = 0;
                var encoded = new StringBuilder();

                read_bytes = yield input.read_async(buffer);
                while (read_bytes != 0) {
                    buffer.length = (int)read_bytes;
                    size_t enc_len = Base64.encode_step((uchar[])buffer, false, encode_buffer,
                                                        ref state, ref save);
                    encoded.append_len((string)encode_buffer, (ssize_t)enc_len);
                    read_bytes = yield input.read_async(buffer);
                }
                size_t enc_close = Base64.encode_close(false, encode_buffer, ref state, ref save);
                encoded.append_len((string)encode_buffer, (ssize_t)enc_close);

                return encoded.str;
            }


            protected virtual void process_result(string? url, Match? target = null) {
                string msg;
                if (url != null) {
                    Gdk.Display.get_default().get_clipboard().set_text(url);
                    msg = "The selection was successfully uploaded and its URL was copied to clipboard.";
                } else {
                    msg = "An error occurred during upload, please check the log for more information.";
                }

                try {
                    var notification = new Notify.Notification("BobLauncher - Imgur", msg + url, "BobLauncher");
                    notification.set_timeout(10000);
                    notification.show();
                } catch (Error err) {
                    warning("%s", err.message);
                }
            }

            protected override bool do_execute(Match match, Match? target = null) {
                if (!(match is IFile)) {
                    return false;
                }
                unowned IFile uri_match = (IFile)match;

                upload_file.begin(uri_match.get_file(), (obj, res) => {
                    string? url = null;
                    try {
                        url = upload_file.end(res);
                    } catch (Error err) {
                        warning ("%s", err.message);
                    }

                    process_result(url, target);
                });
                return true;
            }
        }

        public override void find_for_match(Match match, ActionSet rs) {
            rs.add_action(action);
        }
    }
}
