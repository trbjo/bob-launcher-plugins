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

static unsigned int get_shard_index(const char* path) {
    return hash_folder(path) % num_shards;
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

// 27-bit mask
#define HASH27_MASK   0x7FFFFFF    // (1<<27)-1 = 0x07FF FFFF

#define PACK_USER_DATA(i, hash) ( \
    (((uint64_t)(hash) & HASH27_MASK)) |             /* low 27 bits */ \
    (((uint64_t)(i) & 0xFFFF) << 27)                 /* next 16 bits */ \
)

#define UNPACK_HASH(x)  ((uint32_t)((x) & HASH27_MASK))
#define UNPACK_I(x)     ((uint16_t)(((x) >> 27) & 0xFFFF))

#define MIN(a, b) (((a) < (b)) ? (a) : (b))

static inline BobLauncherMatch* custom_factory_func(void *user_data) {
    uint64_t shifted_back = ((uint64_t)user_data >> 4);

    uint32_t wanted_hsh = UNPACK_HASH(shifted_back);
    uint16_t i          = UNPACK_I(shifted_back);
    uint8_t shard_id    = wanted_hsh % num_shards;

    const char *resolved_path =
        ft_lookup_by_index(shards[shard_id], i);

    if (!resolved_path)
        return (BobLauncherMatch*)bob_launcher_file_match_new_from_path("/");

    uint32_t found_folder_hash = hash_folder(resolved_path);

    // Mask down to 27 bits to match our stored truncated hash
    found_folder_hash &= HASH27_MASK;

    if (found_folder_hash != wanted_hsh)
        return (BobLauncherMatch*)bob_launcher_file_match_new_from_path("/");

    BobLauncherMatch* match = (BobLauncherMatch*)
        bob_launcher_file_match_new_from_path(resolved_path);
    free(resolved_path);
    return match;
}


void file_tree_manager_tree_manager_shard(ResultContainer* rs, unsigned int shard_id) {
    if (shard_id >= num_shards) return;
    FileTable* ft = shards[shard_id];

    const int n = rs->string_info->len;
    if (n == 0) return;

    haystack_info* hay = calloc(1, sizeof(haystack_info));
    haystack_index* index = calloc(MATCH_MAX_LEN, sizeof(haystack_index));
    CacheCell* cache = calloc(MATCH_MAX_LEN * n, sizeof(CacheCell));

    size_t offset = 0;
    uint16_t i = 0;
    int cache_valid_cols = 0;

    spin_lock(&ft->lock);

    while (offset < ft->used) {
        FileEntry* entry = (FileEntry*)(ft->data + offset);

        cache_valid_cols = MIN(cache_valid_cols, index[entry->common_chars].pos);

        int matched = haystack_update(hay, entry->str, entry->common_chars, index, rs->string_info);

        if (matched) {
            score_t score = match_score_column_major(rs->string_info, hay, cache_valid_cols, cache);
            cache_valid_cols = hay->len;
            result_container_add_lazy(
                rs,
                entry->hash,
                score,
                custom_factory_func,
                (void*)(PACK_USER_DATA(i, entry->folder_hash) << 4),
                NULL
            );
        }

        i++;
        offset += entry->entry_size;
    }

    spin_unlock(&ft->lock);

    free(hay);
    free(index);
    free(cache);
}

// #include <time.h>
// #include <stdatomic.h>
// static atomic_int shard_counter = 0;
// static atomic_int total_results = 0;
// static atomic_long total_time_ns = 0;

// void file_search_wrapper(ResultContainer* rs, unsigned int shard_id) {
//     struct timespec start, end;
//     clock_gettime(CLOCK_MONOTONIC, &start);
//     int results = file_search_inner(rs, shard_id);
//     clock_gettime(CLOCK_MONOTONIC, &end);

//     long elapsed_ns = (end.tv_sec - start.tv_sec) * 1000000000L + (end.tv_nsec - start.tv_nsec);
//     atomic_fetch_add(&total_time_ns, elapsed_ns);
//     atomic_fetch_add(&total_results, results);

//     int count = atomic_fetch_add(&shard_counter, 1) + 1;
//     if (count % num_shards == 0) {
//         long total = atomic_exchange(&total_time_ns, 0);
//         int _total_results = atomic_exchange(&total_results, 0);
//         printf("all %u shards: %.3f ms, res: %d\n", num_shards, total / 1e6,_total_results);
//     }
// }

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
