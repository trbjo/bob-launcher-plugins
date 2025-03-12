#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <limits.h>
#include <errno.h>
#include <libgen.h>
#include "file-monitor.h"

#define EVENT_BUF_LEN     (10 * (sizeof(struct inotify_event) + NAME_MAX + 1))
#define WATCH_FLAGS       (IN_MODIFY | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO)

// Callback function type definition
typedef void (*file_change_callback)(const char* path, int event_type, void* user_data);

// Structure to hold information about a monitored file
typedef struct {
    char* filename;           // Just the filename part
    char* full_path;          // Full path to the file
    file_change_callback callback;
    void* user_data;
} monitored_file_t;

// Structure to hold information about a watched directory
typedef struct {
    char* dir_path;           // Path to the directory
    int watch_descriptor;     // inotify watch descriptor
    monitored_file_t** files; // Array of monitored files in this directory
    int file_count;           // Number of files being monitored
    int file_capacity;        // Capacity of the files array
} directory_watch_t;

// Main file monitor structure
typedef struct {
    int inotify_fd;                   // inotify file descriptor
    pthread_t watch_thread;           // Thread for monitoring events
    pthread_mutex_t lock;             // Mutex for thread safety
    int running;                      // Flag to control the watch thread
    directory_watch_t** directories;  // Array of watched directories
    int dir_count;                    // Number of directories being watched
    int dir_capacity;                 // Capacity of the directories array
} file_monitor_t;

// Global file monitor instance
static file_monitor_t* monitor = NULL;

// Forward declarations
static void* watch_thread_func(void* arg);
static directory_watch_t* find_directory_watch(const char* dir_path);
static directory_watch_t* add_directory_watch(const char* dir_path);
static monitored_file_t* find_monitored_file(directory_watch_t* dir_watch, const char* filename);
static void add_monitored_file(directory_watch_t* dir_watch, const char* filename,
                              const char* full_path, file_change_callback callback, void* user_data);
static void remove_monitored_file(directory_watch_t* dir_watch, const char* filename);
static void cleanup_directory_watch(directory_watch_t* dir_watch);

// Initialize the file monitor
static int init_file_monitor() {
    if (monitor != NULL) {
        return 0; // Already initialized
    }

    monitor = (file_monitor_t*)malloc(sizeof(file_monitor_t));
    if (!monitor) {
        return -1;
    }

    // Initialize inotify
    monitor->inotify_fd = inotify_init1(IN_NONBLOCK);
    if (monitor->inotify_fd == -1) {
        free(monitor);
        monitor = NULL;
        return -1;
    }

    // Initialize mutex
    if (pthread_mutex_init(&monitor->lock, NULL) != 0) {
        close(monitor->inotify_fd);
        free(monitor);
        monitor = NULL;
        return -1;
    }

    // Initialize directory array
    monitor->dir_capacity = 10;
    monitor->dir_count = 0;
    monitor->directories = (directory_watch_t**)malloc(
        monitor->dir_capacity * sizeof(directory_watch_t*));

    if (!monitor->directories) {
        pthread_mutex_destroy(&monitor->lock);
        close(monitor->inotify_fd);
        free(monitor);
        monitor = NULL;
        return -1;
    }

    // Start the watch thread
    monitor->running = 1;
    if (pthread_create(&monitor->watch_thread, NULL, watch_thread_func, NULL) != 0) {
        free(monitor->directories);
        pthread_mutex_destroy(&monitor->lock);
        close(monitor->inotify_fd);
        free(monitor);
        monitor = NULL;
        return -1;
    }

    return 0;
}

// Clean up the file monitor
static void cleanup_file_monitor() {
    if (!monitor) {
        return;
    }

    // Stop the watch thread
    monitor->running = 0;
    pthread_join(monitor->watch_thread, NULL);

    // Clean up all directory watches
    for (int i = 0; i < monitor->dir_count; i++) {
        cleanup_directory_watch(monitor->directories[i]);
    }
    free(monitor->directories);

    // Clean up the monitor
    pthread_mutex_destroy(&monitor->lock);
    close(monitor->inotify_fd);
    free(monitor);
    monitor = NULL;
}

