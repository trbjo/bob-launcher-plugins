#include "clipboard-hashtable.h"

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

static size_t find_slot(uint32_t* hash_to_idx, size_t capacity, uint32_t key, ClipboardEntry* array) {
    size_t mask = capacity - 1;
    size_t slot = key & mask;

    while (hash_to_idx[slot] != 0) {
        size_t idx = hash_to_idx[slot] - 1;
        if (array[idx].primkey == key) {
            return slot;
        }
        slot = (slot + 1) & mask;
    }
    return slot;
}

static void maybe_grow_array(HashTable* ht) {
    if (ht->size >= ht->array_capacity) {
        size_t new_capacity = ht->array_capacity * 2;
        ClipboardEntry* new_array = realloc(ht->array, new_capacity * sizeof(ClipboardEntry));
        size_t* new_idx_to_hash_slot = realloc(ht->idx_to_hash_slot, new_capacity * sizeof(size_t));

        if (new_array && new_idx_to_hash_slot) {
            ht->array = new_array;
            ht->idx_to_hash_slot = new_idx_to_hash_slot;
            ht->array_capacity = new_capacity;
        }
    }
}

static void resize_hash(HashTable* ht) {
    size_t new_capacity = ht->capacity * 2;
    uint32_t* new_hash_to_idx = calloc(new_capacity, sizeof(uint32_t));

    if (new_hash_to_idx) {
        for (size_t i = 0; i < ht->size; i++) {
            uint32_t key = ht->array[i].primkey;
            size_t new_slot = find_slot(new_hash_to_idx, new_capacity, key, ht->array);
            new_hash_to_idx[new_slot] = i + 1;
            ht->idx_to_hash_slot[i] = new_slot;
        }

        free(ht->hash_to_idx);
        ht->hash_to_idx = new_hash_to_idx;
        ht->capacity = new_capacity;
    }
}

static inline void ht_lock(HashTable* ht) {
    while (atomic_exchange(&ht->lock, 1)) __builtin_ia32_pause();
}

static inline void ht_unlock(HashTable* ht) {
    atomic_store(&ht->lock, 0);
}

HashTable* ht_create(size_t initial_capacity) {
    initial_capacity = next_power_of_2(initial_capacity);
    HashTable* ht = malloc(sizeof(HashTable));
    if (!ht) return NULL;

    ht->array = malloc(initial_capacity * sizeof(ClipboardEntry));
    ht->hash_to_idx = calloc(initial_capacity, sizeof(uint32_t));
    ht->idx_to_hash_slot = malloc(initial_capacity * sizeof(size_t));

    if (!ht->array || !ht->hash_to_idx || !ht->idx_to_hash_slot) {
        free(ht->array);
        free(ht->hash_to_idx);
        free(ht->idx_to_hash_slot);
        free(ht);
        return NULL;
    }

    ht->capacity = initial_capacity;
    ht->array_capacity = initial_capacity;
    ht->size = 0;
    atomic_init(&ht->lock, 0);

    return ht;
}

void ht_destroy(HashTable* ht) {
    if (!ht) return;

    for (size_t i = 0; i < ht->size; i++) {
        free(ht->array[i].text);
        free(ht->array[i].content_type);
    }

    free(ht->array);
    free(ht->hash_to_idx);
    free(ht->idx_to_hash_slot);
    free(ht);
}

bool ht_insert(HashTable* ht, uint32_t primkey, const char* text, int64_t timestamp, const char* content_type) {
    if (!ht || primkey == 0 || !text || !content_type) return false;
    ht_lock(ht);

    if (ht->size >= ht->capacity * 0.75) {
        resize_hash(ht);
    }

    size_t slot = find_slot(ht->hash_to_idx, ht->capacity, primkey, ht->array);

    if (ht->hash_to_idx[slot] != 0) {
        size_t idx = ht->hash_to_idx[slot] - 1;
        free(ht->array[idx].text);
        free(ht->array[idx].content_type);
        ht->array[idx].text = strdup(text);
        ht->array[idx].content_type = strdup(content_type);
        ht->array[idx].timestamp = timestamp;
        ht_unlock(ht);
        return true;
    }

    maybe_grow_array(ht);

    ht->array[ht->size].primkey = primkey;
    ht->array[ht->size].text = strdup(text);
    ht->array[ht->size].content_type = strdup(content_type);
    ht->array[ht->size].timestamp = timestamp;

    ht->hash_to_idx[slot] = ht->size + 1;
    ht->idx_to_hash_slot[ht->size] = slot;
    ht->size++;

    ht_unlock(ht);
    return true;
}

