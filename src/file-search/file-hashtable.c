#include "file-hashtable.h"
#include <stdio.h>
#include <string.h>

#define INITIAL_CAPACITY 65536
#define INITIAL_OFFSETS_CAPACITY 4096

static inline void spin_lock(atomic_flag* lock) {
    while (atomic_flag_test_and_set_explicit(lock, memory_order_acquire)) {
        __builtin_ia32_pause();
    }
}

static inline void spin_unlock(atomic_flag* lock) {
    atomic_flag_clear_explicit(lock, memory_order_release);
}

static uint32_t hash_folder(const char* path) {
    const char* last_slash = strrchr(path, '/');
    if (!last_slash || last_slash == path) {
        return g_str_hash("/");
    }

    size_t folder_len = last_slash - path;
    char folder[folder_len + 1];
    memcpy(folder, path, folder_len);
    folder[folder_len] = '\0';

    return g_str_hash(folder);
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

    ft->offsets = malloc(INITIAL_OFFSETS_CAPACITY * sizeof(size_t));
    if (!ft->offsets) {
        free(ft->data);
        free(ft);
        return NULL;
    }

    ft->capacity = INITIAL_CAPACITY;
    ft->used = 0;
    ft->count = 0;
    ft->offsets_capacity = INITIAL_OFFSETS_CAPACITY;

    return ft;
}

void ft_destroy(FileTable* ft) {
    if (!ft) return;
    free(ft->offsets);
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

    // Ensure data capacity
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

    // Ensure offsets capacity
    if (ft->count + 1 > ft->offsets_capacity) {
        size_t new_cap = ft->offsets_capacity * 2;
        size_t* new_offsets = realloc(ft->offsets, new_cap * sizeof(size_t));
        if (!new_offsets) {
            spin_unlock(&ft->lock);
            return false;
        }
        ft->offsets = new_offsets;
        ft->offsets_capacity = new_cap;
    }

    // ----------------------------------------------------------------------
    // Find insertion point
    // ----------------------------------------------------------------------
    size_t ins_offset = ft->used;
    size_t ins_index = 0;
    size_t offset = 0;

    char _previous_buf[sizeof(FileEntry) + 1] = {0};
    FileEntry* previous = (FileEntry*)_previous_buf;

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

        previous = entry;
        offset += entry->entry_size;
        ins_index++;
    }

    size_t bytes_to_move = ft->used - ins_offset;
    if (bytes_to_move > 0) {
        memmove(ft->data + ins_offset + entry_size,
                ft->data + ins_offset,
                bytes_to_move);
    }

    FileEntry* new_entry = (FileEntry*)(ft->data + ins_offset);
    new_entry->entry_size = (uint16_t)entry_size;
    new_entry->hash = g_str_hash(path);
    new_entry->folder_hash = hash_folder(path);

    strcpy(new_entry->str, path);

    const char* a = previous->str;
    const char* b = new_entry->str;
    uint16_t i = 0;
    while (a[i] && b[i] && a[i] == b[i]) i++;
    new_entry->common_chars = i;

    if (bytes_to_move > 0) {
        FileEntry* next = (FileEntry*)(ft->data + ins_offset + entry_size);
        const char* a = new_entry->str;
        const char* b = next->str;
        uint16_t i = 0;
        while (a[i] && b[i] && a[i] == b[i]) i++;
        next->common_chars = i;
    }

    // ----------------------------------------------------------------------
    // Update offsets array
    // ----------------------------------------------------------------------
    for (size_t j = ft->count; j > ins_index; j--) {
        ft->offsets[j] = ft->offsets[j - 1] + entry_size;
    }
    ft->offsets[ins_index] = ins_offset;

    // ----------------------------------------------------------------------
    // Update table accounting
    // ----------------------------------------------------------------------
    ft->used += entry_size;
    ft->count++;

    spin_unlock(&ft->lock);
    return true;
}

bool ft_remove(FileTable* ft, const char* path) {
    if (!ft || !path) return false;
    spin_lock(&ft->lock);

    size_t offset = 0;
    FileEntry* previous = NULL;
    size_t current_index = 0;

    while (offset < ft->used) {
        FileEntry* entry = (FileEntry*)(ft->data + offset);
        int cmp = strcmp(path, entry->str);

        if (cmp == 0) {
            size_t entry_size = entry->entry_size;
            size_t next_offset = offset + entry_size;
            size_t bytes_after = ft->used - next_offset;

            if (bytes_after > 0) {
                memmove(ft->data + offset,
                        ft->data + next_offset,
                        bytes_after);
            }

            ft->used -= entry_size;
            ft->count--;

            if (offset < ft->used) {  // means there IS a next entry
                FileEntry* next = (FileEntry*)(ft->data + offset);

                if (previous == NULL) {
                    // Next is now the first entry
                    next->common_chars = 0;
                } else {
                    // Recompute prefix(previous, next)
                    const char* a = previous->str;
                    const char* b = next->str;
                    uint16_t i = 0;
                    while (a[i] && b[i] && a[i] == b[i]) i++;
                    next->common_chars = i;
                }
            }

            // --------------------------------------------------------------
            // Update offsets array: shift left and subtract entry_size
            // --------------------------------------------------------------
            for (size_t j = current_index; j < ft->count; j++) {
                ft->offsets[j] = ft->offsets[j + 1] - entry_size;
            }

            spin_unlock(&ft->lock);
            return true;
        }

        if (cmp < 0) {
            // Already passed the point where the entry would be
            spin_unlock(&ft->lock);
            return false;
        }

        previous = entry;
        offset += entry->entry_size;
        current_index++;
    }

    spin_unlock(&ft->lock);
    return false;
}

const char* ft_lookup_by_index(FileTable* ft, uint16_t index) {
    if (!ft || index >= ft->count) return NULL;
    spin_lock(&ft->lock);

    FileEntry* entry = (FileEntry*)(ft->data + ft->offsets[index]);
    char* dup = strdup(entry->str);

    spin_unlock(&ft->lock);
    return dup;
}
