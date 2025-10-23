[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.WifiPlugin);
}


namespace BobLauncher {
    [DBus (name = "net.connman.iwd.Network")]
    public interface IwdNetwork : Object {
        public abstract void Connect() throws Error;
    }

    [DBus (name = "net.connman.iwd.KnownNetwork")]
    public interface IwdKnownNetwork : Object {
        public abstract void Forget() throws Error;
    }

    public struct OrderedNetwork {
        public ObjectPath object_path;
        public int16 signal_strength;
    }


    [DBus (name = "net.connman.iwd.Station")]
    public interface IwdStation : Object {
        public abstract async void Disconnect() throws Error;
        public abstract void Scan() throws Error;
        public abstract OrderedNetwork[] GetOrderedNetworks() throws Error;
        public abstract bool Scanning { get; }
        public abstract ObjectPath? ConnectedNetwork { owned get; }
        public abstract string State { owned get; }
    }


    [DBus (name = "net.connman.iwd.AgentManager")]
    public interface IwdAgentManager : Object {
        public abstract void RegisterAgent(ObjectPath path) throws Error;
        public abstract void UnregisterAgent(ObjectPath path) throws Error;
    }

    [DBus (name = "net.connman.iwd.Agent")]
    public class WifiAgent : Object {
        private unowned WifiPlugin plugin;

        public WifiAgent(WifiPlugin plugin) {
            Object();
            this.plugin = plugin;
        }

        public string RequestPassphrase(ObjectPath network_path) throws Error {
            var password = plugin.password_requested(network_path);
            if (password != null && password != "") {
                return password;
            }
            throw new DBusError.FAILED("No password provided");
        }

        public void Release() throws Error {
            throw new DBusError.FAILED("Not implemented");
        }

        public void Cancel(string reason) throws Error {
            throw new DBusError.FAILED("Not implemented");
        }
    }

    public class WifiPlugin : SearchBase {
        public override bool prefer_insertion_order { get { return true; } }
        static ObjectPath? agent_path;

        static construct {
            agent_path = new ObjectPath("/agent/BobLauncher");
        }

        construct {
            icon_name = "network-wireless";
        }

        private DBusObjectManager? manager = null;
        private DBusConnection? connection = null;
        private WifiAgent agent;
        private uint agent_registration_id;
        private IwdAgentManager? agent_manager = null;
        public signal string password_requested(string network_path);

        public override bool activate() {
            if (agent_registration_id != 0) {
                warning("Already initialized, skipping activation");
                return true;
            }

            try {
                connection = Bus.get_sync(BusType.SYSTEM);
            } catch (Error e) {
                warning("Failed to connect to dbus: %s", e.message);
                return false;
            }
            try {
                manager = new DBusObjectManagerClient.sync(
                    connection,
                    DBusObjectManagerClientFlags.NONE,
                    "net.connman.iwd",
                    "/",
                    null,
                    null
                );

                try {
                    agent_manager = connection.get_proxy_sync<IwdAgentManager>("net.connman.iwd", "/net/connman/iwd");
                } catch (Error e) {
                    warning("IWD AgentManager: %s", e.message);
                }

                agent = new WifiAgent(this);
                agent_registration_id = connection.register_object(agent_path, agent);

                agent_manager.RegisterAgent(agent_path);
                return true;
            } catch (Error e) {
                warning("Failed to connect to iwd or register agent: %s", e.message);
                if (agent_registration_id != 0) {
                    connection.unregister_object(agent_registration_id);
                }
                agent_registration_id = 0;
                return false;
            }
        }

        public override void deactivate() {
            if (agent_manager != null) {
                try {
                    agent_manager.UnregisterAgent(agent_path);
                } catch (Error e) {
                    warning("Failed to unregister agent from IWD: %s", e.message);
                }
                agent_manager = null;
            }

            if (agent_registration_id != 0) {
                connection.unregister_object(agent_registration_id);
                agent_registration_id = 0;
            }

            connection = null;
            manager = null;
        }


