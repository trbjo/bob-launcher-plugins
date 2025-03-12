#include "file-tree-manager.h"
#include "file-hashtable.h"
#include "stdatomic.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <limits.h>

#define CACHE_LINE_SIZE 64

typedef struct {
    FileTable* table;
    atomic_int lock;
    char padding[CACHE_LINE_SIZE - sizeof(FileTable*) - sizeof(atomic_int)];
} __attribute__((aligned(CACHE_LINE_SIZE))) ShardData;

static ShardData* shards = NULL;
static unsigned int num_shards = 0;

typedef struct {
    atomic_int lock;
    int shortest_length;
    unsigned int prefix_length;
    char* prefix;
} __attribute__((aligned(CACHE_LINE_SIZE))) PrefixData;

static PrefixData prefix_data;

static unsigned int string_hash(const char* str) {
    unsigned int hash = 5381;
    int c;

    while ((c = *str++)) {
        hash = ((hash << 5) + hash) + c; // hash * 33 + c
    }

    return hash;
}

static char* string_duplicate(const char* str) {
    if (!str) return NULL;

    size_t len = strlen(str);
    char* dup = malloc(len + 1);
    if (dup) {
        memcpy(dup, str, len + 1);
    }
    return dup;
}

static char* string_concat_with_slash(const char* str) {
    if (!str) return NULL;

    size_t len = strlen(str);
    char* result = malloc(len + 2); // +1 for slash, +1 for null terminator
    if (!result) return NULL;

    strcpy(result, str);
    result[len] = '/';
    result[len + 1] = '\0';

    return result;
}

static inline void spin_lock(atomic_int* lock) {
    while (atomic_exchange(lock, 1)) {
        __builtin_ia32_pause();
    }
}

static inline void spin_unlock(atomic_int* lock) {
    atomic_store(lock, 0);
}

static unsigned int get_shard_index(const char* path);
static int has_suffix(const char* str, const char* suffix);

void file_tree_manager_initialize(int shard_count) {
    num_shards = shard_count;

    // Initialize prefix data
    atomic_init(&prefix_data.lock, 0);
    prefix_data.shortest_length = INT_MAX;
    prefix_data.prefix_length = 0;
    prefix_data.prefix = NULL;

    // Allocate and initialize cache-aligned shards
    // Use posix_memalign to ensure alignment
    shards = NULL;
    if (posix_memalign((void**)&shards, CACHE_LINE_SIZE,
                     num_shards * sizeof(ShardData)) != 0) {
        // Handle allocation failure
        fprintf(stderr, "Failed to allocate aligned memory for shards\n");
        return;
    }

    memset(shards, 0, num_shards * sizeof(ShardData));

    for (int i = 0; i < num_shards; i++) {
        shards[i].table = ft_create(512);
        atomic_init(&shards[i].lock, 0);
    }
}

static unsigned int get_shard_index(const char* path) {
    return string_hash(path) % num_shards;
}

static int has_suffix(const char* str, const char* suffix) {
    size_t str_len = strlen(str);
    size_t suffix_len = strlen(suffix);

    if (str_len < suffix_len)
        return 0;

    return (strcmp(str + str_len - suffix_len, suffix) == 0);
}

void file_tree_manager_add_file(const char* path) {
    unsigned int hash = string_hash(path);
    unsigned int shard_index = get_shard_index(path);

    // Lock only the specific shard
    spin_lock(&shards[shard_index].lock);
    ft_insert(shards[shard_index].table, path, hash);
    spin_unlock(&shards[shard_index].lock);

    // Update shortest prefix if needed
    int path_length = strlen(path);
    if (path_length < prefix_data.shortest_length) {
        spin_lock(&prefix_data.lock);
        if (path_length < prefix_data.shortest_length) {  // Double check under lock
            prefix_data.shortest_length = path_length;
            free(prefix_data.prefix);

            if (has_suffix(path, "/")) {
                prefix_data.prefix = string_duplicate(path);
            } else {
                prefix_data.prefix = string_concat_with_slash(path);
            }
            prefix_data.prefix_length = strlen(prefix_data.prefix);
        }
        spin_unlock(&prefix_data.lock);
    }
}

void file_tree_manager_remove_file(const char* path) {
    unsigned int hash = string_hash(path);
    unsigned int shard_index = get_shard_index(path);

    spin_lock(&shards[shard_index].lock);
    ft_remove(shards[shard_index].table, path, hash);
    spin_unlock(&shards[shard_index].lock);
}

unsigned int file_tree_manager_total_size(void) {
    unsigned int total = 0;

    for (int i = 0; i < num_shards; i++) {
        spin_lock(&shards[i].lock);
        size_t entries_length = 0;
        ft_entries(shards[i].table, &entries_length);
        total += entries_length;
        spin_unlock(&shards[i].lock);
    }

    return total;
}

static BobLauncherMatch* file_match_factory(void* user_data) {
    const char* path = (char*)user_data;
    return (BobLauncherMatch*)bob_launcher_file_match_new_from_path(path);
}

void file_tree_manager_tree_manager_shard(ResultContainer* rs, unsigned int shard_id, double bonus) {
    if (shard_id >= num_shards) return;

    unsigned int prefix_len = prefix_data.prefix_length;

    size_t entries_length = 0;
    spin_lock(&shards[shard_id].lock);
    const FileEntry* entries = ft_entries(shards[shard_id].table, &entries_length);

    for (size_t i = 0; i < entries_length; i++) {
        const FileEntry* entry = &entries[i];

        double score = result_container_match_score_with_offset(
            rs, entry->path, prefix_len);

        if (score > 0.0) {
            result_container_add_lazy(
                rs,
                entry->hash,
                score,
                file_match_factory,
                (void*)strdup(entry->path),
                free
            );
        }
    }
    spin_unlock(&shards[shard_id].lock);
}

void file_tree_manager_cleanup(void) {
    if (shards != NULL) {
        for (unsigned int i = 0; i < num_shards; i++) {
            spin_lock(&shards[i].lock);
            if (shards[i].table != NULL) {
                ft_destroy(shards[i].table);
                shards[i].table = NULL;
            }
            spin_unlock(&shards[i].lock);
        }
        free(shards);
        shards = NULL;
    }

    spin_lock(&prefix_data.lock);
    free(prefix_data.prefix);
    prefix_data.prefix = NULL;
    prefix_data.shortest_length = INT_MAX;
    prefix_data.prefix_length = 0;
    spin_unlock(&prefix_data.lock);
}
