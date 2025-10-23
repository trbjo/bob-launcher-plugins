[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.SystemdServicePlugin);
}


namespace BobLauncher {
    public enum UnitType {
        SERVICE,
        SCOPE
    }

    public static string format_memory(uint64 bytes) {
        if (bytes == uint64.MAX || bytes == 0) {
            return "";
        }

        const uint64 KiB = 1024;
        const uint64 MiB = KiB * 1024;
        const uint64 GiB = MiB * 1024;

        if (bytes >= GiB) {
            return "%.1f GiB".printf(bytes / (double)GiB);
        } else if (bytes >= MiB) {
            return "%.1f MiB".printf(bytes / (double)MiB);
        } else if (bytes >= KiB) {
            return "%.1f KiB".printf(bytes / (double)KiB);
        } else {
            return "%llu B".printf(bytes);
        }
    }


    public class SystemdServicePlugin : PluginBase {
        private const string SYSTEMD_BUSNAME = "org.freedesktop.systemd1";
        private const string SYSTEMD_PATH = "/org/freedesktop/systemd1";
        private const string SYSTEMD_MANAGER_INTERFACE = "org.freedesktop.systemd1.Manager";
        private const string SYSTEMD_UNIT_INTERFACE = "org.freedesktop.systemd1.Unit";
        private const string SYSTEMD_SERVICE_INTERFACE = "org.freedesktop.systemd1.Service";
        private const string SYSTEMD_SCOPE_INTERFACE = "org.freedesktop.systemd1.Scope";
        private const string DBUS_PROPERTIES_INTERFACE = "org.freedesktop.DBus.Properties";

        private GenericArray<Action> service_actions;

        public class SystemdServices : SearchBase {
            public override bool prefer_insertion_order { get { return true; } }
            private DBusConnection session_bus;
            private Variant variant;
            private DBusProxy proxy;
            private BusType bus_type;
            private string title;
            private string description;

            public override string get_title() {
                return this.title;
            }
            public override string get_description() {
                return this.description;
            }
            public override string get_icon_name() {
                return this.icon_name;
            }


            public SystemdServices(BusType bus_type, DBusProxy proxy, Variant variant, DBusConnection session_bus) {
                Object();
                if (bus_type == BusType.SESSION) {
                    this.title = "Systemd User Units";
                    this.description = "Show and manage systemd user services and scopes";
                    this.icon_name = "system-run";
                } else {
                    this.title = "Systemd System Units";
                    this.description = "Show and manage systemd system services and scopes";
                    this.icon_name = "applications-system";
                }

                this.bus_type = bus_type;
                this.proxy = proxy;
                this.variant = variant;
                this.session_bus = session_bus;
            }



