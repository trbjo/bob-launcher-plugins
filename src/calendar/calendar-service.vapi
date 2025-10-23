[CCode (cheader_filename = "calendar_service.h")]
namespace CalendarService {

    [CCode (cname = "CalendarEventTime", destroy_function = "", has_type_id = false, has_copy_function = false)]
    public struct CalendarEventTime {
        public time_t start;
        public time_t end;
        public bool is_all_day;
    }

    [CCode (cname = "CalendarEvent", destroy_function = "calendar_event_free", has_type_id = false, has_copy_function = false)]
    public struct Event {
        public string uid;
        public string summary;
        public CalendarEventTime time;
        public string timezone;
        public string location;
        public string description;
        public string url;
    }

    [CCode (cname = "CalendarInfo", destroy_function = "", has_type_id = false, has_copy_function = false)]
    public struct CalendarInfo {
        public char name[256];
        public char guid[256];
        public char color[32];
    }

    [CCode (cname = "CalendarService", free_function = "calendar_service_destroy", has_type_id = false)]
    [Compact]
    public class Service {
        [CCode (cname = "calendar_service_create", simple_generics = true)]
        public Service(string calendar_name, owned EventChangeCallback callback);

        [CCode (cname = "calendar_service_stop")]
        public void stop();

        [CCode (cname = "calendar_service_start")]
        public void start();

        [CCode (cname = "calendar_service_get_calendar")]
        public unowned Calendar? get_calendar(string name);

        [CCode (cname = "calendar_service_load")]
        public int load();
    }

    [CCode (cname = "Calendar", has_type_id = false)]
    [Compact]
    public class Calendar {
        [CCode (cname = "calendar_add_event")]
        public bool add_event(string summary,
                            CalendarEventTime time,
                            string? location = null,
                            string? description = null,
                            string? url = null);

        [CCode (cname = "calendar_delete_event")]
        public bool delete_event(string uid);

        [CCode (cname = "calendar_save_and_sync")]
        public bool save_and_sync();

        [CCode (cname = "calendar_update_event")]
        public bool update_event(string uid,
                                string? summary = null,
                                CalendarEventTime? event_time = null,
                                string? location = null,
                                string? description = null,
                                string? url = null);

    }



    [CCode (cname = "calendar_event_free")]
    public void event_free(Event event);

    [CCode (cname = "calendar_events_free")]
    public void events_free([CCode (array_length_pos = 1)] Event[] events);

    [CCode (has_target = true, has_type_id = false)]
    public delegate void EventChangeCallback(ref CalendarInfo calendar_info, [CCode (array_length_pos = 2)] Event[] events);
}
