[CCode (cheader_filename = "clipboard-hashtable.h")]
namespace ClipboardHash {
    [Compact]
    [CCode (cname = "HashTable", free_function = "ht_destroy", has_type_id = false)]
    public class Table {
        [CCode (cname = "ht_create")]
        public Table(size_t initial_capacity);

        [CCode (cname = "ht_insert")]
        public bool insert(uint32 primkey, string text, int64 timestamp, string content_type);

        [CCode (cname = "ht_insert_shift")]
        public bool insert_shift(uint32 primkey, string text, int64 timestamp, string content_type);

        [CCode (cname = "ht_remove")]
        public bool remove(uint32 key);

        [CCode (cname = "ht_remove_shift")]
        public bool remove_shift(uint32 key);

        [CCode (cname = "ht_lookup")]
        public unowned Entry? lookup(uint32 key);

        [CCode (cname = "ht_entries", array_length_type = "size_t", array_length_cname = "size")]
        public unowned Entry[] get_entries();
    }

    [CCode (cname = "ClipboardEntry", has_type_id = false, destroy_function = "")]
    public struct Entry {
        public uint32 primkey;
        public string text;
        public int64 timestamp;
        public string content_type;
    }
}
