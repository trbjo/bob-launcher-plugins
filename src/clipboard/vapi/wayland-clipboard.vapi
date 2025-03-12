namespace WaylandClipboard {
    [Compact]
    [CCode (cname = "clipboard_manager", cheader_filename = "wayland-clipboard.h", free_function = "clipboard_manager_destroy")]
    public class Manager {
        [CCode (has_type_id=false, has_target = false)]
        public delegate void ClipboardChangedFunc(GLib.HashTable<GLib.Bytes, GLib.GenericArray<string>> content, uint hash);

        [CCode (cname = "clipboard_manager_new")]
        public Manager(ClipboardChangedFunc callback);

        [CCode (cname = "clipboard_manager_set_clipboard", cheader_filename = "wayland-clipboard.h", has_target = false)]
        public void set_clipboard(GLib.HashTable<GLib.Bytes, GLib.GenericArray<string>> content);

        [CCode (cname = "clipboard_manager_listen", cheader_filename = "wayland-clipboard.h")]
        public void listen();
    }
}
