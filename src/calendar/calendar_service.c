#include "calendar_service.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/select.h>
#include <errno.h>
#include <pthread.h>

static char* safe_strdup(const char* str) {
    if (!str) return NULL;
    return strdup(str);
}

#define ANSI_BOLD_BLUE "\e[1;34m"
#define ANSI_RESET     "\e[0m"

static const char* identifier = ANSI_BOLD_BLUE "CALENDAR" ANSI_RESET " ";

#define DEBUG_PRINT 0

#define printf_debug(...) \
    do { \
        if (DEBUG_PRINT) { \
            printf("%s", identifier); \
            printf(__VA_ARGS__); \
            printf("\n"); \
        } \
    } while(0)

static char* read_file(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return NULL;

    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);

    char *content = malloc(size + 1);
    fread(content, 1, size, f);
    content[size] = '\0';

    fclose(f);
    return content;
}

static bool write_file(const char *path, const char *content) {
    FILE *f = fopen(path, "w");
    if (!f) return false;

    fputs(content, f);
    fclose(f);
    return true;
}

static void run_vdirsyncer_sync() {
    printf_debug("Running vdirsyncer sync...");
    int ret = system("vdirsyncer sync");
    if (ret != 0) {
        fprintf(stderr, "Warning: vdirsyncer sync failed with code %d\n", ret);
    }
}

void calendar_event_free(CalendarEvent *event) {
    if (!event) return;

    free(event->uid);
    free(event->summary);
    free(event->timezone);
    free(event->location);
    free(event->description);
    free(event->url);

    event->uid = NULL;
    event->summary = NULL;
    event->timezone = NULL;
    event->location = NULL;
    event->description = NULL;
    event->url = NULL;
}

void calendar_events_free(CalendarEvent *events, int count) {
    if (!events) return;

    for (int i = 0; i < count; i++) {
        calendar_event_free(&events[i]);
    }
    free(events);
}

static bool str_equal(const char *a, const char *b) {
    if (a == NULL && b == NULL) return true;
    if (a == NULL || b == NULL) return false;
    return strcmp(a, b) == 0;
}

static void extract_events_from_component(icalcomponent *comp, CalendarEvent **events, int *count) {
    *count = 0;
    *events = malloc(sizeof(CalendarEvent) * MAX_EVENTS);

    icalcomponent *vevent = icalcomponent_get_first_component(comp, ICAL_VEVENT_COMPONENT);
    while (vevent && *count < MAX_EVENTS) {
        CalendarEvent *evt = &(*events)[*count];

        memset(evt, 0, sizeof(CalendarEvent));

        icalproperty *uid_prop = icalcomponent_get_first_property(vevent, ICAL_UID_PROPERTY);
        if (uid_prop) {
            evt->uid = safe_strdup(icalproperty_get_uid(uid_prop));
        }

        icalproperty *summary_prop = icalcomponent_get_first_property(vevent, ICAL_SUMMARY_PROPERTY);
        if (summary_prop) {
            evt->summary = safe_strdup(icalproperty_get_summary(summary_prop));
        }

        icalproperty *location_prop = icalcomponent_get_first_property(vevent, ICAL_LOCATION_PROPERTY);
        if (location_prop) {
            const char *loc = icalproperty_get_location(location_prop);
            if (loc) {
                evt->location = safe_strdup(loc);
            }
        }

        icalproperty *description_prop = icalcomponent_get_first_property(vevent, ICAL_DESCRIPTION_PROPERTY);
        if (description_prop) {
            const char *desc = icalproperty_get_description(description_prop);
            if (desc) {
                evt->description = safe_strdup(desc);
            }
        }

        icalproperty *url_prop = icalcomponent_get_first_property(vevent, ICAL_URL_PROPERTY);
        if (url_prop) {
            const char *url_val = icalproperty_get_url(url_prop);
            if (url_val) {
                evt->url = safe_strdup(url_val);
            }
        }

        icalproperty *dtstart_prop = icalcomponent_get_first_property(vevent, ICAL_DTSTART_PROPERTY);
        if (dtstart_prop) {
            struct icaltimetype dtstart = icalproperty_get_dtstart(dtstart_prop);

            evt->time.is_all_day = dtstart.is_date;

            icalparameter *tzid_param = icalproperty_get_first_parameter(dtstart_prop, ICAL_TZID_PARAMETER);
            if (tzid_param) {
                const char *tzid = icalparameter_get_tzid(tzid_param);
                if (tzid) {
                    evt->timezone = safe_strdup(tzid);

                    icaltimezone *zone = icalcomponent_get_timezone(comp, tzid);
                    if (!zone) {
                        zone = icaltimezone_get_builtin_timezone(tzid);
                    }
                    if (zone) {
                        dtstart.zone = zone;
                    }
                }
            }

            evt->time.start = icaltime_as_timet_with_zone(dtstart, dtstart.zone);
        }

        icalproperty *dtend_prop = icalcomponent_get_first_property(vevent, ICAL_DTEND_PROPERTY);
        if (dtend_prop) {
            struct icaltimetype dtend = icalproperty_get_dtend(dtend_prop);

            icalparameter *tzid_param = icalproperty_get_first_parameter(dtend_prop, ICAL_TZID_PARAMETER);
            if (tzid_param) {
                const char *tzid = icalparameter_get_tzid(tzid_param);
                if (tzid) {
                    icaltimezone *zone = icalcomponent_get_timezone(comp, tzid);
                    if (!zone) {
                        zone = icaltimezone_get_builtin_timezone(tzid);
                    }
                    if (zone) {
                        dtend.zone = zone;
                    }
                }
            }

            evt->time.end = icaltime_as_timet_with_zone(dtend, dtend.zone);
        }

        (*count)++;
        vevent = icalcomponent_get_next_component(comp, ICAL_VEVENT_COMPONENT);
    }
}

