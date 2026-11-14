# Prebuilt binary: Docker build and GitHub releases

This fork ships `cloud-desktop-host` as a prebuilt binary, so the LXC container needs no compilers or `-devel` packages. You can build it two ways:

| Where | How | Result |
|---|---|---|
| Any machine with Docker | `docker build -o dist .` | `dist/cloud-desktop-host` |
| GitHub Actions | push a tag `v*` | GitHub release with the binary and an install bundle |

The [Proxmox installer](PVE_INSTALLER.md) uses the latest release by default.

To build CDH from source inside the container, see [BUILD.md](BUILD.md). That still works.

---

## 1. Local build with Docker

```bash
git clone https://github.com/chiririll/cloud-desktop-host.git
cd cloud-desktop-host
git submodule update --init --depth 1 subprojects/wlroots   # the only submodule the build uses
docker build -o dist .
```

The result is `dist/cloud-desktop-host`, a stripped binary of about 0.5 MB.

To build for another Fedora release:

```bash
docker build --build-arg FEDORA=44 -o dist .
```

The binary links against the Fedora release it was built on, so build it for the release the container runs. When you upgrade the container's Fedora, rebuild.

### What the Dockerfile does

1. Starts from `fedora:${FEDORA}` and installs only the build dependencies (meson, gcc, wayland/libinput/mesa/xkbcommon/pixman/systemd `-devel`).
2. Builds wlroots 0.20.2 from `subprojects/wlroots` as a **static** library, so there is no `libwlroots-0.20.so` to install.
3. Builds wlroots with **only the headless parts**:

   | wlroots option | Value | Why |
   |---|---|---|
   | `default_library` | `static` | one self-contained binary |
   | `backends` | `[]` | CDH uses the headless backend (always built) and talks to libinput itself |
   | `renderers` | `gles2` | the renderer CDH uses; no Vulkan dependency |
   | `allocators` | `gbm` | GBM on the render node |
   | `session` | `disabled` | no seat, logind or TTY in an unprivileged container |
   | `xwayland` | `disabled` | KWin and Gamescope start their own Xwayland |
   | `xcb-errors`, `color-management`, `libliftoff` | `disabled` | not needed headless |

   This matches what an in-container build ended up with anyway: without `libseat` or `libdisplay-info`, meson already disabled DRM, session and X11.
4. Strips the binary and checks that it does not link to a shared wlroots.
5. Exports only the binary (the last stage is `FROM scratch`), so `-o dist` writes a single file.

`.dockerignore` keeps `build/`, `dist/`, `.git` out of the build context.

### Runtime dependencies

These come in with `kwin` / `plasma-desktop`, so a container with the desktop installed already has them:

```
libwayland-server libwayland-client libinput libdrm mesa-libgbm
mesa-libEGL mesa-libGLES libxkbcommon pixman systemd-libs
```

Quick check on a clean Fedora:

```bash
docker create --name cdhtest fedora:43 sh -c '
  dnf install -yq libwayland-server libwayland-client libinput mesa-libgbm \
      mesa-libEGL mesa-libGLES libxkbcommon pixman libdrm >/dev/null
  ldd /cloud-desktop-host | grep "not found" || echo ALL_LIBS_OK'
docker cp dist/cloud-desktop-host cdhtest:/cloud-desktop-host
docker start -a cdhtest; docker rm cdhtest
```

### Installing the binary by hand

```bash
pct push 180 dist/cloud-desktop-host /usr/local/bin/cloud-desktop-host --perms 0755
```

`scripts/run.sh` and `scripts/sunshine-prep-gamescope.sh` look for the binary in this order:

1. `$CDH_BIN`
2. `cloud-desktop-host` on `PATH` (e.g. `/usr/local/bin`)
3. `scripts/../build/cloud-desktop-host` (in-repo build)

---

## 2. Releases with GitHub Actions

Workflow: [`.github/workflows/release.yml`](../.github/workflows/release.yml).

### Making a release

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow:

1. Checks out the repo and fetches only `subprojects/wlroots`.
2. Runs the same `docker build` as above once per Fedora release in the workflow matrix (43, 44, 45).
3. Once every Fedora build succeeded, a final `release` job writes one `MANIFEST` and one `SHA256SUMS` and creates the release for that tag with generated notes (so a failed build never leaves a partial release):

   | Asset | Contents |
   |---|---|
   | `cdh-fc<N>-x86_64.tar.gz` | `cdh/cloud-desktop-host`, `cdh/scripts/`, `cdh/configs/`, `cdh/pve/install.sh`, `cdh/pve/host-persist.sh` |
   | `cloud-desktop-host-fc<N>-x86_64` | the bare binary |
   | `MANIFEST` | checksums of every `cloud-desktop-host-fc<N>-x86_64` binary plus `scripts/` and `configs/` (used by `--check`) |
   | `SHA256SUMS` | checksums of all bundles, bare binaries and `MANIFEST` |

Asset names have no version, so the newest release is always at:

```
https://github.com/chiririll/cloud-desktop-host/releases/latest/download/cdh-fc43-x86_64.tar.gz
```

Releases are created once: to redo one, delete the release (and tag) first, then push the tag again.

A manual run (**Actions → release → Run workflow**) builds the same files and keeps them as workflow artifacts. It does not publish a release, which makes it handy for testing a branch.

### Downloading by hand

```bash
base=https://github.com/chiririll/cloud-desktop-host/releases/latest/download
curl -fLO $base/cdh-fc43-x86_64.tar.gz -fLO $base/SHA256SUMS
sha256sum -c --ignore-missing SHA256SUMS
tar -xzf cdh-fc43-x86_64.tar.gz      # → cdh/
```

### Supporting another Fedora release

Add the number to `strategy.matrix.fedora` in the workflow and to `SUPPORTED_FEDORA` in `pve/install-parts/10-config.sh` (then run `pve/build.sh`). Sunshine publishes RPMs for each release too, so check that its `fc<N>` asset exists first. For a local build: `docker build --build-arg FEDORA=44 -o dist .`
