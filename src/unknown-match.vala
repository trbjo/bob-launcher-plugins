[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.QueryVerbatimPlugin);
}

namespace BobLauncher {
    public class QueryVerbatimPlugin : SearchBase {
        construct {
            icon_name = "text";
        }

        public override void search(ResultContainer rs) {
            string q = rs.get_query();
            rs.add_lazy(q.hash(), MatchScore.ABOVE_THRESHOLD, () => new UnknownMatch(q));
        }
    }
}