            public override void search(ResultContainer rs) {
                bool empty_string = rs.get_query().char_count() == 0;
                // int64 start_time = get_monotonic_time();

                GLib.Variant? result;
                try {
                    result = proxy.call_sync(
                        "ListUnitsByPatterns",
                        variant,
                        DBusCallFlags.NONE,
                        -1,
                        null
                    );
                } catch (Error e) {
                    warning(e.message);
                    return;
                }

                string unit_name = "";
                string description = "";
                // string load_state = "";
                string active_state = "";
                string sub_state = "";
                // string following = "";
                string unit_path = "";
                // uint32 job_id = 0;
                // string job_type = "";
                // string job_path = "";

                VariantIter iter = result.get_child_value(0).iterator();
                int lock = (int)iter.n_children();

                while (iter.next(
                    "(ssssssouso)",
                    ref unit_name,
                    ref description,
                    null,
                    ref active_state,
                    ref sub_state,
                    null,
                    ref unit_path,
                    null,
                    null,
                    null
                )) {

                    string owned_unit_name = unit_name.dup();
                    if (!rs.has_match(owned_unit_name)) {
                        Threading.atomic_dec(ref lock);
                        continue;
                    }
                    string owned_description = description.dup();
                    string owned_active_state = active_state.dup();
                    string owned_sub_state = sub_state.dup();
                    string owned_unit_path = unit_path.dup();

                    Threading.run(() => {
                        Score score = empty_string ? 100 : rs.match_score(owned_unit_name);
                        if (score == MatchScore.LOWEST) {
                            Threading.atomic_dec(ref lock);
                            return;
                        }

                        DBusProxy? props_proxy;
                        try {
                            props_proxy = new DBusProxy.sync(
                                session_bus,
                                DBusProxyFlags.NONE,
                                null,
                                SYSTEMD_BUSNAME,
                                owned_unit_path,
                                DBUS_PROPERTIES_INTERFACE
                            );
                        } catch (Error e) {
                            warning(e.message);
                            Threading.atomic_dec(ref lock);
                            return;
                        }

                        uint hash = owned_unit_name.hash();

                        UnitType unit_type = owned_unit_name.has_suffix(".service") ? UnitType.SERVICE : UnitType.SCOPE;

                        string status_text = "";
                        uint64 memory_current = 0;
                        uint main_pid = 0;

                        if (unit_type == UnitType.SERVICE) {
                            try {
                                var service_props = props_proxy.call_sync(
                                    "GetAll",
                                    new Variant("(s)", SYSTEMD_SERVICE_INTERFACE),
                                    DBusCallFlags.NONE,
                                    -1,
                                    null
                                );
                                var service_dict = service_props.get_child_value(0);

                                var status_variant = service_dict.lookup_value("StatusText", null);
                                if (status_variant != null) {
                                    status_text = status_variant.get_string().dup();
                                }

                                var main_pid_variant = service_dict.lookup_value("MainPID", null);
                                if (main_pid_variant != null) {
                                    main_pid = main_pid_variant.get_uint32();
                                }

                                var memory_variant = service_dict.lookup_value("MemoryCurrent", null);
                                if (memory_variant != null) {
                                    memory_current = memory_variant.get_uint64();
                                }

                            } catch (Error e) {
                                warning("Failed to get service properties: %s", e.message);
                            }
                        } else if (unit_type == UnitType.SCOPE) {
                            try {
                                var scope_props = props_proxy.call_sync(
                                    "GetAll",
                                    new Variant("(s)", SYSTEMD_SCOPE_INTERFACE),
                                    DBusCallFlags.NONE,
                                    -1,
                                    null
                                );
                                var scope_dict = scope_props.get_child_value(0);

                                var control_pid_variant = scope_dict.lookup_value("ControlPID", null);
                                if (control_pid_variant != null) {
                                    main_pid = control_pid_variant.get_uint32();
                                }

                                var memory_variant = scope_dict.lookup_value("MemoryCurrent", null);
                                if (memory_variant != null) {
                                    memory_current = memory_variant.get_uint64();
                                }

                            } catch (Error e) {
                                warning("Failed to get scope properties: %s", e.message);
                            }
                        }

                        bool is_enabled = false;
                        bool can_reload = false;
                        bool is_masked = false;
                        uint64 active_enter_timestamp = 0;
                        string unit_file_state = "";

                        try {

                            var unit_props = props_proxy.call_sync(
                                "GetAll",
                                new Variant("(s)", SYSTEMD_UNIT_INTERFACE),
                                DBusCallFlags.NONE,
                                -1,
                                null
                            );
                            var unit_dict = unit_props.get_child_value(0);

                            var enabled_variant = unit_dict.lookup_value("UnitFileState", null);
                            if (enabled_variant != null) {
                                unit_file_state = enabled_variant.get_string();
                                is_enabled = (unit_file_state == "enabled" || unit_file_state == "enabled-runtime");
                                is_masked = (unit_file_state == "masked" || unit_file_state == "masked-runtime");
                            }

                            var can_reload_variant = unit_dict.lookup_value("CanReload", null);
                            if (can_reload_variant != null) {
                                can_reload = can_reload_variant.get_boolean();
                            }

                            var timestamp_variant = unit_dict.lookup_value("ActiveEnterTimestamp", null);
                            if (timestamp_variant != null) {
                                active_enter_timestamp = timestamp_variant.get_uint64();
                            }
                        } catch (Error e) {
                            warning("Failed to get unit properties: %s", e.message);
                        }

                        string uptime = "";
                        if (owned_active_state == "active" && active_enter_timestamp > 0) {
                            // Convert microseconds since epoch to DateTime
                            var active_since = new DateTime.from_unix_utc((int64)(active_enter_timestamp / 1000000));
                            var now = new DateTime.now_utc();
                            uptime = BobLauncher.Utils.format_modification_time(now, active_since);
                        }

                        rs.add_lazy(hash, score, () => {
                            return new SystemdUnitMatch(
                                owned_unit_name,
                                owned_description,
                                owned_active_state,
                                owned_sub_state,
                                main_pid,
                                status_text,
                                owned_unit_path,
                                get_unit_state_icon(owned_active_state, owned_sub_state, unit_type),
                                bus_type,
                                is_enabled,
                                can_reload,
                                is_masked,
                                uptime,
                                unit_type,
                                unit_file_state,
                                memory_current
                            );
                        });
                        Threading.atomic_dec(ref lock);
                    });
                }
                while (Threading.atomic_load(ref lock) > 0) { }
                // int64 elapsed = get_monotonic_time() - start_time;
                // message("load_services took %.3f ms", elapsed / 1000.0);
            }
        }

