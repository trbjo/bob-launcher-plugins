namespace Monitors {
    [CCode (cname = "add_paths", cheader_filename = "file-monitor.h")]
    private extern int add_paths([CCode (array_length_pos = 1)] string[] paths, FileChangeCallback callback);

    [CCode (cname = "remove_paths", cheader_filename = "file-monitor.h")]
    private extern int remove_paths([CCode (array_length_pos = 1)] string[] paths);

    [CCode (cname = "file_change_callback", cheader_filename = "file-monitor.h")]
    private delegate void FileChangeCallback(string path, int event_type);

}
