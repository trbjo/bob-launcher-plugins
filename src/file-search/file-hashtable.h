#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdatomic.h>

#define CACHE_LINE_SIZE 64

typedef struct {
    uint16_t entry_size;
    uint32_t hash;
    uint32_t folder_hash;
    uint16_t common_chars;
    char str[];
} FileEntry;

typedef struct {
    char* data;
    size_t capacity;
    size_t used;
    size_t count;
    size_t* offsets;          // Array mapping index -> byte offset in data
    size_t offsets_capacity;  // Capacity of offsets array
    atomic_flag lock;
} FileTable;

FileTable* ft_create();
void ft_destroy(FileTable* ft);
bool ft_insert(FileTable* ft, const char* path);
bool ft_remove(FileTable* ft, const char* path);
const char* ft_lookup_by_index(FileTable* ft, uint16_t index);