        construct {
            icon_name = "system-run";
            service_actions = new GenericArray<Action>();
            service_actions.add(new RestartUnitAction());
            service_actions.add(new StartUnitAction());
            service_actions.add(new StopUnitAction());
            service_actions.add(new EnableServiceAction());
            service_actions.add(new DisableServiceAction());
            service_actions.add(new EnableNowServiceAction());
            service_actions.add(new DisableNowServiceAction());
            service_actions.add(new ReloadServiceAction());
            service_actions.add(new MaskServiceAction());
            service_actions.add(new UnmaskServiceAction());
        }

        internal static string get_unit_state_icon(string active_state, string sub_state, UnitType unit_type) {
            switch (active_state) {
                case "active":
                    switch (sub_state) {
                        case "running":
                            return unit_type == UnitType.SCOPE ? "applications-other" : "media-playback-start";
                        case "waiting":
                            return "media-playback-pause";
                        case "exited":
                            return "emblem-ok";
                        case "abandoned":
                            return "user-trash";
                        default:
                            return "emblem-default";
                    }

                case "inactive":
                    switch (sub_state) {
                        case "dead":
                            return unit_type == UnitType.SCOPE ? "applications-other" : "media-playback-stop";
                        case "failed":
                            return "dialog-error";
                        default:
                            return "process-stop";
                    }

                case "failed":
                    switch (sub_state) {
                        case "failed":
                            return "dialog-error";
                        case "crashed":
                            return "computer-fail";
                        case "timeout":
                            return "alarm";
                        default:
                            return "edit-delete";
                    }

                case "activating":
                    switch (sub_state) {
                        case "start-pre":
                            return "content-loading";
                        case "start":
                            return "media-seek-forward";
                        case "start-post":
                            return "emblem-synchronizing";
                        default:
                            return "system-run";
                    }

                case "deactivating":
                    switch (sub_state) {
                        case "stop-pre":
                            return "media-seek-backward";
                        case "stop":
                            return "process-stop";
                        case "stop-post":
                            return "edit-undo";
                        default:
                            return "media-playback-stop";
                    }

                case "reloading":
                    return "view-refresh";

                case "maintenance":
                    return "emblem-system";

                default:
                    return "dialog-question";
            }
        }