// Watch thread function
static void* watch_thread_func(void* arg) {
    char buffer[EVENT_BUF_LEN];

    while (monitor->running) {
        // Read events from inotify
        ssize_t len = read(monitor->inotify_fd, buffer, EVENT_BUF_LEN);

        if (len == -1) {
            if (errno == EAGAIN) {
                // No events available, sleep a bit
                usleep(100000); // 100ms
                continue;
            }
            // Error occurred
            break;
        }

        // Process events
        pthread_mutex_lock(&monitor->lock);

        ssize_t i = 0;
        while (i < len) {
            struct inotify_event* event = (struct inotify_event*)&buffer[i];

            // Find the directory watch for this watch descriptor
            directory_watch_t* dir_watch = NULL;
            for (int j = 0; j < monitor->dir_count; j++) {
                if (monitor->directories[j]->watch_descriptor == event->wd) {
                    dir_watch = monitor->directories[j];
                    break;
                }
            }

            if (dir_watch && event->len > 0) {
                // Find the monitored file
                monitored_file_t* file = find_monitored_file(dir_watch, event->name);

                if (file) {
                    // Call the callback
                    file->callback(file->full_path, event->mask, file->user_data);
                }
            }

            i += sizeof(struct inotify_event) + event->len;
        }

        pthread_mutex_unlock(&monitor->lock);
    }

    return NULL;
}

// Find a directory watch by path
static directory_watch_t* find_directory_watch(const char* dir_path) {
    for (int i = 0; i < monitor->dir_count; i++) {
        if (strcmp(monitor->directories[i]->dir_path, dir_path) == 0) {
            return monitor->directories[i];
        }
    }
    return NULL;
}

// Add a new directory watch
static directory_watch_t* add_directory_watch(const char* dir_path) {
    // Check if we need to resize the directories array
    if (monitor->dir_count >= monitor->dir_capacity) {
        int new_capacity = monitor->dir_capacity * 2;
        directory_watch_t** new_dirs = (directory_watch_t**)realloc(
            monitor->directories, new_capacity * sizeof(directory_watch_t*));

        if (!new_dirs) {
            return NULL;
        }

        monitor->directories = new_dirs;
        monitor->dir_capacity = new_capacity;
    }

    // Add the inotify watch
    int wd = inotify_add_watch(monitor->inotify_fd, dir_path, WATCH_FLAGS);
    if (wd == -1) {
        return NULL;
    }

    // Create the directory watch
    directory_watch_t* dir_watch = (directory_watch_t*)malloc(sizeof(directory_watch_t));
    if (!dir_watch) {
        inotify_rm_watch(monitor->inotify_fd, wd);
        return NULL;
    }

    dir_watch->dir_path = strdup(dir_path);
    dir_watch->watch_descriptor = wd;
    dir_watch->file_capacity = 10;
    dir_watch->file_count = 0;
    dir_watch->files = (monitored_file_t**)malloc(
        dir_watch->file_capacity * sizeof(monitored_file_t*));

    if (!dir_watch->dir_path || !dir_watch->files) {
        if (dir_watch->dir_path) free(dir_watch->dir_path);
        if (dir_watch->files) free(dir_watch->files);
        free(dir_watch);
        inotify_rm_watch(monitor->inotify_fd, wd);
        return NULL;
    }

    // Add to the directories array
    monitor->directories[monitor->dir_count++] = dir_watch;

    return dir_watch;
}

// Find a monitored file in a directory watch
static monitored_file_t* find_monitored_file(directory_watch_t* dir_watch, const char* filename) {
    for (int i = 0; i < dir_watch->file_count; i++) {
        if (strcmp(dir_watch->files[i]->filename, filename) == 0) {
            return dir_watch->files[i];
        }
    }
    return NULL;
}

// Add a monitored file to a directory watch
static void add_monitored_file(directory_watch_t* dir_watch, const char* filename,
                              const char* full_path, file_change_callback callback, void* user_data) {
    // Check if we need to resize the files array
    if (dir_watch->file_count >= dir_watch->file_capacity) {
        int new_capacity = dir_watch->file_capacity * 2;
        monitored_file_t** new_files = (monitored_file_t**)realloc(
            dir_watch->files, new_capacity * sizeof(monitored_file_t*));

        if (!new_files) {
            return;
        }

        dir_watch->files = new_files;
        dir_watch->file_capacity = new_capacity;
    }

    // Create the monitored file
    monitored_file_t* file = (monitored_file_t*)malloc(sizeof(monitored_file_t));
    if (!file) {
        return;
    }

    file->filename = strdup(filename);
    file->full_path = strdup(full_path);
    file->callback = callback;
    file->user_data = user_data;

    if (!file->filename || !file->full_path) {
        if (file->filename) free(file->filename);
        if (file->full_path) free(file->full_path);
        free(file);
        return;
    }

    // Add to the files array
    dir_watch->files[dir_watch->file_count++] = file;
}

// Remove a monitored file from a directory watch
static void remove_monitored_file(directory_watch_t* dir_watch, const char* filename) {
    for (int i = 0; i < dir_watch->file_count; i++) {
        if (strcmp(dir_watch->files[i]->filename, filename) == 0) {
            // Free the file
            free(dir_watch->files[i]->filename);
            free(dir_watch->files[i]->full_path);
            free(dir_watch->files[i]);

            // Remove from the array by shifting
            for (int j = i; j < dir_watch->file_count - 1; j++) {
                dir_watch->files[j] = dir_watch->files[j + 1];
            }

            dir_watch->file_count--;
            return;
        }
    }
}

