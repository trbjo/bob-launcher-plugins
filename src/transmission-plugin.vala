[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.TransmissionPlugin);
}

namespace BobLauncher {
    public enum TorrentStatus {
        STOPPED,
        QUEUED_TO_VERIFY,
        VERIFYING,
        QUEUED_TO_DOWNLOAD,
        DOWNLOADING,
        QUEUED_TO_SEED,
        SEEDING;

        public string to_string() {
            switch (this) {
                case STOPPED:
                    return "Stopped";
                case QUEUED_TO_VERIFY:
                    return "Queued to verify";
                case VERIFYING:
                    return "Verifying local data";
                case QUEUED_TO_DOWNLOAD:
                    return "Queued to download";
                case DOWNLOADING:
                    return "Downloading";
                case QUEUED_TO_SEED:
                    return "Queued to seed";
                case SEEDING:
                    return "Seeding";
                default:
                    return "Unknown status";
            }
        }
    }

    public static bool parse_transmission_response(string response) {
        try {
            debug(response);
            var parser = new Json.Parser();
            parser.load_from_data(response);

            var root_object = parser.get_root().get_object();

            if (root_object.has_member("result")) {
                string result = root_object.get_string_member("result");
                return result == "success";
            }

            return false;
        } catch (Error e) {
            warning("Failed to parse response: %s", e.message);
            return false;
        }
    }


    public class TransmissionClient {
        public string? session_id { get; private set; default = null; }
        public string base_url = "";
        private uint connection_attempts;

        private bool _is_connected = false;
        private bool is_connecting = false;



        public TransmissionClient(string url) {
            base_url = url;
        }

        public void reset() {
            this.connection_attempts = 0;
        }

        public bool is_connected() {
            if (!_is_connected && !is_connecting && connection_attempts++ % 10 == 0) {
                is_connecting = true;
                try_connect(null);
            }
            return _is_connected;
        }


        private void try_connect(Cancellable? cancellable) {
            if (session_id == null) {
                var reply = send_torrent_command("""{"arguments":{"fields":["session-id"]},"method":"session-get"}""", cancellable);
                _is_connected = reply != null && parse_transmission_response(reply);
            }
            is_connecting = false;
        }

        public string? send_torrent_command(string payload, Cancellable? cancellable = null) {
            var session = new Soup.Session();
            session.timeout = 1;
            session.idle_timeout = 1;
            for (uint i = 0; i < 2; i++) {


                var msg = new Soup.Message("POST", base_url);
                msg.request_headers.append("Content-Type", "application/json");
                if (session_id != null) {
                    msg.request_headers.append("X-Transmission-Session-Id", session_id);
                }

                var pl_bytes = new GLib.Bytes(payload.data);
                msg.set_request_body_from_bytes("application/json", pl_bytes);


                try {
                    var input_stream = session.send(msg, cancellable);
                    var status_code = msg.status_code;

                    var token = msg.response_headers.get_one("X-Transmission-Session-Id");
                    if (token != null) {
                        this.session_id = token.dup();
                    }
                    if (status_code == Soup.Status.OK) {
                        var bytes = input_stream.read_bytes(int.MAX, cancellable);
                        return (string)bytes.get_data();
                    } else if (status_code == Soup.Status.CONFLICT) {
                        // Session ID is invalid, update it and retry
                        continue;
                    } else {
                        throw new GLib.Error(GLib.Quark.from_string("TransmissionError"), 0,
                            "Torrent command failed with status code: %u", status_code);
                    }
                } catch (GLib.Error e) { }
            }
            return null;
        }
    }

    public class TransmissionPlugin : SearchBase {
        protected override void search_shard(ResultContainer rs, uint shard_id) {
            if (clients[shard_id].is_connected()) {
                fetch_transmission_data(rs, clients[shard_id]);
            }
        }



        internal static string get_remote_identifier(string url) {
            try {
                var uri = Uri.parse(url, UriFlags.NONE);
                string host = uri.get_host();
                string port = uri.get_port().to_string();

                if (host == "127.0.0.1" || host == "localhost") {
                    return "Local | ";
                } else if (host.has_prefix("192.168.") || host.has_prefix("10.") || (host.has_prefix("172.") && int.parse(host.split(".")[1]) >= 16 && int.parse(host.split(".")[1]) <= 31)) {
                    return @"LAN ($host:$port) | ";
                } else {
                    return @"Remote ($host:$port) | ";
                }
            } catch (Error e) {
                warning("Failed to parse URL: %s", e.message);
                return "Unknown";
            }
        }


        private string[] remote_urls = {};
        private GenericArray<TransmissionClient> clients;
        private GenericArray<Action> actions;

