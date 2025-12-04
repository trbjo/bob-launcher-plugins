#include "file-tree-manager.h"
#include "constants.h"
#include "file-hashtable.h"
#include "match.h"
#include <stdatomic.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <limits.h>

#define CACHE_LINE_SIZE 64

static FileTable** shards = NULL;
static unsigned int num_shards = 0;

static unsigned int get_shard_index(const char* path) {
    return g_str_hash(path) % num_shards;
}

void file_tree_manager_initialize(int shard_count) {
    num_shards = shard_count;

    shards = NULL;
    if (posix_memalign((void**)&shards, CACHE_LINE_SIZE,
                     num_shards * sizeof(*shards)) != 0) {
        fprintf(stderr, "Failed to allocate aligned memory for shards\n");
        return;
    }

    memset(shards, 0, num_shards * sizeof(*shards));

    for (int i = 0; i < num_shards; i++) {
        shards[i] = ft_create();
    }
}

void file_tree_manager_add_file(const char* path) {
    unsigned int shard_index = get_shard_index(path);
    ft_insert(shards[shard_index], path);
}

void file_tree_manager_remove_file(const char* path) {
    unsigned int shard_index = get_shard_index(path);
    ft_remove(shards[shard_index], path);
}

#define PACK_USER_DATA(i, hash) ( \
    ((uint64_t)(hash) & 0xFFFFFFFF) | \
    (((uint64_t)(i) & 0xFFFF) << 32) \
)

#define UNPACK_HASH(x)      ((uint32_t)((x)))
#define UNPACK_I(x)         ((uint16_t)(((x) >> 32) & 0xFFFF))

static inline BobLauncherMatch* custom_factory_func(void *user_data) {
    uint64_t shifted_back = ((uint64_t)user_data >> 4);

    uint32_t wanted_hsh   = UNPACK_HASH(shifted_back);
    uint16_t i        = UNPACK_I(shifted_back);
    uint8_t shard_id  = wanted_hsh % num_shards;

    const char *resolved_path =
        ft_lookup_by_index(shards[shard_id], i);

    if (!resolved_path)
        return (BobLauncherMatch*)bob_launcher_file_match_new_from_path("/");

    uint32_t found_hsh = g_str_hash(resolved_path);

    if (found_hsh != wanted_hsh)
        return (BobLauncherMatch*)bob_launcher_file_match_new_from_path("/");

    BobLauncherMatch* match = (BobLauncherMatch*)bob_launcher_file_match_new_from_path(resolved_path);
    free(resolved_path);

    return match;
}

static void shard_iter_callback(uint16_t i, const char* path, uint32_t hash, void* data) {
    score_t score = result_container_match_score(((ResultContainer*)data), path);
    if (score > SCORE_THRESHOLD) {
        result_container_add_lazy(
            ((ResultContainer*)data),
            hash,
            score,
            custom_factory_func,
            (void*)(PACK_USER_DATA(i, hash) << 4),
            NULL
        );
    }
}

void file_tree_manager_tree_manager_shard(ResultContainer* rs, unsigned int shard_id) {
    if (shard_id >= num_shards) return;
    ft_iterate(shards[shard_id], shard_iter_callback, rs);
}

void file_tree_manager_cleanup(void) {
    if (shards != NULL) {
        for (unsigned int i = 0; i < num_shards; i++) {
            if (shards[i] != NULL) {
                ft_destroy(shards[i]);
                shards[i] = NULL;
            }
        }
        free(shards);
        shards = NULL;
    }
}
