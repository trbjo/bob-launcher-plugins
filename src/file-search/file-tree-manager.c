#include "file-tree-manager.h"
#include "file-hashtable.h"
#include "match.h"
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
static char* global_prefix = NULL;  // Store prefix globally for convenience
static unsigned int global_prefix_len = 0;

static char* string_duplicate(const char* str) {
    if (!str) return NULL;

    size_t len = strlen(str);
    char* dup = malloc(len + 1);
    if (dup) {
        memcpy(dup, str, len + 1);
    }
    return dup;
}

static inline void spin_lock(atomic_int* lock) {
    while (atomic_exchange(lock, 1)) {
        __builtin_ia32_pause();
    }
}

static inline void spin_unlock(atomic_int* lock) {
    atomic_store(lock, 0);
}

// Convert absolute path to relative by stripping prefix
static inline const char* make_relative(const char* absolute_path) {
    if (global_prefix_len > 0 &&
        strncmp(absolute_path, global_prefix, global_prefix_len) == 0) {
        return absolute_path + global_prefix_len;
    }
    return absolute_path;
}

// Convert relative path to absolute by adding prefix
static char* make_absolute(const char* relative_path) {
    if (!global_prefix || global_prefix_len == 0) {
        return string_duplicate(relative_path);
    }

    size_t rel_len = strlen(relative_path);
    char* absolute = malloc(global_prefix_len + rel_len + 1);
    if (absolute) {
        memcpy(absolute, global_prefix, global_prefix_len);
        memcpy(absolute + global_prefix_len, relative_path, rel_len + 1);
    }
    return absolute;
}

static unsigned int get_shard_index(const char* path);
static int has_suffix(const char* str, const char* suffix);