        construct {
            icon_name = "transmission";
            clients = new GenericArray<TransmissionClient>();
            actions = new GenericArray<Action>();

            actions.add(new StartTorrentAction());
            actions.add(new PauseTorrentAction());
            actions.add(new DeleteTorrentAction());
        }
        public override void on_setting_changed(string key, GLib.Variant value) {
                remote_urls = value.get_strv();
                for (int i = 0; i < remote_urls.length; i++) {
                    debug("Transmission remote url: %s", remote_urls[i]);
                }

                clients = new GenericArray<TransmissionClient>();
                foreach (string url in remote_urls) {
                    clients.add(new TransmissionClient(url));
                }

        }

        public override bool activate() {
            return true;
        }

        public override void deactivate() {
            clients = new GenericArray<TransmissionClient>();
        }

        const string PAYLOAD = """{"arguments":{"fields":["id","addedDate","file-count","name","primary-mime-type","totalSize","error","errorString","eta","isFinished","isStalled","labels","leftUntilDone","metadataPercentComplete","peersConnected","peersGettingFromUs","peersSendingToUs","percentDone","queuePosition","rateDownload","rateUpload","recheckProgress","seedRatioMode","sizeWhenDone","status","downloadDir","uploadRatio"]},"method":"torrent-get"}""";

        private void fetch_transmission_data(ResultContainer rs, TransmissionClient client) {
            var reply = client.send_torrent_command(PAYLOAD, null);
            if (reply == null) {
                return;
            }

            try {
                var parser = new Json.Parser();
                parser.load_from_data(reply);

                var root_object = parser.get_root().get_object();
                var arguments_object = root_object.get_object_member("arguments");

                if (arguments_object != null && arguments_object.has_member("torrents")) {
                    var torrents_array = arguments_object.get_array_member("torrents");

                    foreach (var torrent_element in torrents_array.get_elements()) {
                        var torrent_object = torrent_element.get_object();
                        var title = torrent_object.get_string_member("name");
                        var score = rs.match_score(title);
                        rs.add_lazy_unique(score, () => new TransmissionDownload(torrent_object, client));
                    }
                }
            } catch (GLib.Error e) { }
        }


        public class TransmissionDownload : Match {
            public override string get_title() {
                return torrent_object.get_string_member("name");
            }

            private string description;
            public override string get_description() {
                return description;
            }

            public override string get_icon_name() {
                return IconCacheService.best_icon_name_for_mime_type(mime_type);
            }

            public string mime_type { get; construct; }
            public int64 id { get; construct; }
            public double progress { get; construct; }
            public int64 eta { get; construct; }
            public int64 download_speed { get; construct; }
            public int64 upload_speed { get; construct; }
            public int64 size_when_done { get; construct; }
            public double upload_ratio { get; construct; }
            public TorrentStatus status { get; set; }
            public bool is_finished { get; construct; }
            public TransmissionClient client { get; construct; }
            private Json.Object torrent_object;

            public TransmissionDownload(Json.Object torrent_object, TransmissionClient client) {
                int64 _left_until_done = torrent_object.get_int_member("leftUntilDone");
                int64 _size_when_done = torrent_object.get_int_member("sizeWhenDone");
                double _metadata_percent = torrent_object.get_double_member("metadataPercentComplete");

                double _progress;
                string progress_text;

                bool is_retrieving_metadata = (_size_when_done == 0 && _metadata_percent < 1.0);

                if (is_retrieving_metadata) {
                    _progress = 0.0;
                    progress_text = "Metadata: %.1f%%".printf(_metadata_percent * 100);
                } else if (_size_when_done == 0) {
                    _progress = 0.0;
                    progress_text = "Waiting...";
                } else {
                    _progress = (double)(_size_when_done - _left_until_done) / _size_when_done;
                    progress_text = "%.2f%%".printf(_progress * 100);
                }

                int64 _eta = torrent_object.get_int_member("eta");
                int64 _download_speed = torrent_object.get_int_member("rateDownload");
                int64 _upload_speed = torrent_object.get_int_member("rateUpload");
                double _upload_ratio = torrent_object.get_double_member("uploadRatio");

                TorrentStatus _status = (TorrentStatus)torrent_object.get_int_member("status");

                string status_display = is_retrieving_metadata ?
                    "Retrieving metadata" :
                    _status.to_string();

                string _description = "%s%s | %s | %s ↓ %s ↑ | %s | Ratio: %.2f".printf(
                    TransmissionPlugin.get_remote_identifier(client.base_url),
                    status_display,
                    progress_text,
                    format_speed(_download_speed),
                    format_speed(_upload_speed),
                    format_eta(_eta),
                    _upload_ratio
                );

                Object(
                    size_when_done: _size_when_done,
                    id: torrent_object.get_int_member("id"),
                    status: _status,
                    is_finished: torrent_object.get_boolean_member("isFinished"),
                    upload_ratio: _upload_ratio,
                    upload_speed: _upload_speed,
                    download_speed: _download_speed,
                    eta: _eta,
                    progress: _progress,
                    mime_type: torrent_object.get_string_member("primary-mime-type"),
                    client: client
                );
                this.torrent_object = torrent_object;
                this.description = _description;
            }


