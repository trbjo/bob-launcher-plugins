// [CCode (cheader_filename = "file-hashtable.h")]
// namespace FileHash {
    // [CCode (cname = "FileEntry", has_type_id = false, destroy_function = "")]
    // public struct Entry {
        // public unowned uint32 hash;
        // public unowned string path;
    // }

    // [Compact]
    // [CCode (cname = "FileTable", free_function = "ft_destroy", has_type_id = false)]
    // public class Table {
        // [CCode (cname = "ft_create")]
        // public Table(size_t initial_capacity);

        // [CCode (cname = "ft_insert")]
        // public bool insert(string path, uint32 hash);

        // [CCode (cname = "ft_remove")]
        // public bool remove(string path, uint32 hash);

        // [CCode (cname = "ft_lookup")]
        // public unowned Entry? lookup(uint32 hash);

        // [CCode (cname = "ft_entries", array_length_type = "size_t", array_length_cname = "length")]
        // public unowned Entry[] get_entries();
    // }
// }
