#include "wayland-clipboard.h"
#include "wlr-data-control.h"

#include <wayland-client.h>
#include <glib.h>
#include <stdio.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <immintrin.h>
#include <pthread.h>
#include <stdatomic.h>

// Private data structures
struct clipboard_manager_t {
    // Wayland objects
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_seat *seat;
    struct zwlr_data_control_manager_v1 *manager;
    struct zwlr_data_control_device_v1 *device;

    // Thread management
    atomic_int running;
    pthread_t thread_id;
    pthread_mutex_t mutex;

    // State tracking
    uint32_t last_hash;
    bool prevent_infinite_loop;

    // User callback
    clipboard_changed_callback on_clipboard_changed;
};

// Struct to use as user_data for wl_data_offer
typedef struct {
    struct zwlr_data_control_offer_v1 *offer;
    clipboard_manager *manager;
    GPtrArray *mime_types; // Use GPtrArray instead of custom array
} offer_data;

// Struct to use as user_data for wl_data_source
typedef struct {
    struct zwlr_data_control_source_v1 *source;
    clipboard_manager *manager;
    GHashTable *content;
} source_data;

// Forward declarations of private functions
static void* event_loop_thread(void *data);
static void registry_handle_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version);
static void registry_handle_global_remove(void *data, struct wl_registry *registry, uint32_t name);
static void device_handle_data_offer(void *data, struct zwlr_data_control_device_v1 *device, struct zwlr_data_control_offer_v1 *offer);
static void device_handle_selection(void *data, struct zwlr_data_control_device_v1 *device, struct zwlr_data_control_offer_v1 *id);
static void device_handle_finished(void *data, struct zwlr_data_control_device_v1 *device);
static void device_handle_primary_selection(void *data, struct zwlr_data_control_device_v1 *device, struct zwlr_data_control_offer_v1 *id);
static void offer_handle_offer(void *data, struct zwlr_data_control_offer_v1 *offer, const char *mime_type);
static void source_send_handler(void *data, struct zwlr_data_control_source_v1 *source, const char *mime_type, int32_t fd);
static void source_cancelled_handler(void *data, struct zwlr_data_control_source_v1 *source);
static void process_offer(clipboard_manager *manager, struct zwlr_data_control_offer_v1 *offer_obj);
static GBytes* read_offer_data(struct zwlr_data_control_offer_v1 *offer, const char *mime_type);

// Wayland listeners
static const struct wl_registry_listener registry_listener = {
    .global = registry_handle_global,
    .global_remove = registry_handle_global_remove
};

static const struct zwlr_data_control_device_v1_listener device_listener = {
    .data_offer = device_handle_data_offer,
    .selection = device_handle_selection,
    .finished = device_handle_finished,
    .primary_selection = device_handle_primary_selection
};

static const struct zwlr_data_control_offer_v1_listener offer_listener = {
    .offer = offer_handle_offer
};

static const struct zwlr_data_control_source_v1_listener source_listener = {
    .send = source_send_handler,
    .cancelled = source_cancelled_handler
};

// Implementation of public functions

clipboard_manager* clipboard_manager_new(clipboard_changed_callback callback) {
    clipboard_manager *manager = calloc(1, sizeof(clipboard_manager));
    if (!manager) {
        fprintf(stderr, "Failed to allocate clipboard manager\n");
        return NULL;
    }

    // Initialize atomic flag for thread management
    atomic_init(&manager->running, 0);

    // Initialize mutex
    if (pthread_mutex_init(&manager->mutex, NULL) != 0) {
        fprintf(stderr, "Failed to initialize mutex\n");
        free(manager);
        return NULL;
    }

    // Store callback
    manager->on_clipboard_changed = callback;

    // Connect to Wayland display
    manager->display = wl_display_connect(NULL);
    if (!manager->display) {
        fprintf(stderr, "Failed to connect to Wayland display\n");
        pthread_mutex_destroy(&manager->mutex);
        free(manager);
        return NULL;
    }

    // Get registry
    manager->registry = wl_display_get_registry(manager->display);
    if (!manager->registry) {
        fprintf(stderr, "Failed to get Wayland registry\n");
        wl_display_disconnect(manager->display);
        pthread_mutex_destroy(&manager->mutex);
        free(manager);
        return NULL;
    }

    // Set up registry listener
    wl_registry_add_listener(manager->registry, &registry_listener, manager);

    // Roundtrip to process registry events
    wl_display_roundtrip(manager->display);

    // Check if we got all the required objects
    if (!manager->manager || !manager->seat) {
        fprintf(stderr, "Failed to find required Wayland globals\n");
        if (manager->manager) {
            zwlr_data_control_manager_v1_destroy(manager->manager);
        }
        wl_registry_destroy(manager->registry);
        wl_display_disconnect(manager->display);
        pthread_mutex_destroy(&manager->mutex);
        free(manager);
        return NULL;
    }

    // Get data device
    manager->device = zwlr_data_control_manager_v1_get_data_device(manager->manager, manager->seat);
    if (!manager->device) {
        fprintf(stderr, "Failed to get data device\n");
        zwlr_data_control_manager_v1_destroy(manager->manager);
        wl_registry_destroy(manager->registry);
        wl_display_disconnect(manager->display);
        pthread_mutex_destroy(&manager->mutex);
        free(manager);
        return NULL;
    }

    // Add device listener
    zwlr_data_control_device_v1_add_listener(manager->device, &device_listener, manager);

    // Roundtrip to ensure device is set up
    wl_display_roundtrip(manager->display);

    return manager;
}

