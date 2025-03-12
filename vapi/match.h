#ifndef MATCH_H
#define MATCH_H

#include <math.h>
#include <stddef.h>
#include <stdint.h>

typedef double score_t;
#define SCORE_MAX 100.0
#define SCORE_MIN 0.0
#define MATCH_MAX_LEN 512

#define SWAP(x, y, T) do { T SWAP = x; x = y; y = SWAP; } while (0)
#define MAX(a, b) (((a) > (b)) ? (a) : (b))

typedef struct {
    int len;
    int orig_len;
    const char *original;
    uint32_t chars[MATCH_MAX_LEN] __attribute__((aligned(32)));
    uint32_t unicode_upper[MATCH_MAX_LEN] __attribute__((aligned(32)));
    const char *raw_upper;
} needle_info;

typedef struct {
    int len;
    score_t bonus[MATCH_MAX_LEN];
    uint32_t chars[MATCH_MAX_LEN];
} haystack_info;

// Core needle_info functions
needle_info* prepare_needle(const char* needle);
void free_string_info(needle_info* info);

// Matching functions
int query_has_match(const needle_info* needle, const char* haystack);
score_t match_score(const needle_info* needle, const char* haystack);

// Offset variants
int query_has_match_with_offset(const needle_info* needle, const char* haystack, unsigned int offset);
score_t match_score_with_offset(const needle_info* needle, const char* haystack, unsigned int offset);
score_t match_and_score(const needle_info* needle, const char* haystack_str, unsigned int offset);

// Position matching
score_t match_positions(const needle_info* needle, const char* haystack, int* positions);

#endif // MATCH_H