static bool events_differ(CalendarEvent *old_events, int old_count,
                         CalendarEvent *new_events, int new_count) {
    if (old_count != new_count) return true;

    for (int i = 0; i < new_count; i++) {
        bool found = false;
        for (int j = 0; j < old_count; j++) {
            if (str_equal(new_events[i].uid, old_events[j].uid) &&
                str_equal(new_events[i].summary, old_events[j].summary) &&
                str_equal(new_events[i].location, old_events[j].location) &&
                str_equal(new_events[i].description, old_events[j].description) &&
                str_equal(new_events[i].url, old_events[j].url) &&
                new_events[i].time.is_all_day == old_events[j].time.is_all_day &&
                new_events[i].time.start == old_events[j].time.start &&
                new_events[i].time.end == old_events[j].time.end) {
                found = true;
                break;
            }
        }
        if (!found) return true;
    }
    return false;
}

static void read_calendar_displayname(const char *cal_path, char *displayname, size_t size) {
    char displayname_path[MAX_PATH];
    snprintf(displayname_path, MAX_PATH, "%s/displayname", cal_path);

    FILE *f = fopen(displayname_path, "r");
    if (f) {
        if (fgets(displayname, size, f)) {
            char *newline = strchr(displayname, '\n');
            if (newline) *newline = '\0';
        }
        fclose(f);
        return;
    }

    const char *slash = strrchr(cal_path, '/');
    if (slash) {
        strncpy(displayname, slash + 1, size - 1);
    }
}

static void read_calendar_color(const char *cal_path, char *color, size_t size) {
    char color_path[MAX_PATH];
    snprintf(color_path, MAX_PATH, "%s/color", cal_path);

    FILE *f = fopen(color_path, "r");
    if (f) {
        if (fgets(color, size, f)) {
            char *newline = strchr(color, '\n');
            if (newline) *newline = '\0';
        }
        fclose(f);
        return;
    }

    strncpy(color, "#3B82F6", size - 1);
}