        public override void find_for_match(Match match, ActionSet rs) {
            var service_match = match as SystemdUnitMatch;
            if (service_match == null) {
                return;
            }

            foreach (var action in service_actions) {
                // Skip actions not applicable to scopes
                if (service_match.unit_type == UnitType.SCOPE) {
                    if (action is StartUnitAction ||
                        action is RestartUnitAction ||
                        action is EnableServiceAction ||
                        action is DisableServiceAction ||
                        action is EnableNowServiceAction ||
                        action is DisableNowServiceAction ||
                        action is ReloadServiceAction ||
                        action is MaskServiceAction ||
                        action is UnmaskServiceAction) {
                        continue;
                    }
                }

                // Regular action filtering
                if (action is StartUnitAction && service_match.active_state == "active") continue;
                if (action is StopUnitAction && service_match.active_state == "inactive") continue;
                if (action is EnableServiceAction && service_match.is_enabled) continue;
                if (action is DisableServiceAction && !service_match.is_enabled) continue;
                if (action is ReloadServiceAction && !service_match.can_reload) continue;
                if (action is MaskServiceAction && service_match.is_masked) continue;
                if (action is UnmaskServiceAction && !service_match.is_masked) continue;

                rs.add_action(action);
            }
        }

        private SystemdServices? create_systemd_service_class(BusType bus_type) {
            try {
                string address;
                if (bus_type == BusType.SESSION) {
                    address = Environment.get_variable("DBUS_SESSION_BUS_ADDRESS");
                } else {
                    address = "unix:path=/var/run/dbus/system_bus_socket";
                }

                if (address == null) {
                    warning("Could not get bus address");
                    return null;
                }

                var session_bus = new DBusConnection.for_address_sync(
                    address,
                    DBusConnectionFlags.AUTHENTICATION_CLIENT | DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
                    null,
                    null
                );

                var proxy = new DBusProxy.sync(
                    session_bus,
                    DBusProxyFlags.NONE,
                    null,
                    SYSTEMD_BUSNAME,
                    SYSTEMD_PATH,
                    SYSTEMD_MANAGER_INTERFACE
                );

                var builder = new VariantBuilder(new VariantType("(asas)"));
                builder.open(new VariantType("as"));

                // Empty array for states (all states)
                builder.close();

                builder.open(new VariantType("as"));
                builder.add("s", "*.service");
                builder.add("s", "*.scope");
                builder.close();
                var variant = builder.end();

                return new SystemdServices(bus_type, proxy, variant, session_bus);
            } catch (Error e) {
                warning("Error creating private bus connection: %s", e.message);
                return null;
            }
        }

        public override bool activate() {
            SystemdServices? user = create_systemd_service_class(BusType.SESSION);
            var _search_providers = new GenericArray<SearchBase>();
            if (user != null) {
                _search_providers.add(user);
            }
            SystemdServices? system = create_systemd_service_class(BusType.SYSTEM);
            if (system != null) {
                _search_providers.add(system);
            }
            search_providers = _search_providers;
            return _search_providers.length > 0;
        }

        public class SystemdUnitMatch : Match, IRichDescription {
            public string my_title { get; construct; }
            public string my_icon_name { get; construct; }
            public string unit_name { get; construct; }
            public string active_state { get; construct; }
            public string sub_state { get; construct; }
            public string status_text { get; construct; }
            public bool is_enabled { get; construct; }
            public bool can_reload { get; construct; }
            public bool is_masked { get; construct; }
            public BusType bus_type { get; construct; }
            public string uptime { get; construct; }
            public UnitType unit_type { get; construct; }
            public string unit_file_state { get; construct; }
            public uint main_pid { get; construct; }
            public uint64 memory_current { get; construct; }
            public string description { get; construct; }

            private Description? _cached_description = null;

            public override string get_title() {
                return my_title;
            }

            public override string get_description() {
                assert_not_reached();
            }

            public override string get_icon_name() {
                return my_icon_name;
            }

            public unowned Description get_rich_description(Levensteihn.StringInfo si) {
                if (_cached_description == null) {
                    _cached_description = build_rich_description();
                }
                return _cached_description;
            }

