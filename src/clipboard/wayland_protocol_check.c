#include "wayland_protocol_check.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

struct registry_data {
    bool has_protocol;
    const char *protocol_name;
};

static void registry_handler(void *data, struct wl_registry *registry,
                           uint32_t id, const char *interface, uint32_t version)
{
    struct registry_data *rd = (struct registry_data *)data;

    if (strcmp(interface, rd->protocol_name) == 0) {
        rd->has_protocol = true;
    }
}

static void registry_remover(void *data, struct wl_registry *registry, uint32_t id)
{
    // Not needed for our purposes
}

static const struct wl_registry_listener registry_listener = {
    registry_handler,
    registry_remover
};

bool wayland_has_protocol(const char *protocol_name)
{
    struct wl_display *display = NULL;
    struct wl_registry *registry = NULL;
    struct registry_data data = {
        .has_protocol = false,
        .protocol_name = protocol_name
    };

    // Connect to the Wayland display
    display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "Failed to connect to Wayland display\n");
        return false;
    }

    // Get the registry
    registry = wl_display_get_registry(display);
    if (!registry) {
        fprintf(stderr, "Failed to get Wayland registry\n");
        wl_display_disconnect(display);
        return false;
    }

    // Add listener to check for protocols
    wl_registry_add_listener(registry, &registry_listener, &data);

    // Roundtrip to ensure all globals are received
    wl_display_roundtrip(display);

    // Cleanup
    wl_registry_destroy(registry);
    wl_display_disconnect(display);

    return data.has_protocol;
}