static void load_calendar(CalendarService *service, const char *cal_guid) {
    if (service->calendar_count >= MAX_CALENDARS) return;

    char cal_path[MAX_PATH];
    snprintf(cal_path, MAX_PATH, "%s/%s", service->base_path, cal_guid);

    struct stat st;
    if (stat(cal_path, &st) != 0 || !S_ISDIR(st.st_mode)) return;

    icalcomponent *master_cal = icalcomponent_new_vcalendar();
    icalcomponent_add_property(master_cal, icalproperty_new_version("2.0"));
    icalcomponent_add_property(master_cal, icalproperty_new_prodid("-//CalendarService//EN"));

    DIR *dir = opendir(cal_path);
    if (!dir) {
        icalcomponent_free(master_cal);
        return;
    }

    struct dirent *entry;
    int event_count = 0;

    while ((entry = readdir(dir))) {
        if (!strstr(entry->d_name, ".ics")) continue;

        char ics_path[MAX_PATH];
        snprintf(ics_path, MAX_PATH, "%s/%s", cal_path, entry->d_name);

        char *content = read_file(ics_path);
        if (!content) continue;

        icalcomponent *file_cal = icalparser_parse_string(content);
        free(content);

        if (!file_cal) continue;

        icalcomponent *vtimezone = icalcomponent_get_first_component(file_cal, ICAL_VTIMEZONE_COMPONENT);
        while (vtimezone) {
            icalcomponent *tz_copy = icalcomponent_new_clone(vtimezone);
            icalcomponent_add_component(master_cal, tz_copy);
            vtimezone = icalcomponent_get_next_component(file_cal, ICAL_VTIMEZONE_COMPONENT);
        }

        icalcomponent *vevent = icalcomponent_get_first_component(file_cal, ICAL_VEVENT_COMPONENT);
        while (vevent) {
            icalcomponent *event_copy = icalcomponent_new_clone(vevent);
            icalcomponent_add_component(master_cal, event_copy);
            event_count++;
            vevent = icalcomponent_get_next_component(file_cal, ICAL_VEVENT_COMPONENT);
        }

        icalcomponent_free(file_cal);
    }
    closedir(dir);

    if (event_count == 0) {
        icalcomponent_free(master_cal);
        return;
    }

    Calendar *cal = &service->calendars[service->calendar_count];
    read_calendar_displayname(cal_path, cal->name, sizeof(cal->name));
    read_calendar_color(cal_path, cal->color, sizeof(cal->color));
    strncpy(cal->guid, cal_guid, sizeof(cal->guid) - 1);
    strncpy(cal->path, cal_path, sizeof(cal->path) - 1);
    cal->component = master_cal;

    extract_events_from_component(master_cal, &cal->cached_events, &cal->cached_event_count);

    cal->watch_fd = inotify_add_watch(service->inotify_fd, cal_path,
                                      IN_MODIFY | IN_CREATE | IN_DELETE);

    service->calendar_count++;
    printf_debug("Loaded: %s (color: %s, %d events, guid: %s)",
           cal->name, cal->color, event_count, cal->guid);
}

static void create_calendar_info(const Calendar *cal, CalendarInfo *info) {
    strncpy(info->name, cal->name, sizeof(info->name) - 1);
    strncpy(info->guid, cal->guid, sizeof(info->guid) - 1);
    strncpy(info->color, cal->color, sizeof(info->color) - 1);
}

void calendar_service_trigger_initial_callbacks(CalendarService *service) {
    if (!service || !service->on_change) return;

    for (int i = 0; i < service->calendar_count; i++) {
        Calendar *cal = &service->calendars[i];
        if (cal->cached_events && cal->cached_event_count > 0) {
            CalendarInfo info;
            create_calendar_info(cal, &info);
            service->on_change(&info, cal->cached_events, cal->cached_event_count, service->user_data);
        }
    }
}

CalendarService* calendar_service_init(const char *vdirsyncer_path,
                                       CallbackFunc callback,
                                      void *user_data, DestroyFunc destroy_func) {
    CalendarService *service = calloc(1, sizeof(CalendarService));
    strncpy(service->base_path, vdirsyncer_path, sizeof(service->base_path) - 1);
    service->on_change = callback;
    service->user_data = user_data;
    service->destroy_func = destroy_func;

    service->inotify_fd = inotify_init();
    if (service->inotify_fd < 0) {
        perror("inotify_init");
        free(service);
        return NULL;
    }

    if (pipe(service->stop_pipe) < 0) {
        perror("pipe");
        close(service->inotify_fd);
        free(service);
        return NULL;
    }

    service->running = false;
    return service;
}

int calendar_service_load(CalendarService *service) {
    DIR *dir = opendir(service->base_path);
    if (!dir) {
        perror("opendir");
        return -1;
    }

    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (entry->d_name[0] == '.') continue;
        load_calendar(service, entry->d_name);
    }

    closedir(dir);
    return service->calendar_count;
}

