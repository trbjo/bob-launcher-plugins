[CCode (cheader_filename = "file-tree-manager.h")]
namespace FileTreeManager {
    [CCode (cname = "file_tree_manager_initialize")]
    public void initialize(int shards);

    [CCode (cname = "file_tree_manager_add_file")]
    public void add_file(string path);

    [CCode (cname = "file_tree_manager_remove_file")]
    public void remove_file(string path);

    [CCode (cname = "file_tree_manager_total_size")]
    public uint total_size();

    [CCode (cname = "file_tree_manager_tree_manager_shard")]
    public void tree_manager_shard(BobLauncher.ResultContainer rs, uint shard_id, double bonus);

    [CCode (cname = "file_tree_manager_cleanup")]
    public void cleanup();
}
