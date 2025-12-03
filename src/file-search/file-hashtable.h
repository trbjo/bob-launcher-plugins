#ifndef FILE_HASHTABLE_H
#define FILE_HASHTABLE_H

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdatomic.h>

typedef struct {
    uint16_t entry_size;
    char str[];
} FileEntry;

#define CACHE_LINE_SIZE 64

typedef struct {
    char* data;
    size_t capacity;
    size_t used;
    size_t count;
    atomic_flag lock;
    char _pad[CACHE_LINE_SIZE - sizeof(char*) - sizeof(size_t) * 3 - sizeof(atomic_flag)];
} FileTable;

typedef void (*ft_iterator)(uint16_t i, const char* path, void* user_data);

FileTable* ft_create();
void ft_destroy(FileTable* ft);
bool ft_insert(FileTable* ft, const char* path);
bool ft_remove(FileTable* ft, const char* path);
const char* ft_lookup_by_index(FileTable* ft, uint16_t index);
void ft_iterate(FileTable* ft, ft_iterator callback, void* user_data);

#endif // FILE_HASHTABLE_H