static void* service_thread(void* arg) {
    CalendarService* service = (CalendarService*)arg;

    service->running = true;
    char buf[EVENT_BUF_LEN];

    printf_debug("Service started, monitoring %d calendars",
           service->calendar_count);

    while (service->running) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(service->inotify_fd, &fds);
        FD_SET(service->stop_pipe[0], &fds);

        int max_fd = (service->inotify_fd > service->stop_pipe[0]) ?
                     service->inotify_fd : service->stop_pipe[0];

        int ret = select(max_fd + 1, &fds, NULL, NULL, NULL);
        if (ret < 0) {
            if (errno == EINTR) continue;
            perror("select");
            break;
        }

        if (FD_ISSET(service->stop_pipe[0], &fds)) {
            printf_debug("Stop signal received");
            break;
        }

        if (FD_ISSET(service->inotify_fd, &fds)) {
            int length = read(service->inotify_fd, buf, EVENT_BUF_LEN);
            if (length < 0) {
                perror("read");
                break;
            }

            int i = 0;
            while (i < length) {
                struct inotify_event *event = (struct inotify_event *)&buf[i];

                for (int j = 0; j < service->calendar_count; j++) {
                    if (service->calendars[j].watch_fd == event->wd) {
                        Calendar *cal = &service->calendars[j];
                        printf_debug("'%s' modified, checking for changes...", cal->name);

                        icalcomponent *new_master_cal = icalcomponent_new_vcalendar();
                        icalcomponent_add_property(new_master_cal, icalproperty_new_version("2.0"));
                        icalcomponent_add_property(new_master_cal, icalproperty_new_prodid("-//CalendarService//EN"));

                        DIR *reload_dir = opendir(cal->path);
                        if (reload_dir) {
                            struct dirent *reload_entry;

                            while ((reload_entry = readdir(reload_dir))) {
                                if (!strstr(reload_entry->d_name, ".ics")) continue;

                                char reload_ics_path[MAX_PATH];
                                snprintf(reload_ics_path, MAX_PATH, "%s/%s", cal->path, reload_entry->d_name);

                                char *content = read_file(reload_ics_path);
                                if (!content) continue;

                                icalcomponent *file_cal = icalparser_parse_string(content);
                                free(content);

                                if (!file_cal) continue;

                                icalcomponent *vtimezone = icalcomponent_get_first_component(file_cal, ICAL_VTIMEZONE_COMPONENT);
                                while (vtimezone) {
                                    icalcomponent *tz_copy = icalcomponent_new_clone(vtimezone);
                                    icalcomponent_add_component(new_master_cal, tz_copy);
                                    vtimezone = icalcomponent_get_next_component(file_cal, ICAL_VTIMEZONE_COMPONENT);
                                }

                                icalcomponent *vevent = icalcomponent_get_first_component(file_cal, ICAL_VEVENT_COMPONENT);
                                while (vevent) {
                                    icalcomponent *event_copy = icalcomponent_new_clone(vevent);
                                    icalcomponent_add_component(new_master_cal, event_copy);
                                    vevent = icalcomponent_get_next_component(file_cal, ICAL_VEVENT_COMPONENT);
                                }

                                icalcomponent_free(file_cal);
                            }
                            closedir(reload_dir);
                        }

                        CalendarEvent *new_events;
                        int new_count;
                        extract_events_from_component(new_master_cal, &new_events, &new_count);

                        if (events_differ(cal->cached_events, cal->cached_event_count,
                                         new_events, new_count)) {
                            if (service->on_change) {
                                CalendarInfo info;
                                create_calendar_info(cal, &info);
                                service->on_change(&info, new_events, new_count, service->user_data);
                            }

                            calendar_events_free(cal->cached_events, cal->cached_event_count);
                            cal->cached_events = new_events;
                            cal->cached_event_count = new_count;
                        } else {
                            calendar_events_free(new_events, new_count);
                        }

                        icalcomponent_free(cal->component);
                        cal->component = new_master_cal;
                        break;
                    }
                }

                i += sizeof(struct inotify_event) + event->len;
            }
        }
    }

    return NULL;
}

void calendar_service_start(CalendarService *service) {
    pthread_create(&service->service_thread, NULL, service_thread, service);
}

void calendar_service_stop(CalendarService *service) {
    service->running = false;
    write(service->stop_pipe[1], "x", 1);
    pthread_join(service->service_thread, NULL);
}

Calendar* calendar_service_get_calendar(CalendarService *service, const char *name) {
    for (int i = 0; i < service->calendar_count; i++) {
        if (strcmp(service->calendars[i].name, name) == 0) {
            return &service->calendars[i];
        }
    }
    return NULL;
}