            private Description build_rich_description() {
                var root = new Description.container("systemd-unit-description");

                if (status_text != "") {
                    var desc_container = new Description.container("description-container", Gtk.Orientation.HORIZONTAL);
                    desc_container.add_child(new Description("dialog-information-symbolic", "info-icon", FragmentType.IMAGE));
                    desc_container.add_child(new Description(@"$description | $status_text", "description-text"));
                    root.add_child(desc_container);
                } else {
                    var desc_container = new Description.container("description-container", Gtk.Orientation.HORIZONTAL);
                    desc_container.add_child(new Description("dialog-information-symbolic", "info-icon", FragmentType.IMAGE));
                    desc_container.add_child(new Description(description, "description-text"));
                    root.add_child(desc_container);
                }

                var state_container = new Description.container("state-container", Gtk.Orientation.HORIZONTAL);
                state_container.add_child(new Description("emblem-system-symbolic", "state-icon", FragmentType.IMAGE));
                string state_text = @"$active_state";
                if (sub_state != "" && sub_state != active_state) {
                    state_text += @" ($sub_state)";
                }
                state_container.add_child(new Description(state_text, get_state_css_class()));
                root.add_child(state_container);

                if (main_pid > 0) {
                    var pid_container = new Description.container("pid-container", Gtk.Orientation.HORIZONTAL);
                    pid_container.add_child(new Description("system-run-symbolic", "pid-icon", FragmentType.IMAGE));
                    pid_container.add_child(new Description(@"$main_pid", "pid-text"));
                    root.add_child(pid_container);
                }

                string memory_str = format_memory(memory_current);
                if (memory_str != "") {
                    var memory_container = new Description.container("memory-container", Gtk.Orientation.HORIZONTAL);
                    memory_container.add_child(new Description("drive-harddisk-system-symbolic", "memory-icon", FragmentType.IMAGE));
                    memory_container.add_child(new Description(memory_str, "memory-text"));
                    root.add_child(memory_container);
                }

                if (uptime != "") {
                    var uptime_container = new Description.container("uptime-container", Gtk.Orientation.HORIZONTAL);
                    uptime_container.add_child(new Description("document-open-recent-symbolic", "uptime-icon", FragmentType.IMAGE));
                    uptime_container.add_child(new Description(uptime, "uptime-text"));
                    root.add_child(uptime_container);
                }

                var flags_container = new Description.container("flags-container", Gtk.Orientation.HORIZONTAL);

                if (unit_type == UnitType.SCOPE) {
                    if (unit_file_state == "transient") {
                        flags_container.add_child(new Description("view-paged-symbolic", "transient-icon", FragmentType.IMAGE));
                    }
                } else {
                    if (is_enabled) {
                        flags_container.add_child(new Description("emblem-ok-symbolic", "enabled-icon", FragmentType.IMAGE));
                    } else {
                        flags_container.add_child(new Description("window-close-symbolic", "disabled-icon", FragmentType.IMAGE));
                    }
                }

                if (is_masked) {
                    flags_container.add_child(new Description("security-high-symbolic", "masked-icon", FragmentType.IMAGE));
                }

                if (can_reload) {
                    flags_container.add_child(new Description("view-refresh-symbolic", "reload-icon", FragmentType.IMAGE));
                }

                if (flags_container.children != null && flags_container.children.length > 0) {
                    root.add_child(flags_container);
                }

                return root;
            }

            private string get_state_css_class() {
                switch (active_state) {
                    case "active":
                    case "running":
                        return "state-active";
                    case "inactive":
                    case "dead":
                        return "state-inactive";
                    case "failed":
                        return "state-failed";
                    case "activating":
                    case "reloading":
                        return "state-transitioning";
                    default:
                        return "state-unknown";
                }
            }

            public SystemdUnitMatch(
                string name,
                string description,
                string active_state,
                string sub_state,
                uint main_pid,
                string status_text,
                string unit_path,
                string icon_name,
                BusType bus_type,
                bool is_enabled,
                bool can_reload,
                bool is_masked,
                string uptime,
                UnitType unit_type,
                string unit_file_state,
                uint64 memory_current
            ) {
                Object(
                    my_title: name,
                    my_icon_name: icon_name,
                    unit_name: name,
                    active_state: active_state,
                    sub_state: sub_state,
                    status_text: status_text,
                    is_enabled: is_enabled,
                    can_reload: can_reload,
                    is_masked: is_masked,
                    bus_type: bus_type,
                    uptime: uptime,
                    unit_type: unit_type,
                    unit_file_state: unit_file_state,
                    main_pid: main_pid,
                    memory_current: memory_current,
                    description: description
                );
            }
        }