        private static uint32 nl80211_xbm_to_percent(int32 xbm) {
            const int NOISE_FLOOR_DBM = -90;
            const int SIGNAL_MAX_DBM = -20;

            if (xbm < NOISE_FLOOR_DBM)
                xbm = NOISE_FLOOR_DBM;
            if (xbm > SIGNAL_MAX_DBM)
                xbm = SIGNAL_MAX_DBM;

            return (uint32)(100 - 70 * ((float)(SIGNAL_MAX_DBM - xbm) / (float)(SIGNAL_MAX_DBM - NOISE_FLOOR_DBM)));
        }

        private void get_wifi_networks(ResultContainer rs, IwdStation station) throws Error {
            if (!station.Scanning) {
                station.Scan();
            }
            if (rs.is_cancelled()) return;

            var networks = station.GetOrderedNetworks();
            for (uint i = 0; i < networks.length; i++) {
                if (rs.is_cancelled()) return;
                string object_path = networks[i].object_path;
                int16 signal_strength = networks[i].signal_strength / 100; // convert to dBm from centi

                var network_interface = manager.get_interface(object_path, "net.connman.iwd.Network");
                if (network_interface != null) {
                    var proxy = (DBusProxy)network_interface;

                    string ssid = "";
                    var name_variant = proxy.get_cached_property("Name");
                    if (name_variant != null && name_variant.is_of_type(VariantType.STRING)) {
                        ssid = name_variant.get_string();
                    }

                    if (!rs.has_match(ssid)) {
                        continue;
                    }

                    bool connected = false;
                    var connected_variant = proxy.get_cached_property("Connected");
                    if (connected_variant != null && connected_variant.is_of_type(VariantType.BOOLEAN)) {
                        connected = connected_variant.get_boolean();
                    }

                    Score score;
                    if (connected) {
                        score = MatchScore.HIGHEST;
                    } else if (is_known_network(object_path)) {
                        score = MatchScore.HIGHEST+(Score)signal_strength;
                    } else {
                        score = MatchScore.HIGHEST - MatchScore.EXCELLENT + (Score)signal_strength;
                    }

                    rs.add_lazy(object_path.hash(), score, () => {
                        string security_type = "Unknown";
                        var type_variant = proxy.get_cached_property("Type");
                        if (type_variant != null && type_variant.is_of_type(VariantType.STRING)) {
                            security_type = type_variant.get_string();
                        }
                        return new WifiNetwork(ssid, object_path, connected, signal_strength, security_type, score);
                    });
                }
            }


        }

        public async void forget_network(string object_path) {
            try {
                string[] path_parts = object_path.split("/");
                string network_name = path_parts[path_parts.length - 1];

                string known_network_path = "/net/connman/iwd/" + network_name;

                var known_network = yield Bus.get_proxy<IwdKnownNetwork>(BusType.SYSTEM, "net.connman.iwd", known_network_path);
                known_network.Forget();
                debug("Forgot network: %s", known_network_path);
            } catch (Error e) {
                warning("Failed to forget network %s: %s", object_path, e.message);
            }
        }

        private IwdStation find_station() throws Error {
            var objects = manager.get_objects();
            foreach (var obj in objects) {
                var station_interface = manager.get_interface(obj.get_object_path(), "net.connman.iwd.Station");
                if (station_interface != null) {
                    return Bus.get_proxy_sync<IwdStation>(BusType.SYSTEM, "net.connman.iwd", obj.get_object_path());
                }
            }
            throw new GLib.Error(GLib.Quark.from_string("Wifi Error"), 0, "No station");
        }

        private bool network_needs_password(string object_path) {
            var proxy = (DBusProxy)manager.get_interface(object_path, "net.connman.iwd.Network");
            if (proxy == null) {
                warning("could not get interface net.connman.iwd.Network");
                return false;
            }
            var type = (string)proxy.get_cached_property("Type");
            if (type == "open") {
                return false;
            }
            return proxy.get_cached_property("KnownNetwork") == null;
        }

