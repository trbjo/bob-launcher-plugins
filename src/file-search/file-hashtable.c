#include "file-hashtable.h"
#include <stdio.h>
#include <string.h>

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

static size_t find_slot(FileTable* ft, uint32_t hash) {
    size_t mask = ft->hash_capacity - 1;
    size_t slot = hash & mask;

    while (ft->hash_table[slot] != 0) {
        uint32_t idx = ft->hash_table[slot] - 1;
        BlobLocation* loc = &ft->locations[idx];
        FileEntry* entry = (FileEntry*)(ft->blobs[loc->blob_idx] + loc->offset);

        if (entry->hash == hash) {
            return slot;
        }
        slot = (slot + 1) & mask;
    }
    return slot;
}

static void resize_hash(FileTable* ft) {
    size_t new_capacity = ft->hash_capacity * 2;
    uint32_t* new_table = calloc(new_capacity, sizeof(uint32_t));
    BlobLocation* new_locations = realloc(ft->locations, new_capacity * sizeof(BlobLocation));

    if (!new_table || !new_locations) return;

    uint32_t* old_table = ft->hash_table;
    size_t old_capacity = ft->hash_capacity;

    ft->hash_table = new_table;
    ft->locations = new_locations;
    ft->hash_capacity = new_capacity;

    // Rehash all entries
    for (size_t i = 0; i < old_capacity; i++) {
        if (old_table[i] != 0) {
            BlobLocation* loc = &ft->locations[old_table[i] - 1];
            FileEntry* entry = (FileEntry*)(ft->blobs[loc->blob_idx] + loc->offset);

            size_t slot = find_slot(ft, entry->hash);
            ft->hash_table[slot] = old_table[i];
        }
    }

    free(old_table);
}

FileTable* ft_create(size_t initial_capacity) {
    initial_capacity = next_power_of_2(initial_capacity);

    FileTable* ft = calloc(1, sizeof(FileTable));
    if (!ft) return NULL;

    ft->blob_capacity = 1;
    ft->blobs = malloc(ft->blob_capacity * sizeof(char*));
    ft->blob_entry_counts = malloc(ft->blob_capacity * sizeof(uint16_t));
    ft->hash_table = calloc(initial_capacity, sizeof(uint32_t));
    ft->locations = malloc(initial_capacity * sizeof(BlobLocation));

    if (!ft->blobs || !ft->blob_entry_counts || !ft->hash_table || !ft->locations) {
        free(ft->blobs);
        free(ft->blob_entry_counts);
        free(ft->hash_table);
        free(ft->locations);
        free(ft);
        return NULL;
    }

    ft->blobs[0] = aligned_alloc(64, BLOB_SIZE);
    if (!ft->blobs[0]) {
        free(ft->blobs);
        free(ft->blob_entry_counts);
        free(ft->hash_table);
        free(ft->locations);
        free(ft);
        return NULL;
    }
    memset(ft->blobs[0], 0, BLOB_SIZE);
    ft->blob_entry_counts[0] = 0;

    ft->blob_count = 1;
    ft->current_blob = 0;
    ft->current_offset = 0;
    ft->hash_capacity = initial_capacity;
    ft->hash_count = 0;
    ft->total_count = 0;

    return ft;
}

void ft_destroy(FileTable* ft) {
    if (!ft) return;

    for (size_t i = 0; i < ft->blob_count; i++) {
        free(ft->blobs[i]);
    }

    free(ft->blobs);
    free(ft->blob_entry_counts);
    free(ft->hash_table);
    free(ft->locations);
    free(ft);
}

