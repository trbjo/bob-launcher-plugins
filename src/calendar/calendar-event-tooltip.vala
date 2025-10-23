namespace BobLauncher {
    namespace Calendar {
        internal class CalendarEventTooltip : Gtk.Widget {

            private Gtk.Label label;

            internal CalendarEventTooltip(string? text) {
                Object();
                label = new Gtk.Label(text);
                label.set_parent(this);
            }

            public override void measure(Gtk.Orientation orientation, int for_size,
                                       out int minimum, out int natural,
                                       out int minimum_baseline, out int natural_baseline) {
                label.measure(orientation, for_size, out minimum, out natural,
                                   out minimum_baseline, out natural_baseline);
            }

            protected override void size_allocate(int width, int height, int baseline) {
                label.allocate(width, height, baseline, null);
            }

            protected override void snapshot(Gtk.Snapshot snapshot) {
                snapshot_child(label, snapshot);
            }
        }
    }
}