        public bool connect_to_network(string object_path) {
            try {
                var network = Bus.get_proxy_sync<IwdNetwork>(BusType.SYSTEM, "net.connman.iwd", object_path);
                network.Connect();
                debug("Connected to network: %s", object_path);
                return true;
            } catch (Error e) {
                warning("Failed to connect to network %s: %s", object_path, e.message);
                return false;
            }
        }

        private void disconnect_from_network() {
            try {
                var objects = manager.get_objects();
                foreach (var obj in objects) {
                    var station_interface = manager.get_interface(obj.get_object_path(), "net.connman.iwd.Station");
                    if (station_interface != null) {
                        var station = Bus.get_proxy_sync<IwdStation>(BusType.SYSTEM, "net.connman.iwd", obj.get_object_path());
                        station.Disconnect.begin();
                        debug("Disconnected from network");
                        break;
                    }
                }
            } catch (Error e) {
                warning("Failed to disconnect from network: %s", e.message);
            }
        }

        private bool is_known_network(string object_path) {
            var proxy = (DBusProxy)manager.get_interface(object_path, "net.connman.iwd.Network");
            if (proxy == null) {
                warning("could not get interface net.connman.iwd.Network");
                return false;
            }
            return proxy.get_cached_property("KnownNetwork") != null;
        }

        public class WifiNetwork : Match {
            public string object_path { get; set; }
            public string ssid { get; set; }
            public bool is_connected { get; set; }
            public int16 signal_strength { get; set; }
            public string security_type { get; set; }

            public override string get_title() {
                return this.ssid;
            }

            public override string get_description() {
                return get_network_description(is_connected, signal_strength, security_type);
            }

            public override string get_icon_name() {
                return is_connected ? "network-wireless" : "network-wireless-offline";
            }


            public WifiNetwork(string ssid, string object_path, bool is_connected, int16 signal_strength, string security_type, Score score) {
                Object(
                    object_path: object_path,
                    ssid: ssid,
                    is_connected: is_connected,
                    signal_strength: signal_strength,
                    security_type: security_type
                );
            }

            private static string get_network_description(bool is_connected, int16 signal_strength, string security_type) {
                string status = is_connected ? "Connected" : "Not connected";
                string signal = get_signal_strength_string(signal_strength);
                return @"$status | Signal: $signal | Security: $security_type";
            }

            private static string get_signal_strength_string(int16 strength) {
                uint32 percentage = nl80211_xbm_to_percent(strength);

                string description = percentage >= 80 ? "Excellent" :
                                     percentage >= 60 ? "Good" :
                                     percentage >= 40 ? "Fair" :
                                     percentage >= 20 ? "Poor" : "Very Poor";

                return @"$description ($strength dBm, $percentage%)";
            }
        }

        private class ConnectOpenAction: Action {
            private unowned WifiPlugin plugin;

            private string network_name;
            public override string get_title() {
                return "Connect to " + network_name;
            }

            public override string get_description() {
                return "Connect to the open or stored Wi-Fi network";
            }
            public override string get_icon_name() {
                return "network-wireless-acquiring";
            }

            public ConnectOpenAction(WifiPlugin plugin, string network_name) {
                Object();
                this.network_name = network_name;
                this.plugin = plugin;
            }

            public override Score get_relevancy(Match match) {
                if (match is WifiNetwork && !((WifiNetwork)match).is_connected) {
                    return MatchScore.EXCELLENT;
                }
                return MatchScore.ABOVE_THRESHOLD;
            }

            public override bool do_execute(Match source, Match? target = null) {
                if (!(source is WifiNetwork)) {
                    return false;
                }
                var network = (WifiNetwork)source;
                plugin.connect_to_network(network.object_path);
                return true;
            }
        }

        private class ConnectSecuredAction : ActionTarget {
            private unowned WifiPlugin plugin;
            private string network_path;
            private string network_password;

            private string network_name;
            public override string get_title() {
                return "Enter Passphrase for " + network_name;
            }

            public override string get_description() {
                return "Connect to the secured Wi-Fi network (requires password)";
            }
            public override string get_icon_name() {
                return "network-wireless-acquiring";
            }


