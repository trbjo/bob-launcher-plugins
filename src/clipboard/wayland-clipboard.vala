namespace BobLauncher {
    public class WaylandClipboard {
        public class ClipboardItem {
            public GLib.HashTable<Bytes, GLib.GenericArray<string>> content;
            public uint hash;

            public ClipboardItem(GLib.HashTable<Bytes, GLib.GenericArray<string>> content, uint combined_hash) {
                this.hash = combined_hash;
                this.content = content;
            }
        }

        // helper class to make mime types available to the offer
        private class MimeWrapper {
            private static MimeWrapper instance;
            private Zwlr.DataControlOfferV1Listener listener;
            private unowned Zwlr.DataControlOfferV1 proxy;
            private GLib.GenericArray<string> mime_types;

            public MimeWrapper(Zwlr.DataControlOfferV1 proxy) {
                instance = this;
                this.proxy = proxy;
                mime_types = new GenericArray<string>();

                this.listener = Zwlr.DataControlOfferV1Listener() {
                    offer = (data, offer, mime_type) => {
                        // don't register these
                        if (mime_type == "SAVE_TARGETS") {
                            return;
                        }
                        instance.mime_types.add(mime_type);
                        instance.proxy.set_user_data(instance.mime_types);
                    }
                };
                proxy.add_listener(ref this.listener, null);
            }
        }

        // helper class to make the data available to send
        private class OfferWrapper {
            private static OfferWrapper instance;
            private Zwlr.DataControlSourceV1Listener listener;
            public unowned Zwlr.DataControlSourceV1 proxy;
            public signal void cb_cancelled();

            ~OfferWrapper() {
                debug("OfferWrapper DESTROYED");
            }

            private GLib.HashTable<string, Bytes> mime_to_content;

            public OfferWrapper(Zwlr.DataControlSourceV1 proxy) {
                instance = this;
                this.mime_to_content = new GLib.HashTable<string, Bytes>(str_hash, str_equal);
                this.proxy = proxy;
                this.listener = Zwlr.DataControlSourceV1Listener() {
                    send = (user_data, source, mime_type, fd) => {
                        var content = instance.mime_to_content[mime_type];
                        if (content == null) {
                            warning("No content found for MIME type: %s", mime_type);
                            return;
                        }
                        var output = new UnixOutputStream(fd, true);
                        try {
                            size_t bytes_written;
                            output.write_all(content.get_data(), out bytes_written);
                        } catch (Error e) {
                            warning("Failed to write clipboard data for %s: %s", mime_type, e.message);
                        } finally {
                            try {
                                output.close();
                            } catch (Error e) {
                                warning("Failed to close output stream: %s", e.message);
                            }
                        }
                    },

                    cancelled = (user_data, source) => {
                        instance.cb_cancelled();
                    }
                };
                proxy.add_listener(ref this.listener, null);
            }

            public void add_content(Bytes content, GLib.GenericArray<string> mime_types) {
                foreach (var mime_type in mime_types) {
                    mime_to_content[mime_type] = content;
                    proxy.offer(mime_type);
                }
            }
        }

        public signal void clipboard_changed(ClipboardItem item);
        private static GLib.HashTable<uint32, string> names;

        private Wl.Display wl_display;
        private Wl.Registry registry;
        private Wl.Seat seat;

        private int running = 0;
        private uint64 thread_id;

        private bool prevent_inifinite_loop = false;
        private uint last_hash; // avoid storing duplicates

        private Zwlr.DataControlManagerV1? data_control_manager = null;
        private Zwlr.DataControlDeviceV1? data_control_device = null;
        private Zwlr.DataControlDeviceV1Listener listener;

        static construct {
            names = new GLib.HashTable<uint32, string>(direct_hash, direct_equal);
        }

        public WaylandClipboard() {
            Threading.atomic_store(ref running, 1);
            wl_display = new Wl.Display.connect(null);

            if (wl_display == null) {
                error("Failed to connect to Wayland display");
            }

            registry = wl_display.get_registry();
            if (registry == null) {
                error("Failed to get Wayland registry");
            }

            registry.add_listener(Wl.RegistryListener() {
                global = on_global,
                global_remove = on_global_remove,
            }, this);

            if (wl_display.roundtrip() == -1) {
                critical("Failed to complete initial roundtrip, error code: %d", wl_display.get_error());
            }

            if (this.data_control_manager == null) {
                error("Failed to get data_control_manager");
            }

            if (this.seat == null) {
                error("Failed to get seat");
            }

            data_control_device = data_control_manager.get_data_device(seat);
            if (data_control_device == null) {
                error("Failed to get data control device");
            }

            listener = Zwlr.DataControlDeviceV1Listener() {
                data_offer = (data, device, offer) => { if (offer != null) new MimeWrapper(offer); },
                selection = (data, device, offer) => { if (offer != null) event_handler_wrapper(data, offer); },
                finished = (data, device) => { message("data control device is finished"); },
                primary_selection = (data, device, offer) => { if (offer != null) offer.destroy(); }
            };

            data_control_device.add_listener(ref listener, this);

            if (wl_display.roundtrip() == -1) {
                critical("Failed to complete final roundtrip, error code: %d", wl_display.get_error());
            }

            thread_id = Threading.spawn_joinable(run_event_loop);
            wl_display.roundtrip();
        }

        public void destroy() {
            Threading.atomic_dec(ref running);
            wl_display.roundtrip();
            Threading.join(thread_id);

            if (data_control_device != null) {
                data_control_device.destroy();
            }
            if (data_control_manager != null) {
                data_control_manager.destroy();
            }
        }

        public void set_clipboard(GLib.HashTable<Bytes, GLib.GenericArray<string>> content) {
            message("8");
            var current_selection = data_control_manager.create_data_source();

            prevent_inifinite_loop = true;

            var wrapper = new OfferWrapper(current_selection);
            wrapper.cb_cancelled.connect(() => {
                // store a reference, this will be garbage collected automatically by vala.
                current_selection.get_id();
            });

            content.foreach((key, value) => wrapper.add_content(key, value));

            data_control_device.set_selection(current_selection);
            wl_display.flush();
            message("9");
        }

        private static void event_handler_wrapper(void *data, Zwlr.DataControlOfferV1 offer) {
            ((WaylandClipboard)data).event_handler(offer);
        }

        private void event_handler(Zwlr.DataControlOfferV1 offer) {
            if (prevent_inifinite_loop) {
                prevent_inifinite_loop = false;
                offer.destroy();
                return;
            }

            var mime_types = (GenericArray<string>) offer.get_user_data();
            if (mime_types == null) {
                warning("mime_types was NULL or empty");
                offer.destroy();
                return;
            }

            var content_map = new GLib.HashTable<Bytes, GenericArray<string>>(
                (bytes) => bytes.hash(),
                (a, b) => a.compare(b) == 0
            );

            bool has_new_content = false;
            uint combined_hash = 17;

            foreach (string mime_type in mime_types) {
                GLib.Bytes? content = read_clipboard_content(offer, mime_type);
                if (content != null && content.get_size() > 0) {
                    if (!content_map.contains(content)) {
                        content_map[content] = new GenericArray<string>();
                    }
                    content_map[content].add(mime_type);

                    combined_hash = 31 * combined_hash + content.hash();
                    combined_hash = 31 * combined_hash + mime_type.hash();

                    has_new_content = true;
                }
            }

            if (has_new_content && combined_hash != last_hash) {
                last_hash = combined_hash;
                clipboard_changed(new ClipboardItem(content_map, combined_hash));
            }

            offer.destroy();
        }

        private GLib.Bytes? read_clipboard_content(Zwlr.DataControlOfferV1 offer, string mime_type) {
            int pipe_fd[2];
            if (Posix.pipe(pipe_fd) == 0) {
                offer.receive(mime_type, pipe_fd[1]);
                wl_display.flush();

                Posix.close(pipe_fd[1]);
                Posix.fcntl(pipe_fd[0], Posix.F_SETFL, Posix.O_NONBLOCK);

                var input_stream = new UnixInputStream(pipe_fd[0], true);
                var memory_stream = new MemoryOutputStream.resizable();

                uint8[] buffer = new uint8[4096];
                ssize_t bytes_read;
                bool end_of_stream = false;

                while (!end_of_stream) {
                    try {
                        bytes_read = input_stream.read(buffer);
                        if (bytes_read > 0) {
                            memory_stream.write(buffer[0:bytes_read]);
                        } else if (bytes_read == 0) {
                            end_of_stream = true;
                        }
                    } catch (IOError e) {
                        if (e is IOError.WOULD_BLOCK) {
                            continue;
                        } else {
                            critical("Error reading from pipe: %s", e.message);
                            end_of_stream = true;
                        }
                    }
                }

                try {
                    memory_stream.close(); // Close the stream before stealing bytes
                } catch (IOError e) {
                    critical("Error closing memory stream: %s", e.message);
                }

                var bytes = memory_stream.steal_as_bytes();
                debug("Read %llu bytes of %s content", bytes.get_size(), mime_type);
                return bytes;
            } else {
                critical("Failed to create pipe for receiving data");
                return null;
            }
        }

        private static void on_global_remove(void *data, Wl.Registry wl_registry, uint32 name) {
            unowned WaylandClipboard instance = ((WaylandClipboard)data);
            if (names.get(name) == "zwlr_data_control_manager_v1") {
                instance.data_control_manager = null;
            }
        }

        private static void on_global(void* data, Wl.Registry wl_registry, uint32 name, string interface, uint32 version) {
            unowned WaylandClipboard instance = ((WaylandClipboard)data);
            names.set(name, interface);
            if (interface == "zwlr_data_control_manager_v1" && instance.data_control_manager == null) {
                instance.data_control_manager = wl_registry.bind<Zwlr.DataControlManagerV1>(name, ref Zwlr.DataControlManagerV1.iface, version);
            } else if (interface == "wl_seat" && instance.seat == null) {
                instance.seat = wl_registry.bind<Wl.Seat>(name, ref Wl.Seat.iface, version);
            }
        }

        private void run_event_loop() {
            while (Threading.atomic_load(ref running) != 0 && wl_display.dispatch() != -1);
        }
    }
}