        public abstract class SystemdServiceAction : Action {
            protected DBusConnection connection;

            private string title;
            public override string get_title() {
                return title;
            }

            private string description;
            public override string get_description() {
                return description;
            }

            private string icon_name;
            public override string get_icon_name() {
                return icon_name;
            }

            protected SystemdServiceAction(string title, string description, string icon_name) {
                Object();
                this.title = title;
                this.icon_name = icon_name;
                this.description = description;
            }

            protected bool execute_systemd_action(BusType bus_type, string method, string unit_name, string mode = "replace", Variant? extra = null) {
                try {
                    string address;
                    if (bus_type == BusType.SESSION) {
                        address = Environment.get_variable("DBUS_SESSION_BUS_ADDRESS");
                    } else {
                        address = "unix:path=/var/run/dbus/system_bus_socket";
                    }

                    connection = new DBusConnection.for_address_sync(
                        address,
                        DBusConnectionFlags.AUTHENTICATION_CLIENT | DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
                        null,
                        null
                    );

                    var proxy = new DBusProxy.sync(
                        connection,
                        DBusProxyFlags.NONE,
                        null,
                        SYSTEMD_BUSNAME,
                        SYSTEMD_PATH,
                        SYSTEMD_MANAGER_INTERFACE
                    );

                    Variant? result = null;

                    if (extra != null) {
                        result = proxy.call_sync(method, extra, DBusCallFlags.NONE, -1, null);
                    } else {
                        result = proxy.call_sync(method,
                            new Variant("(ss)", unit_name, mode),
                            DBusCallFlags.NONE,
                            -1,
                            null
                        );
                    }
                    debug(@"$method executed on $unit_name");

                    if (result != null) {
                        debug(@"Result: %s", result.print(true));
                    }

                    proxy.call_sync("Reload", null, DBusCallFlags.NONE, -1, null);
                    return true;

                } catch (Error e) {
                    warning(@"Error executing $method on $unit_name: %s", e.message);
                    return false;
                } finally {
                    if (connection != null) {
                        try {
                            connection.close_sync();
                        } catch (Error e) {
                            // Ignore close errors
                        }
                    }
                }
            }

            public override Score get_relevancy(Match match) {
                if (!(match is SystemdUnitMatch)) {
                    return MatchScore.LOWEST;
                }

                var service_match = (SystemdUnitMatch)match;

                if (service_match.unit_type == UnitType.SCOPE) {
                    if (!(this is StopUnitAction)) {
                        return MatchScore.LOWEST;
                    }
                }

                if (this is StartUnitAction && (service_match.active_state != "active")) {
                    return MatchScore.ABOVE_THRESHOLD;
                } else if (this is StopUnitAction && (service_match.active_state != "inactive")) {
                    return MatchScore.ABOVE_THRESHOLD;
                } else if (this is RestartUnitAction) {
                    return MatchScore.ABOVE_THRESHOLD;
                } else if (this is ReloadServiceAction && (service_match.can_reload)) {
                    return MatchScore.ABOVE_THRESHOLD;
                } else if (this is EnableServiceAction && (!service_match.is_enabled)) {
                    return MatchScore.ABOVE_THRESHOLD;
                } else if (this is DisableServiceAction && (service_match.is_enabled)) {
                    return MatchScore.ABOVE_THRESHOLD;
                } else if (this is EnableNowServiceAction && (!service_match.is_enabled)) {
                    return MatchScore.ABOVE_THRESHOLD;
                } else if (this is DisableNowServiceAction && (service_match.is_enabled)) {
                    return MatchScore.ABOVE_THRESHOLD;
                } else if (this is MaskServiceAction && (!service_match.is_masked)) {
                    return MatchScore.ABOVE_THRESHOLD;
                } else if (this is UnmaskServiceAction && (service_match.is_masked)) {
                    return MatchScore.ABOVE_THRESHOLD;
                } else {
                    return MatchScore.LOWEST;
                }
            }

        }

