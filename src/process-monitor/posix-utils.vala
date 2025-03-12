namespace ProcessUtils {
    public enum ProcessState {
        RUNNING,
        SLEEPING,
        DISK_SLEEP,
        STOPPED,
        TRACING_STOP,
        ZOMBIE,
        DEAD,
        WAKEKILL,
        WAKING,
        PARKED,
        IDLE,
        UNKNOWN;

        public string to_string() {
            switch (this) {
                case RUNNING:     return "R";
                case SLEEPING:    return "S";
                case DISK_SLEEP:  return "D";
                case STOPPED:     return "T";
                case TRACING_STOP:return "t";
                case ZOMBIE:      return "Z";
                case DEAD:        return "X";
                case WAKEKILL:    return "K";
                case WAKING:      return "W";
                case PARKED:      return "P";
                case IDLE:        return "I";
                default:          return "?";
            }
        }

        public static ProcessState from_string(string state) {
            switch (state) {
                case "R": return RUNNING;
                case "S": return SLEEPING;
                case "D": return DISK_SLEEP;
                case "T": return STOPPED;
                case "t": return TRACING_STOP;
                case "Z": return ZOMBIE;
                case "X": return DEAD;
                case "K": return WAKEKILL;
                case "W": return WAKING;
                case "P": return PARKED;
                case "I": return IDLE;
                default:  return UNKNOWN;
            }
        }
    }

    // GNU only, let's not use this
    // relies on '-D_GNU_SOURCE', '-include', 'unistd.h'
    // [CCode (cname = "group_member", cheader_filename = "unistd.h")]
    // extern int group_member(Posix.gid_t gid);

    [CCode (cname = "getgroups", cheader_filename = "sys/types.h,unistd.h,grp.h")]
    extern int getgroups(int size, [CCode(array_length = false)] Posix.gid_t[] list);

    [CCode (cname = "getegid", cheader_filename = "sys/types.h,unistd.h")]
    extern Posix.gid_t getegid();

    [CCode (cname = "getgrgid", cheader_filename = "grp.h")]
    extern unowned Posix.Group? getgrgid(Posix.gid_t gid);


    // workaround for GNU-only `group_member` function
    public static bool is_group_member(Posix.gid_t group_to_check) {
        // First, check if it's the effective GID
        if (getegid() == group_to_check) {
            return true;
        }

        // Then check supplementary groups
        int ngroups = 16;
        Posix.gid_t[] groups = new Posix.gid_t[ngroups];

        while (true) {
            int result = getgroups(ngroups, groups);
            if (result < 0 && Posix.errno == Posix.EINVAL) {
                ngroups *= 2;
                groups = new Posix.gid_t[ngroups];
            } else if (result >= 0) {
                for (int i = 0; i < result; i++) {
                    if (groups[i] == group_to_check) {
                        return true;
                    }
                }
                break;
            } else {
                // An error occurred
                return false;
            }
        }

        // Finally, check the user's group list in /etc/group
        unowned Posix.Group? group_info = getgrgid(getegid());
        if (group_info != null) {
            for (int i = 0; group_info.gr_mem[i] != null; i++) {
                unowned Posix.Group? member_group = getgrgid(group_to_check);
                if (member_group != null && member_group.gr_name == group_info.gr_mem[i]) {
                    return true;
                }
            }
        }
        return false;
    }
}

