namespace BobLauncher {
    internal class HistoryMatch : Match, IURLMatch, ITextMatch {
        public FirefoxHistoryPlugin.FirefoxItemType item_type { get; set; }
        public string uri { get; construct; }

        public string get_url() {
            return uri;
        }

        private string title;
        public override string get_title() {
            return title;
        }

        private string description;
        public override string get_description() {
            return description;
        }

        public override string get_icon_name() {
            return item_type == FirefoxHistoryPlugin.FirefoxItemType.BOOKMARK ? "user-bookmarks" : "applications-internet";
        }

        public string get_text() {
            return uri;
        }

        public HistoryMatch(string title, string uri, FirefoxHistoryPlugin.FirefoxItemType type, string? formatted_date) {
            assert(title != null);
            assert(uri != null);
            Object(uri: uri);
            this.description = formatted_date != null ? "%s | %s".printf(formatted_date, uri) : uri;
            this.item_type = type;
            this.title = title;
        }
    }

}