bool ht_insert_shift(HashTable* ht, uint32_t primkey, const char* text, int64_t timestamp, const char* content_type) {
    if (!ht || primkey == 0 || !text || !content_type) return false;

    ht_lock(ht);

    // If key exists, remove it first
    size_t slot = find_slot(ht->hash_to_idx, ht->capacity, primkey, ht->array);
    if (ht->hash_to_idx[slot] != 0) {
        size_t idx = ht->hash_to_idx[slot] - 1;
        free(ht->array[idx].text);
        free(ht->array[idx].content_type);

        memmove(&ht->array[idx], &ht->array[idx + 1],
                (ht->size - idx - 1) * sizeof(ClipboardEntry));
        ht->size--;

        // Update hash indices for shifted entries
        for (size_t i = idx; i < ht->size; i++) {
            size_t entry_slot = ht->idx_to_hash_slot[i + 1];
            ht->hash_to_idx[entry_slot] = i + 1;
            ht->idx_to_hash_slot[i] = entry_slot;
        }
    }

    // Check if we need to resize the hash table
    if (ht->size >= ht->capacity * 0.75) {
        resize_hash(ht);
    }

    // Make sure we have enough space in the array
    maybe_grow_array(ht);

    // Ensure we have room for one more element
    if (ht->size + 1 > ht->array_capacity) {
        size_t new_capacity = ht->array_capacity * 2;
        ClipboardEntry* new_array = realloc(ht->array, new_capacity * sizeof(ClipboardEntry));
        size_t* new_idx_to_hash_slot = realloc(ht->idx_to_hash_slot, new_capacity * sizeof(size_t));

        if (new_array && new_idx_to_hash_slot) {
            ht->array = new_array;
            ht->idx_to_hash_slot = new_idx_to_hash_slot;
            ht->array_capacity = new_capacity;
        } else {
            // Handle allocation failure
            ht_unlock(ht);
            return false;
        }
    }

    // Shift everything up
    memmove(&ht->array[1], &ht->array[0], ht->size * sizeof(ClipboardEntry));

    // Update hash indices for all shifted entries
    for (size_t i = ht->size; i > 0; i--) {
        size_t entry_slot = ht->idx_to_hash_slot[i - 1];
        ht->hash_to_idx[entry_slot] = i + 1;
        ht->idx_to_hash_slot[i] = entry_slot;
    }

    // Insert at front
    ht->array[0].primkey = primkey;
    ht->array[0].text = strdup(text);
    ht->array[0].content_type = strdup(content_type);
    ht->array[0].timestamp = timestamp;

    ht->hash_to_idx[slot] = 1;
    ht->idx_to_hash_slot[0] = slot;
    ht->size++;

    ht_unlock(ht);
    return true;
}

bool ht_remove(HashTable* ht, uint32_t key) {
    if (!ht || key == 0) return false;

    ht_lock(ht);

    size_t slot = find_slot(ht->hash_to_idx, ht->capacity, key, ht->array);
    if (ht->hash_to_idx[slot] == 0) {
        ht_unlock(ht);
        return false;
    }

    size_t idx = ht->hash_to_idx[slot] - 1;

    free(ht->array[idx].text);
    free(ht->array[idx].content_type);

    if (idx < ht->size - 1) {
        ht->array[idx] = ht->array[ht->size - 1];
        size_t moved_slot = ht->idx_to_hash_slot[ht->size - 1];
        ht->hash_to_idx[moved_slot] = idx + 1;
        ht->idx_to_hash_slot[idx] = moved_slot;
    }

    ht->hash_to_idx[slot] = 0;
    ht->size--;

    ht_unlock(ht);
    return true;
}

const ClipboardEntry* ht_lookup(HashTable* ht, uint32_t key) {
    if (!ht || key == 0) return NULL;

    size_t slot = find_slot(ht->hash_to_idx, ht->capacity, key, ht->array);
    if (ht->hash_to_idx[slot] == 0) return NULL;

    return &ht->array[ht->hash_to_idx[slot] - 1];
}

const ClipboardEntry* ht_entries(HashTable* ht, size_t* length) {
    if (!ht || !length) return NULL;

    ht_lock(ht);
    *length = ht->size;
    const ClipboardEntry* entries = ht->array;
    ht_unlock(ht);
    return entries;
}