icalcomponent* calendar_get_first_event(Calendar *cal) {
    if (!cal || !cal->component) return NULL;
    return icalcomponent_get_first_component(cal->component, ICAL_VEVENT_COMPONENT);
}

icalcomponent* calendar_get_next_event(Calendar *cal, icalcomponent *current) {
    if (!cal || !cal->component || !current) return NULL;
    return icalcomponent_get_next_component(cal->component, ICAL_VEVENT_COMPONENT);
}

bool calendar_add_event(Calendar *cal, const char *summary,
                       CalendarEventTime* event_time,
                       const char *location,
                       const char *description,
                       const char *url) {
    if (!cal || !cal->component) return false;

    icalcomponent *event = icalcomponent_new_vevent();

    icalcomponent_add_property(event, icalproperty_new_summary(summary));

    struct icaltimetype dtstart, dtend;

    if (event_time->is_all_day) {
        dtstart = icaltime_from_timet_with_zone(event_time->start, 1, NULL);
        dtend = icaltime_from_timet_with_zone(event_time->end, 1, NULL);
    } else {
        dtstart = icaltime_from_timet_with_zone(event_time->start, 0, NULL);
        dtend = icaltime_from_timet_with_zone(event_time->end, 0, NULL);
    }

    icalcomponent_add_property(event, icalproperty_new_dtstart(dtstart));
    icalcomponent_add_property(event, icalproperty_new_dtend(dtend));

    if (location && location[0] != '\0') {
        icalcomponent_add_property(event, icalproperty_new_location(location));
    }

    if (description && description[0] != '\0') {
        icalcomponent_add_property(event, icalproperty_new_description(description));
    }

    if (url && url[0] != '\0') {
        icalcomponent_add_property(event, icalproperty_new_url(url));
    }

    char uid[128];
    snprintf(uid, sizeof(uid), "%ld@localhost", (long)time(NULL));
    icalcomponent_add_property(event, icalproperty_new_uid(uid));

    icalcomponent_add_property(event, icalproperty_new_dtstamp(icaltime_current_time_with_zone(NULL)));

    icalcomponent_add_component(cal->component, event);

    icalcomponent *single_cal = icalcomponent_new_vcalendar();
    icalcomponent_add_property(single_cal, icalproperty_new_version("2.0"));
    icalcomponent_add_property(single_cal, icalproperty_new_prodid("-//CalendarService//EN"));

    icalcomponent *event_copy = icalcomponent_new_clone(event);
    icalcomponent_add_component(single_cal, event_copy);

    char event_path[MAX_PATH];
    snprintf(event_path, MAX_PATH, "%s/%s.ics", cal->path, uid);

    char *ical_str = icalcomponent_as_ical_string(single_cal);
    bool result = write_file(event_path, ical_str);

    icalcomponent_free(single_cal);

    return result;
}

bool calendar_delete_event(Calendar *cal, const char *uid) {
    if (!cal || !cal->component || !uid || uid[0] == '\0') return false;

    icalcomponent *vevent = icalcomponent_get_first_component(cal->component, ICAL_VEVENT_COMPONENT);
    icalcomponent *target_event = NULL;

    while (vevent) {
        icalproperty *uid_prop = icalcomponent_get_first_property(vevent, ICAL_UID_PROPERTY);
        if (uid_prop) {
            const char *event_uid = icalproperty_get_uid(uid_prop);
            if (event_uid && strcmp(event_uid, uid) == 0) {
                target_event = vevent;
                break;
            }
        }
        vevent = icalcomponent_get_next_component(cal->component, ICAL_VEVENT_COMPONENT);
    }

    if (!target_event) {
        fprintf(stderr, "Event with UID '%s' not found\n", uid);
        return false;
    }

    icalcomponent_remove_component(cal->component, target_event);
    icalcomponent_free(target_event);

    char event_path[MAX_PATH];
    snprintf(event_path, MAX_PATH, "%s/%s.ics", cal->path, uid);

    if (unlink(event_path) != 0) {
        fprintf(stderr, "Warning: Could not delete file %s: %s\n", event_path, strerror(errno));
    } else {
        printf_debug("Deleted event file: %s", event_path);
    }

    run_vdirsyncer_sync();

    return true;
}