            public static string format_eta(int64 seconds) {
                if (seconds < 0) {
                    return "∞";
                }

                int hours = (int)(seconds / 3600);
                int minutes = (int)((seconds % 3600) / 60);
                int remaining_seconds = (int)(seconds % 60);

                return "%02d:%02d:%02d".printf(hours, minutes, remaining_seconds);
            }


            public static string format_speed(int64 bytes_per_second) {
                string[] units = { "B/s", "KB/s", "MB/s", "GB/s", "TB/s" };
                double speed = bytes_per_second;
                int unit_index = 0;

                while (speed >= 1024 && unit_index < units.length - 1) {
                    speed /= 1024;
                    unit_index++;
                }

                return "%.2f %s".printf(speed, units[unit_index]);
            }
        }

        public class StartTorrentAction: Action {

            public override string get_icon_name() {
                return "media-playback-start";
            }

            public override string get_title() {
                return "Start Torrent";
            }

            public override string get_description() {
                return "Resume downloading the torrent";
            }

            public override Score get_relevancy(Match match) {
                if (match is TransmissionDownload && ((TransmissionDownload)match).status != TorrentStatus.DOWNLOADING) {
                    return MatchScore.VERY_GOOD;
                }
                return MatchScore.LOWEST;
            }

            public override bool do_execute(Match source, Match? target = null) {
                if (!(source is TransmissionDownload)) {
                    return false;
                }
                var torrent = (TransmissionDownload)source;
                var payload = """{"arguments":{"ids":[%lld]},"method":"torrent-start"}""".printf(torrent.id);

                var reply = torrent.client.send_torrent_command(payload, null);
                if (reply == null || !parse_transmission_response(reply)) {
                    warning("Failed to start torrent: %s", torrent.get_title());
                }
                return true;
            }
        }

        public class DeleteTorrentAction: Action {
            public override string get_icon_name() {
                return "user-trash";
            }
            public override string get_title() {
                return "Delete Torrent and data";
            }

            public override string get_description() {
                return "Delete the torrent and its data";
            }

            public override Score get_relevancy(Match match) {
                if (match is TransmissionDownload) {
                    return MatchScore.VERY_GOOD;
                }
                return MatchScore.LOWEST;
            }

            public override bool do_execute(Match source, Match? target = null) {
                if (!(source is TransmissionDownload)) {
                    return false;
                }
                var torrent = (TransmissionDownload)source;
                var payload = """{"arguments":{"delete-local-data":true,"ids":[%lld]},"method":"torrent-remove"}""".printf(torrent.id);

                var reply = torrent.client.send_torrent_command(payload, null);
                if (reply == null || !parse_transmission_response(reply)) {
                    warning("Failed to delete torrent: %s", torrent.get_title());
                    return false;
                }
                return true;
            }
        }

        public class PauseTorrentAction: Action {
            public override string get_title() {
                return "Pause Torrent";
            }
            public override string get_description() {
                return "Pause the torrent download";
            }
            public override string get_icon_name() {
                return "media-playback-pause";
            }

            public override Score get_relevancy(Match match) {
                if (match is TransmissionDownload && ((TransmissionDownload)match).status == TorrentStatus.DOWNLOADING) {
                    return MatchScore.VERY_GOOD;
                }
                return MatchScore.LOWEST;
            }

            public override bool do_execute(Match source, Match? target = null) {
                if (!(source is TransmissionDownload)) {
                    return false;
                }
                var torrent = (TransmissionDownload)source;
                var payload = """{"arguments":{"ids":[%lld]},"method":"torrent-stop"}""".printf(torrent.id);

                var reply = torrent.client.send_torrent_command(payload, null);
                if (reply == null || !parse_transmission_response(reply)) {
                    warning("Failed to pause torrent: %s", torrent.get_title());
                    return false;
                }
                return true;
            }
        }

        public override void find_for_match(Match match, ActionSet rs) {
            foreach (var action in actions) {
                rs.add_action(action);
            }
        }
    }
}
