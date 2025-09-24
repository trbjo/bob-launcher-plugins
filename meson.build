project('io.github.trbjo.bob.launcher.plugins', 'vala', 'c',
    version: '0.5.0',
    default_options: [
        'buildtype=release',
        'optimization=3',
        'b_lto=true',
        'prefix=/usr/local'
    ]
)
project_name = 'io.github.trbjo.bob.launcher'

# Check if we're being built as a subproject
is_subproject = meson.is_subproject()

common_deps = {
    'gtk4': dependency('gtk4-wayland', version: '>= 4.0.0'),
    'glib': dependency('glib-2.0'),
    'gio': dependency('gio-2.0'),
    'gio-unix': dependency('gio-unix-2.0'),
}

common_c_args = ['-w']
common_link_args = ['-Wl,--as-needed', '-Wl,-z,now', '-lm', '-lxxhash']
common_vala_args = []

extra_deps = {
    'tinysparql': dependency('tinysparql-3.0'),
    'libnotify': dependency('libnotify'),
    'posix': meson.get_compiler('vala').find_library('posix'),
    'wayland': dependency('wayland-client'),
    'libsoup': dependency('libsoup-3.0'),
    'json': dependency('json-glib-1.0', version: '>= 1.8.0'),
}

database_dep = subproject('database').get_variable('database_dep')
file_monitor_lib = subproject('file-monitor')
file_monitor_dep = file_monitor_lib.get_variable('file_monitor_dep')
file_monitor_vapi = file_monitor_lib.get_variable('file_monitor_dep').get_variable('vapi_dir')

curl_lib = subproject('vurla')
curl_dep = curl_lib.get_variable('curl_dep')
curl_vapi = curl_lib.get_variable('curl_dep').get_variable('vapi_dir')

# Plugin sources mapping
plugins = {
    'api_bay': files('src/api-bay.vala'),
    'calculator': files('src/calculator-plugin.vala'),
    'chromium': files('src/chromium-plugin.vala'),
    'clipboard_manager': files(
        'src/clipboard/clipboard-manager-plugin.vala',
        'src/clipboard/clipboard-matches.vala',
        'src/clipboard/clipboard-database.vala',
        'src/clipboard/wlr-data-control.h',
        'src/clipboard/wlr-data-control.c',
        'src/clipboard/wayland-clipboard.c',
        'src/clipboard/wayland-clipboard.h',
        'src/clipboard/clipboard-hashtable.h',
        'src/clipboard/clipboard-hashtable.c',
        'src/clipboard/wayland_protocol_check.h',
        'src/clipboard/wayland_protocol_check.c'
    ),
    'command': files('src/command-plugin.vala'),
    'common_actions': files('src/common-actions.vala'),
    'desktop_file': files('src/desktop-file-service.vala', 'src/desktop-file-plugin.vala'),
    'downloads': files('src/downloads-plugin.vala'),
    'file_op': files('src/file-op-plugin.vala'),
    'file_search': files(
        'src/file-search/file-hashtable.h',
        'src/file-search/file-hashtable.c',
        'src/file-search/file-tree-manager.h',
        'src/file-search/file-tree-manager.c',
        'src/file-search/file-search-plugin.vala',
    ),
    'firefox_bookmarks': files('src/firefox-history/firefox-bookmarks-plugin.vala', 'src/firefox-history/firefox-match.vala'),
    'gnome_bookmarks': files('src/gnome-bookmarks-plugin.vala'),
    'imgur': files('src/imgur-plugin.vala'),
    'mpris': files('src/mpris-plugin.vala'),
    'pass': files('src/pass-plugin.vala'),
    'pastebin': files('src/pastebin-plugin.vala'),
    'recently_used': files('src/recently-used.vala'),
    'ssh': files('src/ssh-plugin.vala'),
    'systemd_service': files('src/systemd-service-plugin.vala'),
    'process_monitor': files('src/process-monitor/process-monitor.vala', 'src/process-monitor/posix-utils.vala','src/process-monitor/process-match.vala'),
    'tracker': files('src/tracker.vala'),
    'transmission': files('src/transmission-plugin.vala'),
    'url_shortener': files('src/url-shortener-plugin.vala'),
}

