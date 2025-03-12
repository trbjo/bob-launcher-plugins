#ifndef FILE_TREE_MANAGER_H
#define FILE_TREE_MANAGER_H

#include <glib.h>
#include "bob-launcher.h" // Include for ResultContainer definition

void file_tree_manager_initialize(gint shards);
void file_tree_manager_add_file(const gchar* path);
void file_tree_manager_remove_file(const gchar* path);
guint file_tree_manager_total_size(void);
void file_tree_manager_tree_manager_shard(ResultContainer* rs, guint shard_id, double bonus);
void file_tree_manager_cleanup(void);

#endif // FILE_TREE_MANAGER_H
