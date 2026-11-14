# Builds cloud-desktop-host for one distro with wlroots linked statically. The binary links against that
# distro's sonames, so there is one build per release (Fedora NN, Ubuntu 26.04…).
#
#   docker build -o dist .                                    # Fedora 43
#   docker build --build-arg FEDORA=44 -o dist .
#   docker build --build-arg BASE=ubuntu:26.04 -o dist .
#
# Result: dist/cloud-desktop-host (single binary, only needs runtime libs:
#   wayland, libinput, libdrm, mesa-libgbm, mesa-libEGL/GLES, libxkbcommon,
#   pixman, systemd-libs — all already pulled in by kwin/plasma-desktop).
ARG FEDORA=43
ARG BASE=fedora:${FEDORA}

FROM ${BASE} AS build
RUN . /etc/os-release && if [ "$ID" = fedora ]; then \
      dnf install -y --setopt=install_weak_deps=False \
        meson ninja-build gcc gcc-c++ pkgconf-pkg-config \
        wayland-devel wayland-protocols-devel mesa-libGLES-devel mesa-libEGL-devel \
        libinput-devel systemd-devel libdrm-devel mesa-libgbm-devel \
        libxkbcommon-devel pixman-devel \
      && dnf clean all; \
    else \
      apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential meson ninja-build pkg-config \
        libwayland-dev wayland-protocols libgles2-mesa-dev libegl1-mesa-dev \
        libinput-dev libudev-dev libsystemd-dev libdrm-dev libgbm-dev \
        libxkbcommon-dev libpixman-1-dev \
      && rm -rf /var/lib/apt/lists/*; \
    fi

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