            public ConnectSecuredAction(WifiPlugin plugin, string network_name, string network_path) {
                Object();
                this.plugin = plugin;
                this.network_name = network_name;
                this.network_path = network_path;
            }

            public override bool do_execute(Match source, Match? target) {
                if (!(source is WifiNetwork) || target == null) {
                    return false;
                }
                var network = (WifiNetwork)source;
                this.network_password = target.get_title();
                plugin.password_requested.connect(on_password_requested);
                return plugin.connect_to_network(network.object_path);
            }

            private string on_password_requested(string requested_network_path) {
                if (requested_network_path == this.network_path) {
                    plugin.password_requested.disconnect(on_password_requested);
                    return this.network_password;
                }
                return "";
            }

            public override Score get_relevancy(Match match) {
                if (!(match is WifiNetwork)) {
                    return MatchScore.LOWEST;
                }

                if (!((WifiNetwork)match).is_connected) {
                    return MatchScore.EXCELLENT;
                }
                return MatchScore.ABOVE_THRESHOLD;
            }

            public override Match target_match (string query) {
                return new UnknownMatch(query); // TODO: create proper wifi target
            }

        }

        private class DisconnectAction: Action {
            private unowned WifiPlugin plugin;
            private string network_name;
            public override string get_title() {
                return "Disconnect the current Wi-Fi network";
            }

            public override string get_description() {
                return "Disconnect from \"" + network_name + "\"";
            }
            public override string get_icon_name() {
                return "network-wireless-offline";
            }


            public DisconnectAction(WifiPlugin plugin, string network_name) {
                Object();
                this.plugin = plugin;
                this.network_name = network_name;
            }

            public override Score get_relevancy(Match match) {
                if (!(match is WifiNetwork)) {
                    return MatchScore.LOWEST;
                }

                if (((WifiNetwork)match).is_connected) {
                    return MatchScore.EXCELLENT;
                }

                return MatchScore.ABOVE_THRESHOLD;
            }

            public override bool do_execute(Match source, Match? target = null) {
                if (source is WifiNetwork) {
                    plugin.disconnect_from_network();
                }
                return source is WifiNetwork;
            }
        }

        private class ForgetNetworkAction: Action {
            private WifiPlugin plugin;

            private string network_name;
            public override string get_title() {
                return "Forget " + network_name;
            }

            public override string get_description() {
                return "Forget the saved Wi-Fi network";
            }
            public override string get_icon_name() {
                return "edit-delete";
            }

            public ForgetNetworkAction(WifiPlugin plugin, string network_name) {
                Object();
                this.plugin = plugin;
            }

            public override Score get_relevancy(Match match) {
                if (match is WifiNetwork) {
                    return MatchScore.AVERAGE;
                }
                return MatchScore.LOWEST;
            }

            public override bool do_execute(Match source, Match? target = null) {
                if (!(source is WifiNetwork)) {
                    return false;
                }
                var network = (WifiNetwork)source;
                plugin.forget_network.begin(network.object_path);
                return true;
            }
        }

        public override void find_for_match(Match match, ActionSet rs) {
            var wifi_network = match as WifiNetwork;
            if (wifi_network == null) {
                return;
            }

            string ssid = wifi_network.get_title();
            unowned string op = wifi_network.object_path;

            if (wifi_network.is_connected) {
                rs.add_action(new DisconnectAction(this, ssid));
            } else if (network_needs_password(op)) {
                rs.add_action(new ConnectSecuredAction(this, ssid, op));
            } else {
                rs.add_action(new ConnectOpenAction(this, ssid));
            }



            if (is_known_network(wifi_network.object_path)) {
                var forget_action = new ForgetNetworkAction(this, ssid);
                rs.add_action(forget_action);
            }
        }

        public override void search(ResultContainer rs) {
            try {
                while(manager == null) {
                    activate();
                    if (rs.is_cancelled()) return;
                }
                var station = find_station();
                if (rs.is_cancelled()) return;
                get_wifi_networks(rs, station);
            } catch (Error e) {
                warning(e.message);
            }
        }
    }
}
