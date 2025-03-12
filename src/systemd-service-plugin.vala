[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.SystemdServicePlugin);
}


namespace BobLauncher {
    public class SystemdServicePlugin : SearchAction {
        private const string SYSTEMD_BUSNAME = "org.freedesktop.systemd1";
        private const string SYSTEMD_PATH = "/org/freedesktop/systemd1";
        private const string SYSTEMD_MANAGER_INTERFACE = "org.freedesktop.systemd1.Manager";
        private const string SYSTEMD_UNIT_INTERFACE = "org.freedesktop.systemd1.Unit";
        private const string SYSTEMD_SERVICE_INTERFACE = "org.freedesktop.systemd1.Service";
        private const string DBUS_PROPERTIES_INTERFACE = "org.freedesktop.DBus.Properties";

        private GenericArray<Action> service_actions;
        private DBusConnection session_bus;
        public BusType bus_type = BusType.SESSION;

        public override ulong initialize(GLib.Settings settings) {
            ulong handler_id = base.initialize(settings);
            if (bus_type == BusType.SESSION) {
                this.title = "Systemd User Services";
                this.description = "Show and manage systemd user services";
            } else {
                this.title = "Systemd System Services";
                this.description = "Show and manage systemd system services";
            }
            return handler_id;
        }

        construct {
            icon_name = "system-run";
            service_actions = new GenericArray<Action>();
            service_actions.add(new RestartServiceAction(bus_type));
            service_actions.add(new StartServiceAction(bus_type));
            service_actions.add(new StopServiceAction(bus_type));
            service_actions.add(new EnableServiceAction(bus_type));
            service_actions.add(new DisableServiceAction(bus_type));
            service_actions.add(new EnableNowServiceAction(bus_type));
            service_actions.add(new DisableNowServiceAction(bus_type));
            service_actions.add(new ReloadServiceAction(bus_type));
            service_actions.add(new MaskServiceAction(bus_type));
            service_actions.add(new UnmaskServiceAction(bus_type));
        }

        private new Variant? get_property(DBusProxy proxy, string interface_name, string property_name) {
            try {
                var result = proxy.call_sync(
                    "Get",
                    new Variant("(ss)", interface_name, property_name),
                    DBusCallFlags.NONE,
                    -1
                );

                if (result != null) {
                    Variant? value = null;
                    result.get("(v)", &value);
                    return value;
                }
            } catch (Error e) {
                warning("Error getting property %s: %s\n", property_name, e.message);
            }
            return null;
        }

