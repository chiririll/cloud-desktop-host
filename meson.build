project('cloud-desktop-host', ['c', 'cpp'],
  version: '0.1.0',
  default_options: [
    'c_std=c11',
    'cpp_std=c++17',
    'warning_level=2',
  ])

# wlroots 0.20.2 как subproject (компилируется как C)
wlroots_proj = subproject('wlroots', default_options: [
  'examples=false',
])
wlroots_dep = wlroots_proj.get_variable('wlroots')

wayland_server = dependency('wayland-server')
wayland_protos = dependency('wayland-protocols', version: '>=1.35')
glesv2         = dependency('glesv2')
libinput_dep   = dependency('libinput')
libudev_dep    = dependency('libudev')
libsystemd_dep = dependency('libsystemd')
math_dep       = meson.get_compiler('cpp').find_library('m', required: true)

# wlroots protocol headers генерируются в build dir — нужен explicit include
wlr_proto_inc = include_directories('subprojects/wlroots/protocol', is_system: true)

executable('cloud-desktop-host',
  'src/main.cpp',
  'src/protocols.cpp',
  'src/output.cpp',
  'src/idle.cpp',
  'src/xdg.cpp',
  'src/input.cpp',
  'src/dbus_input.cpp',
  'src/debug_ui.cpp',
  dependencies: [
    wlroots_dep,
    wayland_server,
    glesv2,
    libinput_dep,
    libudev_dep,
    libsystemd_dep,
    math_dep,
  ],
  include_directories: [wlr_proto_inc],
  cpp_args: ['-DWLR_USE_UNSTABLE'],
  install: true)