bool calendar_update_event(Calendar *cal,
                          const char *uid,
                          const char *summary,
                          const CalendarEventTime *event_time,
                          const char *location,
                          const char *description,
                          const char *url) {
    if (!cal || !cal->component || !uid || uid[0] == '\0') return false;

    // Find the event
    icalcomponent *vevent = icalcomponent_get_first_component(cal->component, ICAL_VEVENT_COMPONENT);
    icalcomponent *target_event = NULL;

    while (vevent) {
        icalproperty *uid_prop = icalcomponent_get_first_property(vevent, ICAL_UID_PROPERTY);
        if (uid_prop) {
            const char *event_uid = icalproperty_get_uid(uid_prop);
            if (event_uid && strcmp(event_uid, uid) == 0) {
                target_event = vevent;
                break;
            }
        }
        vevent = icalcomponent_get_next_component(cal->component, ICAL_VEVENT_COMPONENT);
    }

    if (!target_event) {
        fprintf(stderr, "Event with UID '%s' not found\n", uid);
        return false;
    }

    // Update SUMMARY if provided
    if (summary) {
        icalproperty *summary_prop = icalcomponent_get_first_property(target_event, ICAL_SUMMARY_PROPERTY);
        if (summary_prop) {
            icalcomponent_remove_property(target_event, summary_prop);
            icalproperty_free(summary_prop);
        }
        icalcomponent_add_property(target_event, icalproperty_new_summary(summary));
    }

    // Update DTSTART and DTEND if provided
    if (event_time) {
        // Remove old DTSTART
        icalproperty *dtstart_prop = icalcomponent_get_first_property(target_event, ICAL_DTSTART_PROPERTY);
        if (dtstart_prop) {
            icalcomponent_remove_property(target_event, dtstart_prop);
            icalproperty_free(dtstart_prop);
        }

        // Remove old DTEND
        icalproperty *dtend_prop = icalcomponent_get_first_property(target_event, ICAL_DTEND_PROPERTY);
        if (dtend_prop) {
            icalcomponent_remove_property(target_event, dtend_prop);
            icalproperty_free(dtend_prop);
        }

        // Add new DTSTART and DTEND
        struct icaltimetype dtstart, dtend;

        if (event_time->is_all_day) {
            dtstart = icaltime_from_timet_with_zone(event_time->start, 1, NULL);
            dtend = icaltime_from_timet_with_zone(event_time->end, 1, NULL);
        } else {
            dtstart = icaltime_from_timet_with_zone(event_time->start, 0, NULL);
            dtend = icaltime_from_timet_with_zone(event_time->end, 0, NULL);
        }

        icalcomponent_add_property(target_event, icalproperty_new_dtstart(dtstart));
        icalcomponent_add_property(target_event, icalproperty_new_dtend(dtend));
    }

    // Update LOCATION if provided
    if (location) {
        icalproperty *location_prop = icalcomponent_get_first_property(target_event, ICAL_LOCATION_PROPERTY);
        if (location_prop) {
            icalcomponent_remove_property(target_event, location_prop);
            icalproperty_free(location_prop);
        }
        if (location[0] != '\0') {
            icalcomponent_add_property(target_event, icalproperty_new_location(location));
        }
    }

    // Update DESCRIPTION if provided
    if (description) {
        icalproperty *description_prop = icalcomponent_get_first_property(target_event, ICAL_DESCRIPTION_PROPERTY);
        if (description_prop) {
            icalcomponent_remove_property(target_event, description_prop);
            icalproperty_free(description_prop);
        }
        if (description[0] != '\0') {
            icalcomponent_add_property(target_event, icalproperty_new_description(description));
        }
    }

    // Update URL if provided
    if (url) {
        icalproperty *url_prop = icalcomponent_get_first_property(target_event, ICAL_URL_PROPERTY);
        if (url_prop) {
            icalcomponent_remove_property(target_event, url_prop);
            icalproperty_free(url_prop);
        }
        if (url[0] != '\0') {
            icalcomponent_add_property(target_event, icalproperty_new_url(url));
        }
    }

    // Update DTSTAMP to mark modification
    icalproperty *dtstamp_prop = icalcomponent_get_first_property(target_event, ICAL_DTSTAMP_PROPERTY);
    if (dtstamp_prop) {
        icalcomponent_remove_property(target_event, dtstamp_prop);
        icalproperty_free(dtstamp_prop);
    }
    icalcomponent_add_property(target_event, icalproperty_new_dtstamp(icaltime_current_time_with_zone(NULL)));

    // Write updated event to disk
    icalcomponent *single_cal = icalcomponent_new_vcalendar();
    icalcomponent_add_property(single_cal, icalproperty_new_version("2.0"));
    icalcomponent_add_property(single_cal, icalproperty_new_prodid("-//CalendarService//EN"));

    icalcomponent *event_copy = icalcomponent_new_clone(target_event);
    icalcomponent_add_component(single_cal, event_copy);

    char event_path[MAX_PATH];
    snprintf(event_path, MAX_PATH, "%s/%s.ics", cal->path, uid);

    char *ical_str = icalcomponent_as_ical_string(single_cal);
    bool result = write_file(event_path, ical_str);

    icalcomponent_free(single_cal);

    if (result) {
        printf_debug("Updated event: %s", uid);
        run_vdirsyncer_sync();
    }

    return result;
}