# Plugin-specific dependencies
plugin_specific_deps = {
    'tracker': ['tinysparql'],
    'downloads': [file_monitor_dep],
    'recently_used': [file_monitor_dep],
    'file_search': [file_monitor_dep],
    'desktop_file': [file_monitor_dep],
    'clipboard_manager': [database_dep, 'json', 'posix', 'wayland'],
    'command': [database_dep],
    'chromium': ['json'],
    'firefox_bookmarks': [database_dep],
    'pass': ['libnotify'],
    'pastebin': ['libsoup', 'libnotify'],
    'imgur': ['libsoup', 'json', 'libnotify'],
    'transmission': ['libsoup', 'json'],
    'url_shortener': ['libsoup', 'libnotify'],
    'api_bay': [curl_dep, 'posix', 'json'],
    'process_monitor': ['posix'],
}

plugin_install_dir = join_paths(get_option('libdir'), project_name)

# Build include directories based on what plugins are enabled
inc_dirs = [ ]
plugin_vala_args = [
    '--vapidir=' + join_paths(meson.current_source_dir(), 'vapi'),
    '--pkg=levensteihn',
    '--pkg=constants',
    '--pkg=data-sink-actions',
    '--pkg=bob-launcher',
    '--pkg=icon-cache-service',
    '--pkg=result-container',
]

# Process plugin options and build lists
static_plugin_sources = []
static_plugin_deps = []
static_plugin_names = []
dynamic_plugin_names = []

foreach plugin_name, sources : plugins
    option_name = 'plugin_' + plugin_name
    plugin_mode = get_option(option_name)

    if plugin_mode == '0'
        # Disabled
        continue
    elif plugin_mode == '1'
        # Static compilation
        static_plugin_sources += sources
        static_plugin_names += plugin_name

        # Add dependencies for static plugins
        if plugin_name in plugin_specific_deps
            foreach dep : plugin_specific_deps[plugin_name]
                if dep in ['json', 'posix', 'wayland', 'libsoup', 'libnotify', 'tinysparql']
                    static_plugin_deps += extra_deps[dep]
                else
                    static_plugin_deps += dep
                endif
            endforeach
        endif
    elif plugin_mode == '2'
        # Dynamic compilation
        dynamic_plugin_names += plugin_name
    endif
endforeach

# Add include directories and vala args for enabled plugins
if 'downloads' in static_plugin_names or 'downloads' in dynamic_plugin_names
    plugin_vala_args += '--vapidir=' + file_monitor_vapi
    plugin_vala_args += '--pkg=file-monitor'
endif

if 'recently_used' in static_plugin_names or 'recently_used' in dynamic_plugin_names
    plugin_vala_args += '--vapidir=' + file_monitor_vapi
    plugin_vala_args += '--pkg=file-monitor'
endif

if 'file_search' in static_plugin_names or 'file_search' in dynamic_plugin_names
    inc_dirs += include_directories('src/file-search')
    plugin_vala_args += '--vapidir=' + join_paths(meson.current_source_dir(), 'src/file-search/vapi')
    plugin_vala_args += '--pkg=file-hashtable'
    plugin_vala_args += '--vapidir=' + file_monitor_vapi
    plugin_vala_args += '--pkg=file-monitor'
    plugin_vala_args += '--pkg=file-tree-manager'
endif

if 'clipboard_manager' in static_plugin_names or 'clipboard_manager' in dynamic_plugin_names
    inc_dirs += include_directories('src/clipboard')
    plugin_vala_args += '--vapidir=' + join_paths(meson.current_source_dir(), 'src/clipboard/vapi')
    plugin_vala_args += '--pkg=wayland-clipboard'
    plugin_vala_args += '--pkg=clipboard-hashtable'
    plugin_vala_args += '--pkg=wayland-protocol-check'
endif

