[CCode (cheader_filename = "wayland_protocol_check.h")]
namespace WaylandProtocol {
    [CCode (cname = "wayland_has_protocol", has_type_id = false)]
    public static bool has_protocol (string protocol_name);
}
