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
    'libical': dependency('libical', version: '>= 3.0.20')
}

database_dep = subproject('database').get_variable('database_dep')
file_monitor_lib = subproject('file-monitor')
file_monitor_dep = file_monitor_lib.get_variable('file_monitor_dep')
file_monitor_vapi = file_monitor_dep.get_variable('vapi_dir')

curl_lib = subproject('vurla')
curl_dep = curl_lib.get_variable('curl_dep')
curl_vapi = curl_lib.get_variable('curl_dep').get_variable('vapi_dir')

plugins = {
    'api-bay': files('src/api-bay.vala'),
    'calculator': files('src/calculator-plugin.vala'),
    'calendar': files(
        'src/calendar/calendar-create-match.vala',
        'src/calendar/calendar-delete-match.vala',
        'src/calendar/date-parser.vala',
        'src/calendar/calendar-icon-widget.vala',
        'src/calendar/calendar-match-action-target.vala',
        'src/calendar/calendar-match-main.vala',
        'src/calendar/calendar-match-edit-title.vala',
        'src/calendar/calendar-match-edit-description.vala',
        'src/calendar/calendar-event-tooltip.vala',
        'src/calendar/calendar-match-helper.vala',
        'src/calendar/calendar-search.vala',
        'src/calendar/calendar-service.vapi',
        'src/calendar/calendar_service.c',
        'src/calendar/calendar_service.h'
    ),
    'chromium': files('src/chromium-plugin.vala'),
    'clipboard-manager': files(
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
    'common-actions': files('src/common-actions.vala'),
    'desktop-file': files('src/desktop-file-service.vala', 'src/desktop-file-plugin.vala'),
    'downloads': files('src/downloads-plugin.vala'),
    'file-op': files('src/file-op-plugin.vala'),
    'file-search': files(
        'src/file-search/file-hashtable.h',
        'src/file-search/file-hashtable.c',
        'src/file-search/file-tree-manager.h',
        'src/file-search/file-tree-manager.c',
        'src/file-search/file-search-plugin.vala',
    ),
    'firefox-bookmarks': files('src/firefox-history/firefox-bookmarks-plugin.vala', 'src/firefox-history/firefox-match.vala'),
    'gnome-bookmarks': files('src/gnome-bookmarks-plugin.vala'),
    'imgur': files('src/imgur-plugin.vala'),
    'mpris': files('src/mpris-plugin.vala'),
    'pass': files('src/pass-plugin.vala'),
    'pastebin': files('src/pastebin-plugin.vala'),
    'recently-used': files('src/recently-used.vala'),
    'unknown-match': files('src/unknown-match.vala'),
    'ssh': files('src/ssh-plugin.vala'),
    'systemd-service': files('src/systemd-service-plugin.vala'),
    'snippets': files('src/snippets-plugin.vala', 'src/snippets-database.vala'),
    'process-monitor': files('src/process-monitor/process-monitor.vala', 'src/process-monitor/posix-utils.vala','src/process-monitor/process-match.vala'),
    'tracker': files('src/tracker.vala'),
    'transmission': files('src/transmission-plugin.vala'),
    'url-shortener': files('src/url-shortener-plugin.vala'),
    'wifi': files('src/wifi-plugin.vala')
}

plugin_specific_deps = {
    'tracker': ['tinysparql'],
    'downloads': [file_monitor_dep],
    'recently-used': [file_monitor_dep],
    'file-search': [file_monitor_dep],
    'desktop-file': [file_monitor_dep],
    'clipboard-manager': [database_dep, 'json', 'posix', 'wayland'],
    'command': [database_dep],
    'snippets': [database_dep],
    'chromium': ['json'],
    'firefox-bookmarks': [database_dep],
    'pass': ['libnotify'],
    'pastebin': ['libsoup', 'libnotify'],
    'imgur': ['libsoup', 'json', 'libnotify'],
    'transmission': ['libsoup', 'json'],
    'url-shortener': ['libsoup', 'libnotify'],
    'api-bay': [curl_dep, 'posix', 'json'],
    'process-monitor': ['posix'],
}

plugin_install_dir = join_paths(get_option('libdir'), project_name)

inc_dirs = []

plugin_vala_args = [
    '--vapidir=' + join_paths(meson.current_source_dir(), 'vapi'),
    '--pkg=levensteihn',
    '--pkg=constants',
    '--pkg=data-sink-actions',
    '--pkg=bob-launcher',
    '--pkg=icon-cache-service',
    '--pkg=result-container',
]

if 'file-search' in plugins
    inc_dirs += include_directories('src/file-search')
    plugin_vala_args += '--vapidir=' + join_paths(meson.current_source_dir(), 'src/file-search/vapi')
    plugin_vala_args += '--pkg=file-hashtable'
    plugin_vala_args += '--vapidir=' + file_monitor_vapi
    plugin_vala_args += '--pkg=file-monitor'
    plugin_vala_args += '--pkg=file-tree-manager'
endif

if 'calendar' in plugins
    inc_dirs += include_directories('src/calendar')
    plugin_vala_args += '--vapidir=' + join_paths(meson.current_source_dir(), 'src/calendar')
    plugin_vala_args += '--pkg=calendar-service'
endif

if 'clipboard-manager' in plugins
    inc_dirs += include_directories('src/clipboard')
    plugin_vala_args += '--vapidir=' + join_paths(meson.current_source_dir(), 'src/clipboard/vapi')
    plugin_vala_args += '--pkg=wayland-clipboard'
    plugin_vala_args += '--pkg=clipboard-hashtable'
    plugin_vala_args += '--pkg=wayland-protocol-check'
endif

if 'api-bay' in plugins
    plugin_vala_args += '--vapidir=' + curl_vapi
    plugin_vala_args += '--pkg=libcurl'
    plugin_vala_args += '--pkg=posix'
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

c_sources = files(
    'vapi/gthread_stub.c'
)

compile_schemas = custom_target('glib-compile-schemas-plugins',
    build_by_default: true,
    output: 'gschemas.compiled',
    command: [
        find_program('glib-compile-schemas'),
        '--strict',
        schema_dir
    ]
)

foreach plugin_name, sources : plugins
    plugin_deps = []
    plugin_sources = sources

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
        plugin_sources + c_sources,
        name_prefix: 'lib-',
        name_suffix: 'so',
        dependencies: plugin_deps,
        install: true,
        install_dir: plugin_install_dir,
        include_directories: inc_dirs,
        c_args: common_c_args + [
            '-I/usr/include/xxhash',
            '-D_GNU_SOURCE',
            '-include', join_paths(meson.current_source_dir(), 'vapi/no-thread-init.h'),
            '-include', join_paths(meson.current_source_dir(), 'vapi/xxhash-override.h'),
            '-I' + join_paths(meson.current_source_dir(), 'vapi'),
        ],
        link_args: common_link_args
            + (plugin_name == 'calendar' ? ['-lical', '-lpthread'] : []),
        vala_args: common_vala_args + plugin_vala_args
    )
endforeach

gnome.post_install(glib_compile_schemas: true)