void clipboard_manager_destroy(clipboard_manager *manager) {
    if (!manager) {
        return;
    }
    atomic_store(&manager->running, 0);
    wl_display_roundtrip(manager->display);

    while (atomic_load(&manager->running) != 2) {
        _mm_pause();
    }
    pthread_join(manager->thread_id, NULL);

    if (manager->device) {
        zwlr_data_control_device_v1_destroy(manager->device);
    }

    if (manager->manager) {
        zwlr_data_control_manager_v1_destroy(manager->manager);
    }

    if (manager->registry) {
        wl_registry_destroy(manager->registry);
    }

    if (manager->display) {
        wl_display_disconnect(manager->display);
    }

    // Clean up mutex
    pthread_mutex_destroy(&manager->mutex);

    // Free the manager
    free(manager);
    manager = NULL;
}

void clipboard_manager_listen(clipboard_manager *manager) {
    if (!manager || atomic_load(&manager->running)) {
        return;
    }

    // Start the event loop thread
    atomic_store(&manager->running, 1);
    if (pthread_create(&manager->thread_id, NULL, event_loop_thread, manager) != 0) {
        fprintf(stderr, "Failed to create event loop thread\n");
        atomic_store(&manager->running, 0);
    }
}

void clipboard_manager_set_clipboard(clipboard_manager *manager, GHashTable *content) {
    if (!manager || !content) {
        return;
    }

    pthread_mutex_lock(&manager->mutex);

    // Create data source
    struct zwlr_data_control_source_v1 *source =
        zwlr_data_control_manager_v1_create_data_source(manager->manager);
    if (!source) {
        fprintf(stderr, "Failed to create data source\n");
        pthread_mutex_unlock(&manager->mutex);
        return;
    }

    // Create source_data to track this source
    source_data *data = calloc(1, sizeof(source_data));
    if (!data) {
        zwlr_data_control_source_v1_destroy(source);
        pthread_mutex_unlock(&manager->mutex);
        return;
    }

    data->source = source;
    data->manager = manager;

    // Create a copy of the content hashtable
    data->content = g_hash_table_new_full(
        (GHashFunc)g_bytes_hash,
        (GEqualFunc)g_bytes_equal,
        (GDestroyNotify)g_bytes_unref,
        (GDestroyNotify)g_ptr_array_unref
    );

    // Copy content to our hashtable and offer mime types
    GHashTableIter iter;
    gpointer key, value;
    g_hash_table_iter_init(&iter, content);
    while (g_hash_table_iter_next(&iter, &key, &value)) {
        GBytes *bytes = key;
        GPtrArray *mime_types = value;

        // Add a ref to the bytes and insert into our table
        g_hash_table_insert(data->content, g_bytes_ref(bytes), g_ptr_array_ref(mime_types));

        // Offer each mime type
        for (int i = 0; i < mime_types->len; i++) {
            const char *mime_type = g_ptr_array_index(mime_types, i);
            zwlr_data_control_source_v1_offer(source, mime_type);
        }
    }

    // Add listener
    zwlr_data_control_source_v1_add_listener(source, &source_listener, data);

    // Set flag to avoid processing our own selection
    manager->prevent_infinite_loop = true;

    // Set selection
    zwlr_data_control_device_v1_set_selection(manager->device, source);

    // Flush to ensure selection is set
    wl_display_flush(manager->display);

    pthread_mutex_unlock(&manager->mutex);
}

