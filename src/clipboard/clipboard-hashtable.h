#ifndef CLIPBOARD_HASHTABLE_H
#define CLIPBOARD_HASHTABLE_H

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>

typedef struct {
    uint32_t primkey;
    char* text;
    int64_t timestamp;
    char* content_type;
} ClipboardEntry;

typedef struct {
    ClipboardEntry* array;
    uint32_t* hash_to_idx;
    size_t* idx_to_hash_slot;
    size_t capacity;
    size_t size;
    size_t array_capacity;
    atomic_int lock;
} HashTable;

HashTable* ht_create(size_t initial_capacity);
void ht_destroy(HashTable* ht);
bool ht_insert(HashTable* ht, uint32_t primkey, const char* text, int64_t timestamp, const char* content_type);
bool ht_remove(HashTable* ht, uint32_t key);
bool ht_remove_shift(HashTable* ht, uint32_t key);
bool ht_insert_shift(HashTable* ht, uint32_t primkey, const char* text, int64_t timestamp, const char* content_type);
const ClipboardEntry* ht_lookup(HashTable* ht, uint32_t key);
const ClipboardEntry* ht_entries(HashTable* ht, size_t* length);

#endif // CLIPBOARD_HASHTABLE_H