        private string get_service_state_icon(string active_state, string sub_state) {
            switch (active_state) {
                case "active":
                    switch (sub_state) {
                        case "running":
                            return "media-playback-start";
                        case "waiting":
                            return "media-playback-pause";
                        case "exited":
                            return "emblem-ok";
                        default:
                            return "emblem-default";
                    }

                case "inactive":
                    switch (sub_state) {
                        case "dead":
                            return "media-playback-stop";
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

        private DBusProxy proxy;

        private void load_services(ResultContainer rs) {
            bool empty_string = rs.get_query().char_count() == 0;

            GLib.Variant? result;
            try {
                result = proxy.call_sync(
                    "ListUnits",
                    null,
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
                // Create owned copies of the strings we need to keep
                string owned_unit_name = unit_name;
                string owned_description = description;
                string owned_active_state = active_state;
                string owned_sub_state = sub_state;
                string owned_unit_path = unit_path;

                Threading.run(() => {
                    if (
                        !owned_unit_name.has_suffix(".service")
                        || !(empty_string || rs.has_match(owned_description) || rs.has_match(owned_unit_name))
                    ) {
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

                    Score score = empty_string ? 100 : rs.match_score(owned_unit_name);
                    uint hash = owned_unit_name.hash();
                    rs.add_lazy(hash, score + bonus, () => {
                        // Keep a reference to props_proxy in the closure
                        var closure_props_proxy = props_proxy;

                        var status_variant = get_property(closure_props_proxy, SYSTEMD_SERVICE_INTERFACE, "StatusText");
                        string status_text = status_variant != null ? status_variant.get_string().dup() : "";

                        var main_pid_variant = get_property(closure_props_proxy, SYSTEMD_SERVICE_INTERFACE, "MainPID");
                        uint main_pid = main_pid_variant != null ? main_pid_variant.get_uint32() : 0;

                        bool is_enabled = false;
                        var enabled_variant = get_property(closure_props_proxy, SYSTEMD_UNIT_INTERFACE, "UnitFileState");
                        if (enabled_variant != null) {
                            string state = enabled_variant.get_string();
                            is_enabled = (state == "enabled" || state == "enabled-runtime");
                        }

                        bool can_reload = false;
                        var can_reload_variant = get_property(closure_props_proxy, SYSTEMD_UNIT_INTERFACE, "CanReload");
                        if (can_reload_variant != null) {
                            can_reload = can_reload_variant.get_boolean();
                        }

                        bool is_masked = false;
                        var masked_variant = get_property(closure_props_proxy, SYSTEMD_UNIT_INTERFACE, "UnitFileState");
                        if (masked_variant != null) {
                            string state = masked_variant.get_string();
                            is_masked = (state == "masked" || state == "masked-runtime");
                        }

                        return new SystemdServiceMatch(
                            owned_unit_name,
                            owned_description,
                            owned_active_state,
                            owned_sub_state,
                            main_pid,
                            status_text,
                            owned_unit_path,
                            get_service_state_icon(owned_active_state, owned_sub_state),
                            bus_type,
                            is_enabled,
                            can_reload,
                            is_masked
                        );
                    });
                    Threading.atomic_dec(ref lock);
                });
            }
            while (Threading.atomic_load(ref lock) > 0) { }
        }

        public override void search(ResultContainer rs) {
            load_services(rs);
        }

        public override void find_for_match(Match match, ActionSet rs) {
            var service_match = match as SystemdServiceMatch;
            if (service_match == null) {
                return;
            }
            foreach (var action in service_actions) {
                if (action is StartServiceAction && service_match.active_state == "active") continue;
                if (action is StopServiceAction && service_match.active_state == "inactive") continue;
                if (action is EnableServiceAction && service_match.is_enabled) continue;
                if (action is DisableServiceAction && !service_match.is_enabled) continue;
                rs.add_action(action);
            }
        }

        protected override bool activate(Cancellable current_cancellable) {
            try {
                session_bus = Bus.get_sync(bus_type);
                proxy = new DBusProxy.sync(
                    session_bus,
                    DBusProxyFlags.NONE,
                    null,
                    SYSTEMD_BUSNAME,
                    SYSTEMD_PATH,
                    SYSTEMD_MANAGER_INTERFACE
                );


                return true;
            } catch (Error e) {
                warning("Error connecting to session bus: %s", e.message);
                return false;
            }
        }

        public class SystemdServiceMatch : Match {
            public string unit_name { get; construct; }
            public string active_state { get; construct; }
            public bool is_enabled { get; construct; }
            public bool can_reload { get; construct; }
            public bool is_masked { get; construct; }
            public BusType bus_type { get; construct; }

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


            public SystemdServiceMatch(
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
                bool is_masked
            ) {
                string display_text = description;
                if (status_text != "") {
                    display_text = @"$description | $status_text";
                }

                string state_info = @"State: $active_state ($sub_state)";
                if (main_pid > 0) {
                    state_info += @" | PID: $main_pid";
                }
                state_info += is_enabled ? " | Enabled" : " | Disabled";
                state_info += is_masked ? " | Masked" : "";

                Object(
                    unit_name: name,
                    active_state: active_state,
                    is_enabled: is_enabled,
                    can_reload: can_reload,
                    is_masked: is_masked,
                    bus_type: bus_type
                    // mime_type: "application/x-systemd-unit"
                );
                this.title = name;
                this.description = @"$display_text | $state_info";
                this.icon_name = icon_name;
            }
        }

        public abstract class SystemdServiceAction : Action {
            protected DBusConnection connection;
            private BusType bus_type;

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

            protected SystemdServiceAction(string title, string description, string icon_name, BusType bus_type) {
                Object();
                this.bus_type = bus_type;
                this.title = title;
                this.icon_name = icon_name;
                this.description = description;
            }

            protected void execute_systemd_action(string method, string unit_name, string mode = "replace", Variant? extra = null) {
                try {
                    connection = Bus.get_sync(bus_type);
                    var proxy = new DBusProxy.for_bus_sync(bus_type,
                        DBusProxyFlags.NONE,
                        null,
                        SYSTEMD_BUSNAME,
                        SYSTEMD_PATH,
                        SYSTEMD_MANAGER_INTERFACE,
                        null
                    );

                    if (extra != null) {
                        proxy.call_sync(method, extra, DBusCallFlags.NONE, -1, null);
                    } else {
                        proxy.call_sync(method,
                            new Variant("(ss)", unit_name, mode),
                            DBusCallFlags.NONE,
                            -1,
                            null
                        );
                    }
                    debug(@"$method executed on $unit_name");
                } catch (Error e) {
                    warning(@"Error executing $method on $unit_name: %s", e.message);
                }
            }

            public override Score get_relevancy(Match match) {
                if (!(match is SystemdServiceMatch)) {
                    return MatchScore.LOWEST;
                }

                var service_match = (SystemdServiceMatch)match;
                if (service_match.bus_type != this.bus_type) {
                    return MatchScore.LOWEST;
                }

                if (this is StartServiceAction && (service_match.active_state != "active")) {
                    return MatchScore.ABOVE_THRESHOLD;
                } else if (this is StopServiceAction && (service_match.active_state != "inactive")) {
                    return MatchScore.ABOVE_THRESHOLD;
                } else if (this is RestartServiceAction) {
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

        public class StartServiceAction : SystemdServiceAction {
            public StartServiceAction(BusType bus_type) {
                base("Start Service",
                     "Start the systemd service",
                     "media-playback-start",
                     bus_type);
            }

            public override Score get_relevancy(Match match) {
                return base.get_relevancy(match);
            }

            public override bool do_execute(Match source, Match? target = null) {
                if (source is SystemdServiceMatch) {
                    var service_match = (SystemdServiceMatch)source;
                    execute_systemd_action("StartUnit", service_match.unit_name);
                    return true;
                }
                return false;
            }
        }

        public class StopServiceAction : SystemdServiceAction {
            public StopServiceAction(BusType bus_type) {
                base("Stop Service",
                     "Stop the systemd service",
                     "media-playback-stop",
                     bus_type);
            }

            public override Score get_relevancy(Match match) {
                return base.get_relevancy(match);
            }

            public override bool do_execute(Match source, Match? target = null) {
                if (source is SystemdServiceMatch) {
                    var service_match = (SystemdServiceMatch)source;
                    execute_systemd_action("StopUnit", service_match.unit_name);
                    return true;
                }
                return false;
            }
        }

        public class RestartServiceAction : SystemdServiceAction {

            public RestartServiceAction(BusType bus_type) {
                base("Restart Service",
                     "Restart the systemd service",
                     "view-refresh",
                     bus_type);
            }

            public override Score get_relevancy(Match match) {
                return base.get_relevancy(match) + MatchScore.VERY_GOOD;
            }

            public override bool do_execute(Match source, Match? target = null) {
                if (source is SystemdServiceMatch) {
                    var service_match = (SystemdServiceMatch)source;
                    execute_systemd_action("RestartUnit", service_match.unit_name);
                    return true;
                }
                return false;
            }
        }

        public class ReloadServiceAction : SystemdServiceAction {
            public ReloadServiceAction(BusType bus_type) {
                base("Reload Service",
                     "Reload the systemd service configuration",
                     "view-refresh",
                     bus_type);
            }

            public override Score get_relevancy(Match match) {
                return base.get_relevancy(match);
            }

            public override bool do_execute(Match source, Match? target = null) {
                if (source is SystemdServiceMatch) {
                    var service_match = (SystemdServiceMatch)source;
                    execute_systemd_action("ReloadUnit", service_match.unit_name);
                    return true;
                }
                return false;
            }
        }

        public class EnableServiceAction : SystemdServiceAction {
            public EnableServiceAction(BusType bus_type) {
                base("Enable Service",
                     "Enable the service to start on boot",
                     "object-select",
                     bus_type);
            }

            public override Score get_relevancy(Match match) {
                return base.get_relevancy(match);
            }

            public override bool do_execute(Match source, Match? target = null) {
                if (source is SystemdServiceMatch) {
                    var service_match = (SystemdServiceMatch)source;
                    execute_systemd_action("EnableUnitFiles",
                        service_match.unit_name,
                        "replace",
                        new Variant("(asbb)", new string[] { service_match.unit_name }, false, false)
                    );
                    return true;
                }
                return false;
            }
        }

        public class DisableServiceAction : SystemdServiceAction {
            public DisableServiceAction(BusType bus_type) {
                base("Disable Service",
                     "Disable the service from starting on boot",
                     "window-close",
                     bus_type);
            }

            public override Score get_relevancy(Match match) {
                return base.get_relevancy(match);
            }

            public override bool do_execute(Match source, Match? target = null) {
                if (source is SystemdServiceMatch) {
                    var service_match = (SystemdServiceMatch)source;
                    execute_systemd_action("DisableUnitFiles",
                        service_match.unit_name,
                        "replace",
                        new Variant("(asb)", new string[] { service_match.unit_name }, false)
                    );
                    return true;
                }
                return false;
            }
        }

        public class EnableNowServiceAction : SystemdServiceAction {
            public EnableNowServiceAction(BusType bus_type) {
                base("Enable and Start Service",
                     "Enable the service and start it immediately",
                     "media-playback-start",
                     bus_type);
            }

            public override Score get_relevancy(Match match) {
                return base.get_relevancy(match);
            }

            public override bool do_execute(Match source, Match? target = null) {
                if (source is SystemdServiceMatch) {
                    var service_match = (SystemdServiceMatch)source;
                    // First enable the service
                    execute_systemd_action("EnableUnitFiles",
                        service_match.unit_name,
                        "replace",
                        new Variant("(asbb)", new string[] { service_match.unit_name }, false, false)
                    );
                    // Then start it
                    execute_systemd_action("StartUnit", service_match.unit_name);
                    return true;
                }
                return false;
            }
        }

        public class DisableNowServiceAction : SystemdServiceAction {
            public DisableNowServiceAction(BusType bus_type) {
                base("Disable and Stop Service",
                     "Stop the service and disable it from starting on boot",
                     "process-stop",
                     bus_type);
            }

            public override Score get_relevancy(Match match) {
                return base.get_relevancy(match);
            }

            public override bool do_execute(Match source, Match? target = null) {
                if (source is SystemdServiceMatch) {
                    var service_match = (SystemdServiceMatch)source;
                    // First stop the service
                    execute_systemd_action("StopUnit", service_match.unit_name);
                    // Then disable it
                    execute_systemd_action("DisableUnitFiles",
                        service_match.unit_name,
                        "replace",
                        new Variant("(asb)", new string[] { service_match.unit_name }, false)
                    );
                    return true;
                }
                return false;
            }
        }

        public class MaskServiceAction : SystemdServiceAction {
            public MaskServiceAction(BusType bus_type) {
                base("Mask Service",
                     "Mask the service to prevent it from being started",
                     "locked",
                     bus_type);
            }

            public override Score get_relevancy(Match match) {
                return base.get_relevancy(match);
            }

            public override bool do_execute(Match source, Match? target = null) {
                if (source is SystemdServiceMatch) {
                    var service_match = (SystemdServiceMatch)source;
                    execute_systemd_action("MaskUnitFiles",
                        service_match.unit_name,
                        "replace",
                        new Variant("(asbb)", new string[] { service_match.unit_name }, false, true)
                    );
                    return true;
                }
                return false;
            }
        }

        public class UnmaskServiceAction : SystemdServiceAction {
            public UnmaskServiceAction(BusType bus_type) {
                base("Unmask Service",
                     "Unmask the service to allow it to be started",
                     "unlock",
                     bus_type);
            }

            public override Score get_relevancy(Match match) {
                return base.get_relevancy(match);
            }

            public override bool do_execute(Match source, Match? target = null) {
                if (source is SystemdServiceMatch) {
                    var service_match = (SystemdServiceMatch)source;
                    execute_systemd_action("UnmaskUnitFiles",
                        service_match.unit_name,
                        "replace",
                        new Variant("(asb)", new string[] { service_match.unit_name }, false)
                    );
                    return true;
                }
                return false;
            }
        }
    }
}