// Private function implementations

static void* event_loop_thread(void *data) {
    clipboard_manager *manager = data;

    while (atomic_load(&manager->running) && wl_display_dispatch(manager->display) != -1) { }

    atomic_store(&manager->running, 2);

    return NULL;
}

static void registry_handle_global(void *data, struct wl_registry *registry,
                                 uint32_t name, const char *interface, uint32_t version) {
    clipboard_manager *manager = data;

    if (strcmp(interface, "zwlr_data_control_manager_v1") == 0 && !manager->manager) {
        manager->manager = wl_registry_bind(
            registry, name, &zwlr_data_control_manager_v1_interface,
            version < 2 ? version : 2);
    } else if (strcmp(interface, "wl_seat") == 0 && !manager->seat) {
        manager->seat = wl_registry_bind(
            registry, name, &wl_seat_interface,
            version < 7 ? version : 7);
    }
}

static void registry_handle_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    // Nothing to do here
}

static void device_handle_data_offer(void *data, struct zwlr_data_control_device_v1 *device,
                                   struct zwlr_data_control_offer_v1 *offer) {
    clipboard_manager *manager = data;

    if (!manager || !offer) {
        fprintf(stderr, "Invalid manager or offer\n");
        return;
    }

    // Create offer_data structure
    offer_data *myoffer = calloc(1, sizeof(offer_data));
    if (!myoffer) {
        fprintf(stderr, "Failed to allocate offer myoffer\n");
        return;
    }

    myoffer->offer = offer;
    myoffer->manager = manager;

    myoffer->mime_types = g_ptr_array_new_with_free_func(g_free);

    wl_proxy_set_user_data((struct wl_proxy *)offer, myoffer);

    // Add listener
    zwlr_data_control_offer_v1_add_listener(offer, &offer_listener, myoffer);
}

static void device_handle_selection(void *data, struct zwlr_data_control_device_v1 *device,
                                  struct zwlr_data_control_offer_v1 *id) {
    clipboard_manager *manager = data;

    // If we're in infinite loop prevention mode, ignore this selection
    if (manager->prevent_infinite_loop) {
        manager->prevent_infinite_loop = false;
        return;
    }

    if (id) {
        // Process the offer
        process_offer(manager, id);
    }
}

static void device_handle_finished(void *data, struct zwlr_data_control_device_v1 *device) {
    // Device is being destroyed, nothing to do
}

static void device_handle_primary_selection(void *data, struct zwlr_data_control_device_v1 *device,
                                         struct zwlr_data_control_offer_v1 *id) {
    // Not interested in primary selection
    if (id) {
        zwlr_data_control_offer_v1_destroy(id);
    }
}

static void offer_handle_offer(void *data, struct zwlr_data_control_offer_v1 *offer, const char *mime_type) {
    offer_data *offer_data = data;

    if (!offer_data || !mime_type || !offer_data->mime_types) {
        // fprintf(stderr, || !offer_data->mime_types) {
        return;
    }

    // Skip SAVE_TARGETS
    if (strcmp(mime_type, "SAVE_TARGETS") == 0) {
        return;
    }

    g_ptr_array_add(offer_data->mime_types, g_strdup(mime_type));
}

static void source_send_handler(void *data, struct zwlr_data_control_source_v1 *source,
                              const char *mime_type, int32_t fd) {
    source_data *source_data = data;

    if (!source_data || !source_data->content) {
        close(fd);
        return;
    }

    // Find content for the requested mime type
    GHashTableIter iter;
    gpointer key, value;
    g_hash_table_iter_init(&iter, source_data->content);

    while (g_hash_table_iter_next(&iter, &key, &value)) {
        GBytes *bytes = key;
        GPtrArray *mime_types = value;

        // Check if this content has the requested mime type
        for (int i = 0; i < mime_types->len; i++) {
            const char *current_mime = g_ptr_array_index(mime_types, i);
            if (strcmp(current_mime, mime_type) == 0) {
                // Write content to fd
                gsize size;
                const void *data = g_bytes_get_data(bytes, &size);
                write(fd, data, size);
                break;
            }
        }
    }

    // Always close the fd
    close(fd);
}

static void source_cancelled_handler(void *data, struct zwlr_data_control_source_v1 *source) {
    source_data *source_data = data;

    if (!source_data) {
        return;
    }

    // Clean up - source is automatically destroyed by compositor
    if (source_data->content) {
        g_hash_table_destroy(source_data->content);
    }

    free(source_data);
}

