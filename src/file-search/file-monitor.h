#ifndef FILE_MONITOR_H
#define FILE_MONITOR_H

#ifdef __cplusplus
extern "C" {
#endif

// Callback function type definition
typedef void (*file_change_callback)(const char* path, int event_type, void* user_data);

/**
 * Add paths to the file monitor
 *
 * @param paths Array of file paths to monitor
 * @param path_count Number of paths in the array
 * @param callback Function to call when a file changes
 * @param user_data User data to pass to the callback
 * @return 0 on success, -1 on failure
 */
int add_paths(const char** paths, int path_count, file_change_callback callback, void* user_data);

/**
 * Remove paths from the file monitor
 *
 * @param paths Array of file paths to stop monitoring
 * @param path_count Number of paths in the array
 * @return 0 on success, -1 on failure
 */
int remove_paths(const char** paths, int path_count);

#ifdef __cplusplus
}
#endif

#endif // FILE_MONITOR_H
