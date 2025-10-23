#ifndef CALENDAR_SERVICE_H
#define CALENDAR_SERVICE_H

#include <libical/ical.h>
#include <sys/inotify.h>
#include <stdbool.h>
#include <time.h>

#define MAX_CALENDARS 32
#define MAX_PATH 512
#define MAX_EVENTS 1024
#define EVENT_BUF_LEN (1024 * (sizeof(struct inotify_event) + 16))

typedef struct CalendarEventTime {
    time_t start;
    time_t end;
    bool is_all_day;
} CalendarEventTime;

typedef struct {
    char* uid;
    char* summary;
    CalendarEventTime time;
    char* timezone;
    char* location;
    char* description;
    char* url;
} CalendarEvent;

typedef struct {
    char name[256];
    char guid[256];
    char color[32];
} CalendarInfo;

typedef struct {
    char name[256];
    char guid[256];
    char path[MAX_PATH];
    char color[32];
    icalcomponent *component;
    int watch_fd;
    CalendarEvent *cached_events;
    int cached_event_count;
} Calendar;

typedef void (*DestroyFunc)(void* user_data);
typedef void (*CallbackFunc)(const CalendarInfo* calendar_info, CalendarEvent* events, int event_count, void* user_data);

typedef struct {
    char base_path[MAX_PATH];
    Calendar calendars[MAX_CALENDARS];
    int calendar_count;
    int inotify_fd;
    int stop_pipe[2];
    bool running;
    pthread_t service_thread;
    void *user_data;
    CallbackFunc on_change;
    DestroyFunc destroy_func;
} CalendarService;

CalendarService* calendar_service_create(const char *vdirsyncer_path,
                                      CallbackFunc func,
                                      void *user_data, DestroyFunc destroy_func);

int calendar_service_load(CalendarService *service);

void calendar_service_start(CalendarService *service);

void calendar_service_stop(CalendarService *service);

Calendar* calendar_service_get_calendar(CalendarService *service, const char *name);

icalcomponent* calendar_get_first_event(Calendar *cal);
icalcomponent* calendar_get_next_event(Calendar *cal, icalcomponent *current);

bool calendar_add_event(Calendar *cal, const char *summary,
                       CalendarEventTime* event_time,
                       const char *location,
                       const char *description,
                       const char *url);

bool calendar_save_and_sync(Calendar *cal);

bool calendar_delete_event(Calendar *cal, const char *uid);

bool calendar_update_event(Calendar *cal,
                          const char *uid,
                          const char *summary,
                          const CalendarEventTime *event_time,
                          const char *location,
                          const char *description,
                          const char *url);

void calendar_event_free(CalendarEvent *event);

void calendar_events_free(CalendarEvent *events, int count);

void calendar_service_destroy(CalendarService *service);

#endif
