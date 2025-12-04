#include "file-hashtable.h"
#include <stdio.h>
#include <string.h>

#define INITIAL_CAPACITY 65536

static inline void spin_lock(atomic_flag* lock) {
    while (atomic_flag_test_and_set_explicit(lock, memory_order_acquire)) {
        __builtin_ia32_pause();
    }
}

static inline void spin_unlock(atomic_flag* lock) {
    atomic_flag_clear_explicit(lock, memory_order_release);
}

FileTable* ft_create() {
    FileTable* ft = calloc(1, sizeof(FileTable));
    if (!ft) return NULL;

    ft->data = malloc(INITIAL_CAPACITY);
    atomic_flag_clear(&ft->lock);
    if (!ft->data) {
        free(ft);
        return NULL;
    }

    ft->capacity = INITIAL_CAPACITY;
    ft->used = 0;
    ft->count = 0;

    return ft;
}

void ft_destroy(FileTable* ft) {
    if (!ft) return;
    free(ft->data);
    free(ft);
}

bool ft_insert(FileTable* ft, const char* path) {
    if (!ft || !path) return false;
    spin_lock(&ft->lock);

    if (ft->count >= UINT16_MAX) {
        spin_unlock(&ft->lock);
        return false;
    }

    size_t len = strlen(path);
    size_t entry_size = (sizeof(FileEntry) + len + 1 + 1) & ~(size_t)1;

    // 1. Ensure capacity - grow if needed
    while (ft->used + entry_size > ft->capacity) {
        size_t new_cap = ft->capacity * 2;
        char* new_data = realloc(ft->data, new_cap);
        if (!new_data) {
            spin_unlock(&ft->lock);
            return false;
        }
        ft->data = new_data;
        ft->capacity = new_cap;
    }

    // 2. Find insertion point (first entry where path < entry->str)
    size_t ins_offset = ft->used;  // default: append at end
    size_t offset = 0;

    while (offset < ft->used) {
        FileEntry* entry = (FileEntry*)(ft->data + offset);
        int cmp = strcmp(path, entry->str);

        if (cmp < 0) {
            ins_offset = offset;
            break;
        } else if (cmp == 0) {
            spin_unlock(&ft->lock);
            return true;
        }

        offset += entry->entry_size;
    }

    // 3. Shift data after insertion point
    size_t bytes_to_move = ft->used - ins_offset;
    if (bytes_to_move > 0) {
        memmove(ft->data + ins_offset + entry_size,
                ft->data + ins_offset,
                bytes_to_move);
    }

    // 4. Write new entry
    FileEntry* new_entry = (FileEntry*)(ft->data + ins_offset);
    new_entry->entry_size = (uint16_t)entry_size;
    new_entry->hash = g_str_hash(path);
    strcpy(new_entry->str, path);

    ft->used += entry_size;
    ft->count++;

    spin_unlock(&ft->lock);
    return true;
}

bool ft_remove(FileTable* ft, const char* path) {
    if (!ft || !path) return false;
    spin_lock(&ft->lock);

    size_t offset = 0;
    while (offset < ft->used) {
        FileEntry* entry = (FileEntry*)(ft->data + offset);
        int cmp = strcmp(path, entry->str);

        if (cmp == 0) {
            // Found it - shift everything after it back
            size_t entry_size = entry->entry_size;
            size_t bytes_after = ft->used - offset - entry_size;

            if (bytes_after > 0) {
                memmove(ft->data + offset,
                        ft->data + offset + entry_size,
                        bytes_after);
            }

            ft->used -= entry_size;
            ft->count--;
            spin_unlock(&ft->lock);
            return true;
        }

        if (cmp < 0) {
            // Past where it would be - not found
            spin_unlock(&ft->lock);
            return false;
        }

        offset += entry->entry_size;
    }

    spin_unlock(&ft->lock);
    return false;
}

const char* ft_lookup_by_index(FileTable* ft, uint16_t index) {
    if (!ft || index >= ft->count) return NULL;
    spin_lock(&ft->lock);

    size_t offset = 0;
    uint16_t i = 0;

    while (offset < ft->used) {
        FileEntry* entry = (FileEntry*)(ft->data + offset);
        if (i == index) {
            char* dup = strdup(entry->str);
            spin_unlock(&ft->lock);
            return dup;
        }
        offset += entry->entry_size;
        i++;
    }

    spin_unlock(&ft->lock);
    return NULL;
}

void ft_iterate(FileTable* ft, ft_iterator callback, void* user_data) {
    if (!ft || !callback) return;
    spin_lock(&ft->lock);

    size_t offset = 0;
    uint16_t i = 0;

    while (offset < ft->used) {
        FileEntry* entry = (FileEntry*)(ft->data + offset);
        callback(i++, entry->str, entry->hash, user_data);
        offset += entry->entry_size;
    }
    spin_unlock(&ft->lock);
}
