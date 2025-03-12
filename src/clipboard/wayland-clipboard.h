// clipboard-manager.h
#ifndef CLIPBOARD_MANAGER_H
#define CLIPBOARD_MANAGER_H

#include <glib.h>
#include <stdint.h>
#include <stdatomic.h>
#include <pthread.h>

typedef void (*clipboard_changed_callback)(GHashTable *content, uint32_t hash);

typedef struct clipboard_manager_t clipboard_manager;

// Public API
clipboard_manager* clipboard_manager_new(clipboard_changed_callback callback);
void clipboard_manager_destroy(clipboard_manager *manager);
void clipboard_manager_listen(clipboard_manager *manager);
void clipboard_manager_set_clipboard(clipboard_manager *manager, GHashTable *content);

#endif /* CLIPBOARD_MANAGER_H */