// Clean up a directory watch
static void cleanup_directory_watch(directory_watch_t* dir_watch) {
    // Remove the inotify watch
    inotify_rm_watch(monitor->inotify_fd, dir_watch->watch_descriptor);

    // Free all monitored files
    for (int i = 0; i < dir_watch->file_count; i++) {
        free(dir_watch->files[i]->filename);
        free(dir_watch->files[i]->full_path);
        free(dir_watch->files[i]);
    }

    // Free the directory watch
    free(dir_watch->files);
    free(dir_watch->dir_path);
    free(dir_watch);
}

// Public API: Add paths to monitor
int add_paths(const char** paths, int path_count, file_change_callback callback, void* user_data) {
    if (!paths || path_count <= 0 || !callback) {
        return -1;
    }

    // Initialize the file monitor if needed
    if (!monitor && init_file_monitor() != 0) {
        return -1;
    }

    pthread_mutex_lock(&monitor->lock);

    for (int i = 0; i < path_count; i++) {
        const char* path = paths[i];

        // Get the directory and filename
        char* path_copy = strdup(path);
        if (!path_copy) {
            pthread_mutex_unlock(&monitor->lock);
            return -1;
        }

        char* dir_path = dirname(strdup(path_copy));
        char* filename = basename(path_copy);

        // Find or create the directory watch
        directory_watch_t* dir_watch = find_directory_watch(dir_path);
        if (!dir_watch) {
            dir_watch = add_directory_watch(dir_path);
        }

        if (dir_watch) {
            // Add the file to the directory watch
            monitored_file_t* existing = find_monitored_file(dir_watch, filename);
            if (existing) {
                // Update the callback
                existing->callback = callback;
                existing->user_data = user_data;
            } else {
                add_monitored_file(dir_watch, filename, path, callback, user_data);
            }
        }

        free(dir_path);
        free(path_copy);
    }

    pthread_mutex_unlock(&monitor->lock);
    return 0;
}

// Public API: Remove paths from monitoring
int remove_paths(const char** paths, int path_count) {
    if (!paths || path_count <= 0 || !monitor) {
        return -1;
    }

    pthread_mutex_lock(&monitor->lock);

    for (int i = 0; i < path_count; i++) {
        const char* path = paths[i];

        // Get the directory and filename
        char* path_copy = strdup(path);
        if (!path_copy) {
            pthread_mutex_unlock(&monitor->lock);
            return -1;
        }

        char* dir_path = dirname(strdup(path_copy));
        char* filename = basename(path_copy);

        // Find the directory watch
        directory_watch_t* dir_watch = find_directory_watch(dir_path);
        if (dir_watch) {
            // Remove the file from the directory watch
            remove_monitored_file(dir_watch, filename);

            // If no more files in this directory, remove the directory watch
            if (dir_watch->file_count == 0) {
                // Find the index of this directory watch
                int dir_index = -1;
                for (int j = 0; j < monitor->dir_count; j++) {
                    if (monitor->directories[j] == dir_watch) {
                        dir_index = j;
                        break;
                    }
                }

                if (dir_index >= 0) {
                    // Clean up the directory watch
                    cleanup_directory_watch(dir_watch);

                    // Remove from the array by shifting
                    for (int j = dir_index; j < monitor->dir_count - 1; j++) {
                        monitor->directories[j] = monitor->directories[j + 1];
                    }

                    monitor->dir_count--;
                }
            }
        }

        free(dir_path);
        free(path_copy);
    }

    // If no more directories, clean up the file monitor
    if (monitor->dir_count == 0) {
        pthread_mutex_unlock(&monitor->lock);
        cleanup_file_monitor();
        return 0;
    }

    pthread_mutex_unlock(&monitor->lock);
    return 0;
}

// Example usage
/*
void file_changed(const char* path, int event_type, void* user_data) {
    printf("File changed: %s\n", path);
    if (event_type & IN_MODIFY) printf("  Modified\n");
    if (event_type & IN_CREATE) printf("  Created\n");
    if (event_type & IN_DELETE) printf("  Deleted\n");
    if (event_type & IN_MOVED_FROM) printf("  Moved from\n");
    if (event_type & IN_MOVED_TO) printf("  Moved to\n");
}

int main() {
    const char* paths[] = {
        "/tmp/test1.txt",
        "/tmp/test2.txt",
        "/home/user/test3.txt"
    };

    add_paths(paths, 3, file_changed, NULL);

    // Wait for events
    printf("Monitoring files. Press Enter to exit.\n");
    getchar();

    remove_paths(paths, 3);

    return 0;
}
*/