bool ft_insert(FileTable* ft, const char* path, uint32_t hash) {
    if (!ft || !path || hash == 0) return false;

    size_t slot = find_slot(ft, hash);
    if (ft->hash_table[slot] != 0) {
        return true; // Already exists
    }

    if (ft->hash_count >= ft->hash_capacity * 0.75) {
        resize_hash(ft);
        slot = find_slot(ft, hash);
    }

    size_t len = strlen(path);
    size_t entry_size = sizeof(FileEntry) + len + 1;

    // Round up to next 4-byte boundary for alignment
    entry_size = (entry_size + 3) & ~3;

    if (ft->current_offset + entry_size > BLOB_SIZE) {
        ft->current_blob++;
        ft->current_offset = 0;

        if (ft->current_blob >= ft->blob_capacity) {
            ft->blob_capacity++;
            char** new_blobs = realloc(ft->blobs, ft->blob_capacity * sizeof(char*));
            if (!new_blobs) return false;
            ft->blobs = new_blobs;
        }

        if (ft->current_blob >= ft->blob_count) {
            ft->blobs[ft->current_blob] = aligned_alloc(64, BLOB_SIZE);
            ft->blob_entry_counts = realloc(ft->blob_entry_counts, ft->blob_capacity * sizeof(uint16_t));
            ft->blob_entry_counts[ft->current_blob] = 0;

            if (!ft->blobs[ft->current_blob]) return false;
            memset(ft->blobs[ft->current_blob], 0, BLOB_SIZE);
            ft->blob_count++;
        }
    }

    FileEntry* entry = (FileEntry*)(ft->blobs[ft->current_blob] + ft->current_offset);
    entry->hash = hash;
    entry->entry_size = (uint16_t)entry_size;
    strcpy(entry->str, path);

    ft->locations[ft->hash_count] = (BlobLocation){ft->current_blob, ft->current_offset};
    ft->hash_table[slot] = ft->hash_count + 1;
    ft->hash_count++;

    ft->current_offset += entry_size;
    ft->total_count++;
    ft->blob_entry_counts[ft->current_blob]++;

    return true;
}

bool ft_remove(FileTable* ft, const char* path, uint32_t hash) {
    if (!ft || !path || hash == 0) return false;

    size_t slot = find_slot(ft, hash);
    if (ft->hash_table[slot] == 0) {
        return false;
    }

    uint32_t idx = ft->hash_table[slot] - 1;
    BlobLocation* loc = &ft->locations[idx];

    FileEntry* entry = (FileEntry*)(ft->blobs[loc->blob_idx] + loc->offset);
    uint16_t entry_size = entry->entry_size;

    size_t blob_end = (loc->blob_idx == ft->current_blob) ? ft->current_offset : BLOB_SIZE;
    size_t bytes_after = blob_end - (loc->offset + entry_size);

    if (bytes_after > 0) {
        memmove(entry, (char*)entry + entry_size, bytes_after);
    }

    if (loc->blob_idx == ft->current_blob) {
        ft->current_offset -= entry_size;
    }

    for (size_t i = 0; i < ft->hash_count; i++) {
        if (ft->locations[i].blob_idx == loc->blob_idx &&
            ft->locations[i].offset > loc->offset) {
            ft->locations[i].offset -= entry_size;
        }
    }

    ft->blob_entry_counts[loc->blob_idx]--;
    ft->hash_table[slot] = 0;
    ft->hash_count--;
    ft->total_count--;

    return true;
}

bool ft_lookup(FileTable* ft, uint32_t hash, const char* path) {
    if (!ft || !path || hash == 0) return false;

    size_t slot = find_slot(ft, hash);
    return ft->hash_table[slot] != 0;
}

const char* ft_lookup_by_hash(FileTable* ft, uint32_t hash) {
    if (!ft || hash == 0) return NULL;

    size_t slot = find_slot(ft, hash);
    if (ft->hash_table[slot] == 0) {
        return NULL;
    }

    BlobLocation* loc = &ft->locations[ft->hash_table[slot] - 1];
    FileEntry* entry = (FileEntry*)(ft->blobs[loc->blob_idx] + loc->offset);
    return entry->str;
}

void ft_iterate(FileTable* ft, ft_iterator callback, void* user_data) {
    for (size_t i = 0; i < ft->blob_count; i++) {
        char* blob = (char*)ft->blobs[i];
        FileEntry* entry = (FileEntry*)blob;

        uint16_t remaining = ft->blob_entry_counts[i];
        while (remaining-- > 0) {
            callback(entry->hash, entry->str, user_data);
            entry = (FileEntry*)((char*)entry + entry->entry_size);
        }
    }
}

size_t ft_size(FileTable* ft) {
    return ft ? ft->total_count : 0;
}