bool calendar_save_and_sync(Calendar *cal) {
    if (!cal || !cal->component) return false;

    run_vdirsyncer_sync();

    return true;
}

void calendar_service_destroy(CalendarService *service) {

    if (!service) return;
    service->destroy_func(service->user_data);

    for (int i = 0; i < service->calendar_count; i++) {
        if (service->calendars[i].watch_fd >= 0) {
            inotify_rm_watch(service->inotify_fd, service->calendars[i].watch_fd);
        }
        if (service->calendars[i].component) {
            icalcomponent_free(service->calendars[i].component);
        }
        if (service->calendars[i].cached_events) {
            calendar_events_free(service->calendars[i].cached_events,
                               service->calendars[i].cached_event_count);
        }
    }

    if (service->inotify_fd >= 0) {
        close(service->inotify_fd);
    }

    close(service->stop_pipe[0]);
    close(service->stop_pipe[1]);

    free(service);
}

void event_change_callback(void *user_data, const CalendarInfo *cal_info,
                          CalendarEvent *events, int event_count) {
    printf_debug("=== '%s' changed ===", cal_info->name);
    printf_debug("Color: %s, GUID: %s", cal_info->color, cal_info->guid);
    printf_debug("Total events: %d", event_count);

    for (int i = 0; i < event_count; i++) {
        char start_buf[64], end_buf[64];

        if (events[i].time.is_all_day) {
            strftime(start_buf, sizeof(start_buf), "%Y-%m-%d", localtime(&events[i].time.start));
            strftime(end_buf, sizeof(end_buf), "%Y-%m-%d", localtime(&events[i].time.end));
            printf_debug("  [%d] %s (ALL DAY)", i + 1, events[i].summary ? events[i].summary : "(no title)");
        } else {
            strftime(start_buf, sizeof(start_buf), "%Y-%m-%d %H:%M", localtime(&events[i].time.start));
            strftime(end_buf, sizeof(end_buf), "%Y-%m-%d %H:%M", localtime(&events[i].time.end));
            printf_debug("  [%d] %s", i + 1, events[i].summary ? events[i].summary : "(no title)");
        }

        printf_debug("      UID: %s", events[i].uid ? events[i].uid : "(none)");
        printf_debug("      Time: %s - %s", start_buf, end_buf);

        if (events[i].location) {
            printf_debug("      Location: %s", events[i].location);
        }

        if (events[i].description) {
            printf_debug("      Description: %s", events[i].description);
        }

        if (events[i].url) {
            printf_debug("      URL: %s", events[i].url);
        }
    }
    printf_debug("=============================");
}

CalendarService* calendar_service_create(const char *calendar_name,
                                        CallbackFunc callback,
                                        void *user_data, DestroyFunc destroy_func) {
    char cal_path[MAX_PATH];
    const char *home = getenv("HOME");
    if (!home) {
        fprintf(stderr, "HOME environment variable not set\n");
        return NULL;
    }
    snprintf(cal_path, MAX_PATH, "%s/.local/share/calendars/%s", home, calendar_name);

    CalendarService *service = calendar_service_init(cal_path, callback, user_data, destroy_func);
    if (!service) {
        fprintf(stderr, "Failed to initialize service\n");
        return NULL;
    }

    int count = calendar_service_load(service);

    calendar_service_trigger_initial_callbacks(service);

    return service;
}
