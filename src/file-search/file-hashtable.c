#include "file-hashtable.h"

static size_t next_power_of_2(size_t x) {
    x--;
    x |= x >> 1;
    x |= x >> 2;
    x |= x >> 4;
    x |= x >> 8;
    x |= x >> 16;
    x |= x >> 32;
    x++;
    return x;
}

static size_t find_slot(uint32_t* hash_to_idx, size_t capacity, uint32_t hash, const char* path, FileEntry* array) {
    size_t mask = capacity - 1;
    size_t slot = hash & mask;

    while (hash_to_idx[slot] != 0) {
        size_t idx = hash_to_idx[slot] - 1;
        if (array[idx].hash == hash && strcmp(array[idx].path, path) == 0) {
            return slot;
        }
        slot = (slot + 1) & mask;
    }
    return slot;
}

static void maybe_grow_array(FileTable* ft) {
    if (ft->size >= ft->array_capacity) {
        size_t new_capacity = ft->array_capacity * 2;
        FileEntry* new_array = realloc(ft->array, new_capacity * sizeof(FileEntry));
        size_t* new_idx_to_hash_slot = realloc(ft->idx_to_hash_slot, new_capacity * sizeof(size_t));

        if (new_array && new_idx_to_hash_slot) {
            ft->array = new_array;
            ft->idx_to_hash_slot = new_idx_to_hash_slot;
            ft->array_capacity = new_capacity;
        }
    }
}

static void resize_hash(FileTable* ft) {
    size_t new_capacity = ft->capacity * 2;
    uint32_t* new_hash_to_idx = calloc(new_capacity, sizeof(uint32_t));

    if (new_hash_to_idx) {
        for (size_t i = 0; i < ft->size; i++) {
            uint32_t hash = ft->array[i].hash;
            const char* path = ft->array[i].path;
            size_t new_slot = find_slot(new_hash_to_idx, new_capacity, hash, path, ft->array);
            new_hash_to_idx[new_slot] = i + 1;
            ft->idx_to_hash_slot[i] = new_slot;
        }

        free(ft->hash_to_idx);
        ft->hash_to_idx = new_hash_to_idx;
        ft->capacity = new_capacity;
    }
}

FileTable* ft_create(size_t initial_capacity) {
    initial_capacity = next_power_of_2(initial_capacity);
    FileTable* ft = malloc(sizeof(FileTable));
    if (!ft) return NULL;

    ft->array = malloc(initial_capacity * sizeof(FileEntry));
    ft->hash_to_idx = calloc(initial_capacity, sizeof(uint32_t));
    ft->idx_to_hash_slot = malloc(initial_capacity * sizeof(size_t));

    if (!ft->array || !ft->hash_to_idx || !ft->idx_to_hash_slot) {
        free(ft->array);
        free(ft->hash_to_idx);
        free(ft->idx_to_hash_slot);
        free(ft);
        return NULL;
    }

    ft->capacity = initial_capacity;
    ft->array_capacity = initial_capacity;
    ft->size = 0;

    return ft;
}

void ft_destroy(FileTable* ft) {
    if (!ft) return;

    for (size_t i = 0; i < ft->size; i++) {
        free(ft->array[i].path);
    }

    free(ft->array);
    free(ft->hash_to_idx);
    free(ft->idx_to_hash_slot);
    free(ft);
}

bool ft_insert(FileTable* ft, const char* path, uint32_t hash) {
    if (!ft || !path || hash == 0) return false;

    if (ft->size >= ft->capacity * 0.75) {
        resize_hash(ft);
    }

    size_t slot = find_slot(ft->hash_to_idx, ft->capacity, hash, path, ft->array);

    if (ft->hash_to_idx[slot] != 0) {
        // Entry already exists, nothing to do
        return true;
    }

    maybe_grow_array(ft);

    ft->array[ft->size].hash = hash;

    // Instead of strdup, manually allocate with an extra safety byte
    size_t path_len = strlen(path);
    ft->array[ft->size].path = malloc(path_len + 2);  // +1 for null, +1 for safety

    if (!ft->array[ft->size].path) {
        return false;
    }

    memcpy(ft->array[ft->size].path, path, path_len);
    ft->array[ft->size].path[path_len] = '\0';       // Ensure null termination
    ft->array[ft->size].path[path_len + 1] = '\0';   // Extra safety byte

    ft->hash_to_idx[slot] = ft->size + 1;
    ft->idx_to_hash_slot[ft->size] = slot;
    ft->size++;

    return true;
}

bool ft_remove(FileTable* ft, const char* path, uint32_t hash) {
    if (!ft || !path || hash == 0) return false;

    size_t slot = find_slot(ft->hash_to_idx, ft->capacity, hash, path, ft->array);
    if (ft->hash_to_idx[slot] == 0) {
        return false;
    }

    size_t idx = ft->hash_to_idx[slot] - 1;

    free(ft->array[idx].path);

    if (idx < ft->size - 1) {
        // Move the last element to the removed position
        ft->array[idx] = ft->array[ft->size - 1];
        size_t moved_slot = ft->idx_to_hash_slot[ft->size - 1];
        ft->hash_to_idx[moved_slot] = idx + 1;
        ft->idx_to_hash_slot[idx] = moved_slot;
    }

    ft->hash_to_idx[slot] = 0;
    ft->size--;

    return true;
}

const FileEntry* ft_lookup(FileTable* ft, uint32_t hash) {
    if (!ft || hash == 0) return NULL;

    // This is a simplified lookup by hash only
    // For exact matching, the caller should verify the path
    size_t mask = ft->capacity - 1;
    size_t slot = hash & mask;

    while (ft->hash_to_idx[slot] != 0) {
        size_t idx = ft->hash_to_idx[slot] - 1;
        if (ft->array[idx].hash == hash) {
            return &ft->array[idx];
        }
        slot = (slot + 1) & mask;
    }

    return NULL;
}

const FileEntry* ft_entries(FileTable* ft, size_t* length) {
    if (!ft) return NULL;
    if (length) *length = ft->size;
    return ft->array;
}