        public class StartUnitAction : SystemdServiceAction {
            public StartUnitAction() {
                base("Start",
                     "Start the systemd unit",
                     "media-playback-start");

            }

            // public override Score get_relevancy(Match match) {
            //     return base.get_relevancy(match);
            // }

            public override bool do_execute(Match source, Match? target = null) {
                if (source is SystemdUnitMatch) {
                    var service_match = (SystemdUnitMatch)source;
                    BusType bus_type = ((SystemdUnitMatch)source).bus_type;
                    return execute_systemd_action(bus_type, "StartUnit", service_match.unit_name);
                }
                return false;
            }
        }

        public class StopUnitAction : SystemdServiceAction {
            public StopUnitAction() {
                base("Stop",
                     "Stop the systemd unit",
                     "media-playback-stop");

            }

            // public override Score get_relevancy(Match match) {
            //     return base.get_relevancy(match);
            // }

            public override bool do_execute(Match source, Match? target = null) {
                if (source is SystemdUnitMatch) {
                    var service_match = (SystemdUnitMatch)source;
                    BusType bus_type = ((SystemdUnitMatch)source).bus_type;
                    return execute_systemd_action(bus_type, "StopUnit", service_match.unit_name);
                }
                return false;
            }
        }

        public class RestartUnitAction : SystemdServiceAction {

            public RestartUnitAction() {
                base("Restart",
                     "Restart the systemd unit",
                     "view-refresh");

            }

            public override Score get_relevancy(Match match) {
                return base.get_relevancy(match) + MatchScore.VERY_GOOD;
            }

            public override bool do_execute(Match source, Match? target = null) {
                if (source is SystemdUnitMatch) {
                    var service_match = (SystemdUnitMatch)source;
                    BusType bus_type = ((SystemdUnitMatch)source).bus_type;
                    return execute_systemd_action(bus_type, "RestartUnit", service_match.unit_name);
                }
                return false;
            }
        }

        public class ReloadServiceAction : SystemdServiceAction {
            public ReloadServiceAction() {
                base("Reload",
                     "Reload the service configuration",
                     "view-refresh");

            }

            // public override Score get_relevancy(Match match) {
            //     return base.get_relevancy(match);
            // }

            public override bool do_execute(Match source, Match? target = null) {
                if (source is SystemdUnitMatch) {
                    var service_match = (SystemdUnitMatch)source;
                    BusType bus_type = ((SystemdUnitMatch)source).bus_type;
                    return execute_systemd_action(bus_type, "ReloadUnit", service_match.unit_name);
                }
                return false;
            }
        }

        public class EnableServiceAction : SystemdServiceAction {
            public EnableServiceAction() {
                base("Enable",
                     "Enable the service to start on boot",
                     "list-add");

            }

            // public override Score get_relevancy(Match match) {
            //     return base.get_relevancy(match);
            // }

            public override bool do_execute(Match source, Match? target = null) {
                if (source is SystemdUnitMatch) {
                    var service_match = (SystemdUnitMatch)source;
                    BusType bus_type = ((SystemdUnitMatch)source).bus_type;
                    return execute_systemd_action(bus_type, "EnableUnitFiles",
                        service_match.unit_name,
                        "replace",
                        new Variant("(asbb)", new string[] { service_match.unit_name }, false, false)
                    );
                }
                return false;
            }
        }

        public class DisableServiceAction : SystemdServiceAction {
            public DisableServiceAction() {
                base("Disable",
                     "Disable the service from starting on boot",
                     "window-close");

            }

            // public override Score get_relevancy(Match match) {
            //     return base.get_relevancy(match);
            // }