static void process_offer(clipboard_manager *manager, struct zwlr_data_control_offer_v1 *offer_obj) {
    offer_data *data = wl_proxy_get_user_data((struct wl_proxy*)offer_obj);
    if (!data || !data->mime_types || data->mime_types->len == 0) {
        if (offer_obj) {
            zwlr_data_control_offer_v1_destroy(offer_obj);
        }
        return;
    }

    // Create content map
    GHashTable *content_map = g_hash_table_new_full(
        (GHashFunc)g_bytes_hash,
        (GEqualFunc)g_bytes_equal,
        (GDestroyNotify)g_bytes_unref,
        (GDestroyNotify)g_ptr_array_unref
    );

    bool has_new_content = false;
    uint32_t combined_hash = 17;

    // Process all mime types
    for (int i = 0; i < data->mime_types->len; i++) {
        const char *mime_type = g_ptr_array_index(data->mime_types, i);
        GBytes *content = read_offer_data(offer_obj, mime_type);

        if (content && g_bytes_get_size(content) > 0) {
            // Get or create mime types array for this content
            GPtrArray *mime_types = g_hash_table_lookup(content_map, content);
            if (!mime_types) {
                mime_types = g_ptr_array_new_with_free_func(g_free);
                g_hash_table_insert(content_map, g_bytes_ref(content), mime_types);
            }

            // Add mime type
            g_ptr_array_add(mime_types, g_strdup(mime_type));

            // Update hash
            combined_hash = 31 * combined_hash + g_bytes_hash(content);
            combined_hash = 31 * combined_hash + g_str_hash(mime_type);

            has_new_content = true;

            // Free our reference
            g_bytes_unref(content);
        }
    }

    // If we have new content and it's different from the last one
    if (has_new_content && combined_hash != manager->last_hash) {
        manager->last_hash = combined_hash;

        // Call callback if set
        pthread_mutex_lock(&manager->mutex);
        clipboard_changed_callback callback = manager->on_clipboard_changed;
        pthread_mutex_unlock(&manager->mutex);

        if (callback) {
            callback(content_map, combined_hash);
        } else {
            g_hash_table_destroy(content_map);
        }
    } else {
        // No new content or same as before
        g_hash_table_destroy(content_map);
    }

    // Clean up offer data
    if (data->mime_types) {
        g_ptr_array_unref(data->mime_types);
    }
    free(data);

    // Destroy the offer
    zwlr_data_control_offer_v1_destroy(offer_obj);
}

static GBytes* read_offer_data(struct zwlr_data_control_offer_v1 *offer, const char *mime_type) {
    int pipe_fd[2];
    if (pipe(pipe_fd) != 0) {
        perror("Failed to create pipe");
        return NULL;
    }

    // Check if this is a text mime type
    bool is_text = strncmp(mime_type, "text/", 5) == 0;

    // Request content
    zwlr_data_control_offer_v1_receive(offer, mime_type, pipe_fd[1]);

    // Make sure the request reaches the compositor
    wl_display_flush(((offer_data*)wl_proxy_get_user_data((struct wl_proxy*)offer))->manager->display);

    // Close write end
    close(pipe_fd[1]);

    // Set read end to non-blocking
    fcntl(pipe_fd[0], F_SETFL, O_NONBLOCK);

    // Read data
    GByteArray *byte_array = g_byte_array_new();
    uint8_t buffer[4096];
    bool end_of_stream = false;

    while (!end_of_stream) {
        ssize_t bytes_read = read(pipe_fd[0], buffer, sizeof(buffer));

        if (bytes_read > 0) {
            g_byte_array_append(byte_array, buffer, bytes_read);
        } else if (bytes_read == 0) {
            // EOF
            end_of_stream = true;
        } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
            // Would block, try again after a small delay to prevent CPU spin
            usleep(1000); // 1ms delay
        } else {
            // Error
            perror("Error reading from pipe");
            end_of_stream = true;
        }
    }

    // For text types, add a null terminator
    if (is_text) {
        uint8_t null_byte = 0;
        g_byte_array_append(byte_array, &null_byte, 1);
    }

    // Close read end
    close(pipe_fd[0]);

    // Convert to GBytes and clean up
    GBytes *result = g_byte_array_free_to_bytes(byte_array);
    return result;
}
