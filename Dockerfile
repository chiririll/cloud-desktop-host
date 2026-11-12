# Builds cloud-desktop-host for Fedora 43 with wlroots linked statically.
#
#   docker build -o dist .
#
# Result: dist/cloud-desktop-host (single binary, only needs runtime libs:
#   wayland, libinput, libdrm, mesa-libgbm, mesa-libEGL/GLES, libxkbcommon,
#   pixman, systemd-libs — all already pulled in by kwin/plasma-desktop).
ARG FEDORA=43

FROM fedora:${FEDORA} AS build
RUN dnf install -y --setopt=install_weak_deps=False \
      meson ninja-build gcc gcc-c++ pkgconf-pkg-config \
      wayland-devel wayland-protocols-devel mesa-libGLES-devel mesa-libEGL-devel \
      libinput-devel systemd-devel libdrm-devel mesa-libgbm-devel \
      libxkbcommon-devel pixman-devel \
 && dnf clean all

WORKDIR /src
COPY . .
# Headless-only wlroots (CDH talks to libinput itself): no DRM/libinput/X11 backends, no Xwayland, no seat/session.
RUN meson setup build --buildtype=release --prefix=/usr \
      -Dwlroots:default_library=static \
      -Dwlroots:examples=false \
      -Dwlroots:backends=[] \
      -Dwlroots:renderers=gles2 \
      -Dwlroots:allocators=gbm \
      -Dwlroots:session=disabled \
      -Dwlroots:xwayland=disabled \
      -Dwlroots:xcb-errors=disabled \
      -Dwlroots:color-management=disabled \
      -Dwlroots:libliftoff=disabled \
 && ninja -C build \
 && strip build/cloud-desktop-host \
 && ! ldd build/cloud-desktop-host | grep -q wlroots

FROM scratch
COPY --from=build /src/build/cloud-desktop-host /cloud-desktop-host
