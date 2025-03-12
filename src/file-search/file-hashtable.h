#ifndef FILE_HASHTABLE_H
#define FILE_HASHTABLE_H

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>

typedef struct {
    uint32_t hash;      // Hash of the path
    char* path;         // The file path
} FileEntry;

typedef struct {
    FileEntry* array;
    uint32_t* hash_to_idx;
    size_t* idx_to_hash_slot;
    size_t capacity;
    size_t size;
    size_t array_capacity;
} FileTable;

FileTable* ft_create(size_t initial_capacity);
void ft_destroy(FileTable* ft);
bool ft_insert(FileTable* ft, const char* path, uint32_t hash);
bool ft_remove(FileTable* ft, const char* path, uint32_t hash);
const FileEntry* ft_lookup(FileTable* ft, uint32_t hash);
const FileEntry* ft_entries(FileTable* ft, size_t* length);

#endif // FILE_HASHTABLE_H
