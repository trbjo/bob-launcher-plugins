namespace Levensteihn {
    [Compact]
    [CCode (cname = "needle_info", free_function = "free_string_info", cheader_filename = "match.h", has_type_id = false)]
    public class StringInfo {
        public int len;
        [CCode (cname = "prepare_needle")]
        public static StringInfo? create(string needle);
    }

    [CCode (cname = "match_score", cheader_filename = "match.h")]
    public extern static double match_score(StringInfo needle, string? haystack);

    [CCode (cname = "match_score_with_offset", cheader_filename = "match.h")]
    public extern static double match_score_with_offset(StringInfo needle, string? haystack, uint offset);

    [CCode (cname = "query_has_match", cheader_filename = "match.h")]
    public extern static bool query_has_match(StringInfo needle, string? haystack);

    [CCode (cname = "match_positions", cheader_filename = "match.h")]
    public static double match_positions(StringInfo needle, string? haystack, [CCode (array_length = false)] int[] positions);

    [CCode (cname = "MATCH_MAX_LEN", cheader_filename = "match.h")]
    private const int MATCH_MAX_LEN;

    private static int[] match_positions_with_markup(StringInfo needle, string? haystack) {
        int n = needle.len;
        var positions = new int[int.min(n + 1, MATCH_MAX_LEN)];

        for (int i = 0; i < positions.length; i++) {
            positions[i] = -1;
        }

        match_positions(needle, haystack, positions);
        return positions;
    }
}