void file_tree_manager_initialize(int shard_count, const char* prefix) {
    num_shards = shard_count;

    if (prefix && *prefix) {
        size_t len = strlen(prefix);
        // Add trailing slash if not present
        if (prefix[len - 1] != '/') {
            global_prefix = malloc(len + 2);
            if (global_prefix) {
                memcpy(global_prefix, prefix, len);
                global_prefix[len] = '/';
                global_prefix[len + 1] = '\0';
                global_prefix_len = len + 1;
            }
        } else {
            global_prefix = string_duplicate(prefix);
            global_prefix_len = len;
        }
    } else {
        global_prefix = NULL;
        global_prefix_len = 0;
    }

    // Allocate and initialize cache-aligned shards
    shards = NULL;
    if (posix_memalign((void**)&shards, CACHE_LINE_SIZE,
                     num_shards * sizeof(ShardData)) != 0) {
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
    return g_str_hash(path) % num_shards;
}

static int has_suffix(const char* str, const char* suffix) {
    size_t str_len = strlen(str);
    size_t suffix_len = strlen(suffix);

    if (str_len < suffix_len)
        return 0;

    return (strcmp(str + str_len - suffix_len, suffix) == 0);
}

void file_tree_manager_add_file(const char* path) {
    // Convert to relative path for storage
    const char* relative_path = make_relative(path);
    uint32_t hash = g_str_hash(path);
    unsigned int shard_index = get_shard_index(path);

    spin_lock(&shards[shard_index].lock);
    ft_insert(shards[shard_index].table, relative_path, hash);
    spin_unlock(&shards[shard_index].lock);
}

void file_tree_manager_remove_file(const char* path) {
    // Convert to relative path for removal
    const char* relative_path = make_relative(path);
    uint64_t hash = g_str_hash(path);
    unsigned int shard_index = get_shard_index(path);

    spin_lock(&shards[shard_index].lock);
    ft_remove(shards[shard_index].table, relative_path, hash);
    spin_unlock(&shards[shard_index].lock);
}

#define PACK_INFO(shard_id, hash) \
    ((((uint64_t)(shard_id) << 32) | ((uint64_t)(hash))))

#define UNPACK_HASH(packed_ptr) \
    ((uint32_t)(packed_ptr))

#define UNPACK_SHARD_ID(packed_ptr) \
    (((uint64_t)(packed_ptr) >> 32) & 0xFF)

static inline BobLauncherMatch* custom_factory_func(void *user_data) {
    uint64_t shifted_back = ((uint64_t)user_data >> 4);

    uint8_t shard_id = UNPACK_SHARD_ID(shifted_back);
    uint32_t hash = UNPACK_HASH(shifted_back);

    spin_lock(&shards[shard_id].lock);
    const char* relative_path = ft_lookup_by_hash(shards[shard_id].table, hash);
    spin_unlock(&shards[shard_id].lock);

    if (!relative_path) return NULL;

    char* absolute_path = make_absolute(relative_path);
    if (!absolute_path) return NULL;

    BobLauncherMatch* match = (BobLauncherMatch*)bob_launcher_file_match_new_from_path(absolute_path);
    free(absolute_path);

    return match;
}


typedef struct {
    ResultContainer* rs;
    unsigned int shard_id;
} ShardIterData;

static void shard_iter_callback(uint32_t hash, const char* path, void* data) {
    result_container_add_lazy(
        ((ShardIterData*)data)->rs,
        hash,
        result_container_match_score(((ShardIterData*)data)->rs, path),
        custom_factory_func,
        (void*)(PACK_INFO(((ShardIterData*)data)->shard_id, hash) << 4),
        NULL
    );
}

void file_tree_manager_tree_manager_shard(ResultContainer* rs, unsigned int shard_id) {
    if (shard_id >= num_shards) return;

    spin_lock(&shards[shard_id].lock);
    ShardIterData data = { .rs = rs, .shard_id = shard_id };
    ft_iterate(shards[shard_id].table, shard_iter_callback, &data);
    spin_unlock(&shards[shard_id].lock);
}

typedef struct {
    const char* prefix;
    size_t prefix_len;
    char** paths;
    uint32_t* hashes;
    size_t count;
    size_t capacity;
} RemoveData;

static void remove_iter_callback(uint32_t hash, const char* path, void* user_data) {
    RemoveData* data = (RemoveData*)user_data;

    if (strncmp(path, data->prefix, data->prefix_len) == 0) {
        if (data->count < data->capacity) {
            data->paths[data->count] = strdup(path);
            data->hashes[data->count] = hash;
            data->count++;
        }
    }
}

void file_tree_manager_remove_by_prefix_shard(unsigned int shard_id, const char* prefix) {
    if (shard_id >= num_shards || !prefix) return;

    const char* relative_prefix = make_relative(prefix);
    size_t prefix_len = strlen(relative_prefix);
    char* normalized_prefix = NULL;

    if (relative_prefix[prefix_len - 1] != '/') {
        normalized_prefix = malloc(prefix_len + 2);
        if (!normalized_prefix) return;
        strcpy(normalized_prefix, relative_prefix);
        normalized_prefix[prefix_len] = '/';
        normalized_prefix[prefix_len + 1] = '\0';
        relative_prefix = normalized_prefix;
        prefix_len++;
    }

    spin_lock(&shards[shard_id].lock);

    size_t capacity = ft_size(shards[shard_id].table);
    RemoveData data = {
        .prefix = relative_prefix,
        .prefix_len = prefix_len,
        .paths = malloc(capacity * sizeof(char*)),
        .hashes = malloc(capacity * sizeof(uint32_t)),
        .count = 0,
        .capacity = capacity
    };

    if (data.paths && data.hashes) {
        ft_iterate(shards[shard_id].table, remove_iter_callback, &data);

        for (size_t i = 0; i < data.count; i++) {
            if (data.paths[i]) {
                ft_remove(shards[shard_id].table, data.paths[i], data.hashes[i]);
                free(data.paths[i]);
            }
        }
    }

    if (data.paths) free(data.paths);
    if (data.hashes) free(data.hashes);

    spin_unlock(&shards[shard_id].lock);

    if (normalized_prefix) free(normalized_prefix);
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

    if (global_prefix) {
        free(global_prefix);
        global_prefix = NULL;
        global_prefix_len = 0;
    }
}
