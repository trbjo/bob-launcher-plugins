#ifndef FILE_HASHTABLE_H
#define FILE_HASHTABLE_H

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>

#define BLOB_SIZE 65536

typedef struct {
    uint32_t blob_idx;
    uint32_t offset;
} BlobLocation;

typedef struct {
    uint32_t hash;
    uint16_t entry_size;
    char str[];
} __attribute__((packed, aligned(4))) FileEntry;

typedef struct {
    char** blobs;                // array of 8KB blocks
    size_t blob_count;           // number of allocated blobs
    uint16_t* blob_entry_counts; // entries per blob
    size_t blob_capacity;        // capacity of blobs array
    size_t current_blob;         // index of current blob being filled
    size_t current_offset;       // offset in current blob

    uint32_t* hash_table;        // hash -> index into locations array (0 = empty)
    BlobLocation* locations;     // blob_idx + offset for each hash
    size_t hash_capacity;
    size_t hash_count;           // number of entries in hash table

    size_t total_count;          // total number of strings
} FileTable;

typedef void (*ft_iterator)(uint32_t hash, const char* path, void* user_data);

FileTable* ft_create(size_t initial_capacity);
void ft_destroy(FileTable* ft);
bool ft_insert(FileTable* ft, const char* path, uint32_t hash);
bool ft_remove(FileTable* ft, const char* path, uint32_t hash);
bool ft_lookup(FileTable* ft, uint32_t hash, const char* path);
const char* ft_lookup_by_hash(FileTable* ft, uint32_t hash);
void ft_iterate(FileTable* ft, ft_iterator callback, void* user_data);
size_t ft_size(FileTable* ft);

#endif // FILE_HASHTABLE_H
