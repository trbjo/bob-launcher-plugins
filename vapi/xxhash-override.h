#ifndef XXHASH_OVERRIDE_H
#define XXHASH_OVERRIDE_H

#include <xxhash.h>
#include <string.h>
#include <glib.h>

#ifdef g_str_hash
  #undef g_str_hash
#endif

#define g_str_hash(v) ((unsigned int)XXH3_64bits((const char*)(v), strlen((const char*)(v))))

#endif
