#ifndef FILE_TREE_MANAGER_H
#define FILE_TREE_MANAGER_H

#include "bob-launcher.h" // Include for ResultContainer definition

void file_tree_manager_initialize(int shards);
void file_tree_manager_add_file(const gchar* path);
void file_tree_manager_remove_file(const gchar* path);
void file_tree_manager_tree_manager_shard(ResultContainer* rs, uint shard_id);
void file_tree_manager_cleanup(void);

#endif // FILE_TREE_MANAGER_H
