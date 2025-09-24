#ifndef WAYLAND_PROTOCOL_CHECK_H
#define WAYLAND_PROTOCOL_CHECK_H

#include <stdbool.h>

/**
 * Check if a Wayland protocol/interface is supported by the compositor
 * @param protocol_name The name of the protocol to check (e.g., "zwlr_data_control_manager_v1")
 * @return true if the protocol is supported, false otherwise
 */
bool wayland_has_protocol(const char *protocol_name);

#endif /* WAYLAND_PROTOCOL_CHECK_H */