            public override bool do_execute(Match source, Match? target = null) {
                if (source is SystemdUnitMatch) {
                    var service_match = (SystemdUnitMatch)source;
                    BusType bus_type = ((SystemdUnitMatch)source).bus_type;
                    return execute_systemd_action(bus_type, "DisableUnitFiles",
                        service_match.unit_name,
                        "replace",
                        new Variant("(asb)", new string[] { service_match.unit_name }, false)
                    );
                }
                return false;
            }
        }

        public class EnableNowServiceAction : SystemdServiceAction {
            public EnableNowServiceAction() {
                base("Enable and Start",
                     "Enable the service and start it immediately",
                     "media-playback-start");

            }

            // public override Score get_relevancy(Match match) {
            //     return base.get_relevancy(match);
            // }

            public override bool do_execute(Match source, Match? target = null) {
                if (source is SystemdUnitMatch) {
                    var service_match = (SystemdUnitMatch)source;
                    // First enable the service
                    BusType bus_type = ((SystemdUnitMatch)source).bus_type;
                    return execute_systemd_action(bus_type, "EnableUnitFiles",
                        service_match.unit_name,
                        "replace",
                        new Variant("(asbb)", new string[] { service_match.unit_name }, false, false)
                    ) && execute_systemd_action(bus_type, "StartUnit", service_match.unit_name);
                }
                return false;
            }
        }

        public class DisableNowServiceAction : SystemdServiceAction {
            public DisableNowServiceAction() {
                base("Disable and Stop",
                     "Stop the service and disable it from starting on boot",
                     "process-stop");

            }

            // public override Score get_relevancy(Match match) {
            //     return base.get_relevancy(match);
            // }

            public override bool do_execute(Match source, Match? target = null) {
                if (source is SystemdUnitMatch) {
                    var service_match = (SystemdUnitMatch)source;
                    // First stop the service
                    BusType bus_type = ((SystemdUnitMatch)source).bus_type;
                    return execute_systemd_action(bus_type, "StopUnit", service_match.unit_name) &&
                           execute_systemd_action(bus_type, "DisableUnitFiles",
                        service_match.unit_name,
                        "replace",
                        new Variant("(asb)", new string[] { service_match.unit_name }, false)
                    );
                }
                return false;
            }
        }

        public class MaskServiceAction : SystemdServiceAction {
            public MaskServiceAction() {
                base("Mask",
                     "Mask the service to prevent it from being started",
                     "locked");

            }

            // public override Score get_relevancy(Match match) {
            //     return base.get_relevancy(match);
            // }

            public override bool do_execute(Match source, Match? target = null) {
                if (source is SystemdUnitMatch) {
                    var service_match = (SystemdUnitMatch)source;

                    var files = new string[] { service_match.unit_name };

                    var variant = new Variant.tuple({
                        new Variant.strv(files),     // as - array of strings
                        new Variant.boolean(false),  // b - first boolean (runtime)
                        new Variant.boolean(true)    // b - second boolean (force)
                    });

                    BusType bus_type = ((SystemdUnitMatch)source).bus_type;
                    return execute_systemd_action(bus_type, "MaskUnitFiles",
                        service_match.unit_name,
                        "replace",
                        variant
                    );
                }
                return false;
            }
        }

        public class UnmaskServiceAction : SystemdServiceAction {
            public UnmaskServiceAction() {
                base("Unmask",
                     "Unmask the service to allow it to be started",
                     "view-private");

            }

            // public override Score get_relevancy(Match match) {
            //     return base.get_relevancy(match);
            // }

            public override bool do_execute(Match source, Match? target = null) {
                if (source is SystemdUnitMatch) {
                    var service_match = (SystemdUnitMatch)source;

                    var files = new string[] { service_match.unit_name };
                    var variant = new Variant.tuple({
                        new Variant.strv(files),     // as - array of strings
                        new Variant.boolean(false)   // b - boolean (runtime)
                    });

                    BusType bus_type = ((SystemdUnitMatch)source).bus_type;
                    return execute_systemd_action(bus_type, "UnmaskUnitFiles",
                        service_match.unit_name,
                        "replace",
                        variant
                    );
                }
                return false;
            }
        }
    }
}