if 'api_bay' in static_plugin_names or 'api_bay' in dynamic_plugin_names
    plugin_vala_args += '--vapidir=' + curl_vapi
    plugin_vala_args += '--pkg=libcurl'
    plugin_vala_args += '--pkg=posix'
endif

# Export variables for parent project
if is_subproject
    set_variable('static_plugin_sources', static_plugin_sources)
    set_variable('static_plugin_deps', static_plugin_deps)
    set_variable('static_plugin_names', static_plugin_names)
    set_variable('plugin_c_args', common_c_args)
    set_variable('plugin_vala_args', plugin_vala_args)
    set_variable('plugin_inc_dirs', inc_dirs)

    # Generate static plugin registration file
    if static_plugin_names.length() > 0
        static_registration_vala = custom_target('static-plugin-registration',
            output: 'static-plugin-registration.vala',
            capture: true,
            command: ['python3', '-c', '''
import sys
plugins = sys.argv[1].split(",") if sys.argv[1] else []
print("/* Generated file - do not edit */")
print("#if STATIC_PLUGINS")
print("namespace BobLauncher.Plugins {")
print("    public static Type[] get_static_plugin_types() {")
print("        Type[] types = {")
for plugin in plugins:
    class_name = "".join([p.capitalize() for p in plugin.split("_")]) + "Plugin"
    print(f"            typeof({class_name}),")
print("        };")
print("        return types;")
print("    }")
print("}")
print("#endif")
''', ','.join(static_plugin_names)]
        )
        set_variable('static_registration_file', static_registration_vala)
    endif
endif

# Install the plugins GSchema
gnome = import('gnome')
plugins_schema_file = 'io.github.trbjo.bob.launcher.plugins.gschema.xml'

schema_dir = join_paths(meson.current_build_dir(), 'data', 'glib-2.0', 'schemas')
run_command('mkdir', '-p', schema_dir, check: true)

plugins_schema_target = custom_target('plugins-schema',
    input: join_paths('data', plugins_schema_file),
    output: plugins_schema_file,
    command: ['cp', '@INPUT@', schema_dir],
    build_by_default: true
)

install_data(
    join_paths('data', plugins_schema_file),
    install_dir: join_paths(get_option('datadir'), 'glib-2.0', 'schemas')
)

# Compile schemas
compile_schemas = custom_target('glib-compile-schemas',
    build_by_default: true,
    output: 'gschemas.compiled',
    command: [
        find_program('glib-compile-schemas'),
        '--strict',
        schema_dir
    ]
)

# Build dynamic plugins
optimization_flags = [
    '-march=native',
    '-fno-plt',
    '-fno-stack-protector',
    '-funroll-loops',
    '-ffast-math',
    '-ftree-vectorize',
]

foreach plugin_name : dynamic_plugin_names
    plugin_deps = []
    plugin_sources = plugins[plugin_name]

    foreach dep_name, dep : common_deps
        plugin_deps += dep
    endforeach

    if plugin_name in plugin_specific_deps
        foreach dep : plugin_specific_deps[plugin_name]
            if dep in ['json', 'posix', 'wayland', 'libsoup', 'libnotify', 'tinysparql']
                plugin_deps += extra_deps[dep]
            else
                plugin_deps += dep
            endif
        endforeach
    endif

    shared_module(plugin_name,
        plugin_sources,
        name_prefix: 'lib-',
        name_suffix: 'so',
        dependencies: plugin_deps,
        install: true,
        install_dir: plugin_install_dir,
        include_directories: inc_dirs,
        c_args: common_c_args + optimization_flags + [
            '-I/usr/include/xxhash',
            '-D_GNU_SOURCE',
            '-include', join_paths(meson.current_source_dir(), 'vapi/xxhash-override.h'),
            '-I' + join_paths(meson.current_source_dir(), 'vapi'),
        ],
        link_args: common_link_args,
        vala_args: common_vala_args + plugin_vala_args
    )
endforeach

gnome.post_install(glib_compile_schemas: true)
