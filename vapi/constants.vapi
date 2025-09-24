[CCode (cheader_filename = "constants.h")]
namespace MatchScore {
    public struct Score : int16 { }

    // Application constants
    [CCode (cname = "BOB_LAUNCHER_APP_ID")]
    public const string BOB_LAUNCHER_APP_ID;

    [CCode (cname = "BOB_LAUNCHER_OBJECT_PATH")]
    public const string BOB_LAUNCHER_OBJECT_PATH;

    // Score modification constants
    [CCode (cname = "LOWEST")]
    public const Score LOWEST;

    [CCode (cname = "NONE")]
    public const Score NONE;

    [CCode (cname = "TIEBREAKER")]
    public const Score TIEBREAKER;

    [CCode (cname = "DECREMENT_MINOR")]
    public const Score DECREMENT_MINOR;

    [CCode (cname = "DECREMENT_MEDIUM")]
    public const Score DECREMENT_MEDIUM;

    [CCode (cname = "DECREMENT_MAJOR")]
    public const Score DECREMENT_MAJOR;

    [CCode (cname = "INCREMENT_MINOR")]
    public const Score INCREMENT_MINOR;

    [CCode (cname = "INCREMENT_SMALL")]
    public const Score INCREMENT_SMALL;

    [CCode (cname = "INCREMENT_MEDIUM")]
    public const Score INCREMENT_MEDIUM;

    [CCode (cname = "INCREMENT_LARGE")]
    public const Score INCREMENT_LARGE;

    [CCode (cname = "INCREMENT_HUGE")]
    public const Score INCREMENT_HUGE;

    [CCode (cname = "BELOW_THRESHOLD")]
    public const Score BELOW_THRESHOLD;

    [CCode (cname = "MATCH_SCORE_THRESHOLD")]
    public const Score THRESHOLD;

    [CCode (cname = "ABOVE_THRESHOLD")]
    public const Score ABOVE_THRESHOLD;

    [CCode (cname = "BELOW_AVERAGE")]
    public const Score BELOW_AVERAGE;

    [CCode (cname = "AVERAGE")]
    public const Score AVERAGE;

    [CCode (cname = "ABOVE_AVERAGE")]
    public const Score ABOVE_AVERAGE;

    [CCode (cname = "GOOD")]
    public const Score GOOD;

    [CCode (cname = "VERY_GOOD")]
    public const Score VERY_GOOD;

    [CCode (cname = "EXCELLENT")]
    public const Score EXCELLENT;

    [CCode (cname = "PRETTY_HIGH")]
    public const Score PRETTY_HIGH;

    [CCode (cname = "HIGHEST")]
    public const Score HIGHEST;
}
