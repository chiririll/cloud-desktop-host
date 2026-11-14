# Installer redesign: host/container split, Ubuntu support, update mode

Status: **implemented** (see [CT_INSTALLER.md](CT_INSTALLER.md) and [PVE_INSTALLER.md](PVE_INSTALLER.md)); written as a design on 2026-11-14. Deviations: `CDH_INPUT_ISOLATED` also accepts `keep`; the host still creates `CT_USER` early (the input guard needs its uid); `SUNSHINE_RPM`/`CLOUD_MOUSE_RPM` stay as aliases; the stream-active marker is a state file; Not yet run on a real CT: the whole Ubuntu path and the update mode.

This document describes three related changes to the installer in `pve/`:

1. **Split** `pve/install.sh` into a host-only script and a standalone in-container script.
2. **Distro support** inside the container: Fedora (as today) and Ubuntu.
3. **Update mode** (`--update`) that brings everything the installer put in place to the latest version.

Each section lists what exists today, what changes, and what to watch. The last section is the suggested implementation order.

---

## 1. Why

- **Ubuntu containers.** Nothing in CDH itself is Fedora-specific (see [§3](#3-ubuntu-support)), but the installer is: `dnf`/`rpm`, the Fedora CT template, `fcNN` release bundles, the Sunshine `fcNN` RPM, RPM Fusion. Adding Ubuntu to the current single script would double every `chk_*`/`do_*` pair in `53-phase-inside.sh`.
- **Non-Proxmox hosts.** The in-container phase only needs a render node, `/dev/uinput`, input devices and the host udev database. Once it runs on its own, it works in Incus, Docker, a plain VM or a hand-made LXC, not only behind `pct`.
- **Updates.** Today "update" means "re-run the installer and hope the checks catch it". They catch some things (see [§4](#4-update-mode)) but not package upgrades or new Sunshine releases, and nothing restarts the session afterwards.

---

## 2. Host/container split

### 2.1 Today

`pve/install.sh` is one generated file (`pve/build.sh` concatenates `pve/install-parts/*.sh` and inlines `install-parts/files/*` as heredocs). It runs on the Proxmox host and reaches into the container with `pct exec`/`pct push` through the `ct`, `ct_sh`, `ct_user`, `ct_systemctl`, `ct_install_rpm`, `rpm_missing` helpers.

Phases, in order (`60-main.sh`):

| Part | Phase | Runs on | Notes |
|------|-------|---------|-------|
| `50-phase-host.sh` | driver, modeset, uinput, uvm | host | `require` steps (not auto-fixable) and modprobes |
| `51-phase-guard.sh` | `cdh_input_guard` module, per-CT input nodes | host | optional, `INSTALL_INPUT_GUARD` |
| `52-phase-container.sh` | template, `pct create`, lxc.conf, devices, CT user | host | needs `pct` |
| `53-phase-inside.sh` | udev db mount, packages, NVIDIA userspace, CDH, Sunshine, Cloud Mouse, Steam | **container** via `pct exec` | everything here moves |
| `54-phase-services.sh` | user service unit | **container** via `pct exec` | moves |

### 2.2 Target layout

```
pve/
├── build.sh                 # builds BOTH generated scripts from the parts
├── install.sh               # GENERATED: host script (Proxmox)
├── ct-install.sh            # GENERATED: in-container script (any distro, any host)
└── install-parts/
    ├── 00-header.sh         # shared: shebang, colors, set -euo pipefail
    ├── 10-config.sh         # shared settings (CT_USER, CDH_VERSION, …) + host-only ones
    ├── 20-helpers.sh        # shared: step engine, msg_*, render_file, get_file
    ├── 30-release.sh        # shared: release_base, manifest, fetch_release
    ├── 40-resolve.sh        # host: CTID/CT prompts
    ├── 50-phase-host.sh     # host
    ├── 51-phase-guard.sh    # host
    ├── 52-phase-container.sh# host
    ├── 55-phase-run-inside.sh # host: push ct-install.sh into the CT and run it
    ├── 60-main.sh           # host main
    ├── ct/                  # in-container parts
    │   ├── 10-ct-config.sh  # env contract (§2.4), os-release detection
    │   ├── 20-distro.sh     # distro detection + dispatch to distro/<id>.sh (dnf / apt)
    │   ├── distro/          # fedora.sh, ubuntu.sh: one backend per distro
    │   ├── 30-phase-system.sh   # udev db, input rule, packages, NVIDIA userspace, linger
    │   ├── 40-phase-cdh.sh      # binary, scripts/configs, Sunshine, config, Cloud Mouse, Steam
    │   ├── 50-phase-services.sh # user service
    │   ├── 60-phase-update.sh   # update-only steps (§4)
    │   └── 90-ct-main.sh
    └── files/               # unchanged (udev rules, systemd units, cdh-input-node.sh)
```

`build.sh` produces two outputs. Which parts go into which output is decided by a marker in the first line of each part (for example `# @host`, `# @ct`, `# @shared`) or simply by directory: top-level parts without `ct/` go to `install.sh`, `ct/` parts plus the shared ones go to `ct-install.sh`. `build.sh --check` (already run in CI) verifies both.

Both generated files are committed and shipped in the release bundle, because they are run as `bash -c "$(curl …)"` and cannot source neighbours.

### 2.3 What the host script keeps doing

Everything in `50`–`52` as today, then one new phase `55-phase-run-inside.sh`:

1. `pct push $CTID pve/ct-install.sh /tmp/cdh-ct-install.sh` (from the checkout, the release bundle, or the same file the host script was fetched from). Pushing instead of `curl` inside the CT avoids a bootstrap dependency: the Fedora template has no `curl` until packages are installed.
2. If a local build is being used (`dist/cloud-desktop-host` + checkout), push the binary and a tarball of `scripts/` + `configs/` to a temp dir in the CT and pass its path (`CDH_LOCAL_BUNDLE`).
3. `pct exec $CTID -- env <contract vars> bash /tmp/cdh-ct-install.sh [--check] [--update]`.
4. Interpret the exit code (§2.5) and fold the result into the host summary (`NEEDED`, `RESTART_CT`).
5. Remove the pushed files.

`phase_summary` stays on the host; it already prints the IP, web UI and Moonlight hints.

### 2.4 The in-container contract

`ct-install.sh` is **non-interactive**. A `curl | bash` pipe has no tty, so there are no `ask`/`confirm` prompts inside; everything comes from the environment with safe defaults.

| Variable | Default | Meaning |
|----------|---------|---------|
| `CT_USER` | `user` | session user; created if missing (today `52-phase-container.sh` does it from the host, this moves inside) |
| `INSTALL_STEAM` | `1` | Steam + Gamescope + MangoHud |
| `CDH_INPUT_ISOLATED` | `0` | set to `1` by the host script when the input guard is on: skips the shared-input udev rule and removes it if present (today `phase_shared_input_rule`) |
| `CDH_GH_REPO`, `CDH_VERSION` | as today | release source; `latest` when empty |
| `CDH_LOCAL_BUNDLE` | empty | directory with `cloud-desktop-host`, `scripts/`, `configs/` to use instead of a download |
| `SUNSHINE_PKG` | empty | URL or path of a Sunshine package; empty = latest release asset for this distro (§3.4) |
| `SUNSHINE_VERSION` | empty | pin a Sunshine release tag (update mode) |
| `CLOUD_MOUSE_PKG` | empty | URL/path, `none` to skip; empty = latest release for this distro, skipped with a warning if there is none |
| `CSRF_EXTRA` | empty | extra Sunshine CSRF origins |
| `CT_CDH` | `/opt/cloud-desktop-host` | scripts + configs location |
| `LOG` | `/var/log/cdh-ct-install.log` | inside the CT; the host script also captures the streamed output in its own log |

Flags: `--check` (report only), `--update` (§4), `--yes` is not needed (nothing asks).

Host facts the inside phase used so far, and where the standalone script gets them:

| Fact | Today | Standalone |
|------|-------|------------|
| NVIDIA driver version | `/sys/module/nvidia/version` on the host | same file is visible inside an LXC; fallback `/proc/driver/nvidia/version` (needs the `/dev/nvidia*` nodes, which the host phase already mapped) |
| host uid of `CT_USER` (shared-input udev rule) | `100000 + uid` computed on the host | second column of `/proc/self/uid_map` inside the CT gives the offset; in a privileged CT or a VM the map is identity and the rule uses the plain uid |
| CT IP (Sunshine CSRF origin) | `pct exec ip …` | `ip -4 -o addr show` / `hostname -I` inside |
| input guard on/off | `INSTALL_INPUT_GUARD` on the host | `CDH_INPUT_ISOLATED` from the contract; default off |
| release bundle | downloaded on the host, `pct push`ed file by file | downloaded inside (`30-release.sh` is shared), sha256 verified against `SHA256SUMS` as today |
| local build | `REPO`/`CDH_BIN` on the host | `CDH_LOCAL_BUNDLE` |

The `ct*` helpers become local: `ct() { "$@"; }`, `ct_sh() { bash -c "$1"; }`, `ct_user() { runuser -l "$CT_USER" -c "$1"; }`, `pct push` → `install -m`. With that shim most `chk_*`/`do_*` functions move unchanged in a first pass; dropping the shim is a cleanup for later.

### 2.5 Exit codes and `--check` pass-through

The step engine (`step`, `require`, `NEEDED`, `APPLIED`) is shared, so `--check` inside works like on the host. The host script needs the result back:

| Exit | Meaning |
|------|---------|
| 0 | nothing needed / everything applied |
| 10 | `--check`: N steps needed (N printed on the last line as `NEEDED=N` for the host to add to its own count) |
| 11 | applied, but the **container must be restarted** (the equivalent of `RESTART_CT`; e.g. a step that changed something only effective at container start) |
| 12 | applied, the **user session was restarted** (update mode; informational) |
| 1 | a `require` failed or a step did not converge; message already printed |
| 2 | usage / unsupported distro |

### 2.6 Running it standalone

```bash
# inside any container/VM that has /dev/dri/renderD*, /dev/uinput, /dev/input/* and /run/udev from the host
CT_USER=user INSTALL_STEAM=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/chiririll/cloud-desktop-host/v1.2.0/pve/ct-install.sh)" -- --check
CT_USER=user INSTALL_STEAM=1 bash -c "$(curl -fsSL …/v1.2.0/pve/ct-install.sh)"
```

- Prefer a **tag** in the URL rather than `main`. The bundle it then downloads is still verified by `SHA256SUMS`.
- The script ends with `main "$@"` (same as today), so a truncated download executes nothing.
- The things the script cannot do for you on a non-Proxmox host: device passthrough, the udev-db bind mount source, the `sys_nice` cap override for KWin, `/dev/shm` size. Document them as a short "host requirements" list in `INSTALL_AND_CONFIG.md` (the LXC conf block there already is that list).

---

## 3. Ubuntu support

### 3.1 CDH itself is distro-neutral

Runtime libraries of the released binary (`ldd dist/cloud-desktop-host`): wayland-server/client, libdrm, xkbcommon, pixman, EGL, GBM, GLESv2, libinput, libudev, libsystemd, libstdc++, plus their transitive deps. wlroots is linked statically. The NVIDIA userspace is installed from the `.run` file with `--no-kernel-module`, which is the same on every distro.

### 3.2 Which Ubuntu

wlroots 0.20.2 (`subprojects/wlroots/meson.build`) requires:

| Dependency | wlroots 0.20.2 needs | Ubuntu 24.04 LTS | Ubuntu 26.04 LTS |
|------------|----------------------|------------------|------------------|
| wayland-server | ≥ 1.24 | 1.22 | ok (verify) |
| libdrm | ≥ 2.4.129 | 2.4.120 | verify |
| xkbcommon | ≥ 1.8 | 1.6 | ok (verify) |
| pixman | ≥ 0.43 | 0.42 | ok (verify) |
| wayland-protocols (CDH) | ≥ 1.35 | 1.34 | ok (verify) |

So **24.04 is out** unless these are built from source, and Plasma 6 (the scripts assume KF6 paths) only arrived in 25.04 anyway. Target **26.04 LTS**; confirm the four floors with `pkg-config --modversion` on the real template before committing to it. Since the binary links against distro sonames (`libinput.so.10`, `libwacom.so.9`, glibc), Ubuntu needs **its own build** of the binary: it is not a matter of reusing the Fedora one.

### 3.3 Package backend

`ct/20-distro.sh` sources `/etc/os-release` and sets `DISTRO=fedora|ubuntu`, `DISTRO_VERSION` (e.g. `43`, `26.04`), and defines:

| Function | dnf | apt |
|----------|-----|-----|
| `pkg_missing pkg…` | `rpm -q` (as `rpm_missing` today) | `dpkg-query -W -f '${Status}\n'` and look for `install ok installed` |
| `pkg_install pkg…` | `dnf install -y` (lenient exit, re-check with `rpm -q`, as today) | `DEBIAN_FRONTEND=noninteractive apt-get install -y` (same lenient handling: udev triggers in postinst fail in a CT too); set `NEEDRESTART_MODE=a` |
| `pkg_install_file url\|path` | `dnf install -y <rpm>` | `apt-get install -y ./file.deb` (resolves deps) |
| `pkg_refresh` | no-op (dnf refreshes itself) | `apt-get update` (once per run, before the first install) |
| `pkg_upgrade_available` | `dnf check-upgrade` exit 100 | `apt-get -s upgrade` lists packages |
| `pkg_upgrade` | `dnf upgrade -y` | `apt-get -y dist-upgrade` |
| `pkg_version pkg` | `rpm -q --qf %{VERSION}` | `dpkg-query -W -f '${Version}'` |

Per-distro data, kept in the same file:

```bash
CT_PACKAGES_fedora=(dbus-daemon dbus-tools dbus-x11 pipewire wireplumber pipewire-pulseaudio
  pipewire-utils xorg-x11-server-Xwayland kwin plasma-desktop grim curl libcap xprop
  xdg-utils kde-cli-tools)
# candidate list, verify every name on the 26.04 template
CT_PACKAGES_ubuntu=(dbus dbus-user-session dbus-x11 pipewire wireplumber pipewire-pulse
  pipewire-audio xwayland kwin-wayland plasma-desktop plasma-workspace polkit-kde-agent-1
  grim curl ca-certificates libcap2-bin x11-utils xdg-utils kde-cli-tools)
STEAM_PACKAGES_fedora=(steam gamescope mangohud)      # after RPM Fusion nonfree
STEAM_PACKAGES_ubuntu=(steam-installer gamescope mangohud)   # after dpkg --add-architecture i386 + multiverse
```

Steam on Ubuntu additionally needs `dpkg --add-architecture i386` and the `multiverse` component enabled, which replaces the RPM Fusion step. The apt `gamescope` may be older than the pinned submodule (3.16.14.5); the Steam Deck Mode docs already describe building the submodule, and `GAMESCOPE_BIN` in `sunshine-prep-gamescope.sh` already allows pointing at it.

### 3.4 Release assets per distro

Today: `cdh-fc43-x86_64.tar.gz`, `cloud-desktop-host-fc43-x86_64`, one `MANIFEST` line per Fedora release, built by a matrix over `fedora: ["43","44","45"]` in `.github/workflows/release.yml` from `Dockerfile` (`ARG FEDORA`).

Change:

- `Dockerfile` takes `ARG BASE=fedora:43` and a second `RUN` branch for apt (`build-essential meson ninja-build pkg-config libwayland-dev wayland-protocols libgles2-mesa-dev libegl1-mesa-dev libinput-dev libsystemd-dev libdrm-dev libgbm-dev libxkbcommon-dev libpixman-1-dev`). The meson flags do not change.
- Matrix becomes a list of `{distro, version, tag}` entries: `fc43`, `fc44`, `fc45`, `ubuntu2604`. Asset names: `cdh-<tag>-x86_64.tar.gz`, `cloud-desktop-host-<tag>-x86_64`.
- `fetch_manifest`/`fetch_release` select by `$DISTRO_TAG` instead of `fc$FEDORA`. `DISTRO_TAG` is computed from os-release inside the CT (`fc43`, `ubuntu2604`); the host script no longer needs `FEDORA` except to pick the CT template.
- `SUPPORTED_FEDORA` becomes `SUPPORTED_DISTROS=(fc43 fc44 fc45 ubuntu2604)`; the host's `--fedora N` flag becomes `--distro fedora-44` / `--distro ubuntu-26.04` and picks the `pveam` template (`fedora-44-default`, `ubuntu-26.04-standard`) and `--ostype`.

### 3.5 Sunshine, Cloud Mouse, Steam

- **Sunshine.** LizardByte publishes `.deb` assets per Ubuntu release next to the `fcNN` RPMs. `latest_sunshine_pkg` matches the asset pattern for `$DISTRO_TAG`. Risk: upstream may lag behind a new Ubuntu LTS and only ship a 24.04 deb whose library deps do not resolve on 26.04. Fallback is the `subprojects/sunshine` build already described in `docs/BUILD.md`; the installer should fail with that hint rather than try to build. Package name differs in case (`Sunshine` RPM vs `sunshine` deb): keep the case-insensitive match.
- **KCM Cloud Mouse.** The release workflow in `kcm-cloud-mouse/` only produces RPMs. Add a deb target (the project is CMake + Qt6/KF6, `packaging/` already has the RPM spec; a `cpack` DEB generator is the least work). Until it exists, the installer skips it with the existing "no build for this release" warning.
- **Steam.** `steam-installer` from multiverse, i386 enabled. Steam self-updates afterwards. `chk_nocaps gamescope` applies unchanged.

### 3.6 Fixes outside the installer

Two hardcoded Fedora paths in the session scripts:

- `scripts/lib.sh:217` spawns `/usr/libexec/kf6/polkit-kde-authentication-agent-1`.
- `scripts/run.sh:114` spawns `/usr/libexec/kactivitymanagerd`.

On Debian/Ubuntu these live under `/usr/lib/x86_64-linux-gnu/libexec/` (with or without a `kf6/` subdir; verify on the template). Replace both with a small `find_libexec <name>` helper in `lib.sh` that tries the known locations and logs a warning if none exists, instead of adding a second hardcoded path.

Also check on the Ubuntu template whether `kwin_wayland` carries `cap_sys_nice+ep` (`getcap`). If it does, the `lxc.cap.drop` override in `INSTALL_AND_CONFIG.md` applies unchanged; if not, nothing to do.

---

## 4. Update mode

### 4.1 Principle

`--update` is not a separate script. The step engine already means "make the system match the target"; update mode moves the target to "latest" and adds a package upgrade. Both `install.sh --update` (host) and `ct-install.sh --update` (container) exist; the host one does its own host steps and then runs the inside one with `--update`.

### 4.2 What a plain re-run already updates

| Step | Why it fires |
|------|--------------|
| CDH binary | `chk_cdh` compares sha256 with the manifest of the resolved release (`latest` unless `CDH_VERSION` is pinned) |
| scripts/configs in `$CT_CDH` | `chk_scripts` runs `sha256sum -c` against the same manifest |
| NVIDIA userspace | `chk_nvuser` looks for `libnvidia-glcore.so.<host driver version>`; a host driver upgrade makes it fire; the `.run` installer removes the previous version itself |
| Sunshine / Gamescope file caps | `chk_nocaps` re-fires after a package upgrade restores them |
| udev db mount, linger, service unit | content comparisons |

### 4.3 What update mode adds (`ct/60-phase-update.sh`)

Inside the container, in this order:

1. **Package upgrade.** `step "distro packages up to date" pkg_upgrade_available pkg_upgrade`. Runs **before** the Sunshine/Gamescope no-caps steps, because a Sunshine package upgrade restores its file capability and ENet breaks silently (`AT_SECURE`).
2. **Sunshine version.** In update mode `chk_sunshine` also compares `pkg_version sunshine` with the latest release tag (or `SUNSHINE_VERSION` if set) and reinstalls on mismatch. `latest_sunshine_pkg` already resolves the asset.
3. **Cloud Mouse version.** Same, against the `kcm-cloud-mouse` latest release.
4. **CDH bundle.** As today; `CDH_VERSION` pins it. Before overwriting, keep the previous binary as `/usr/local/bin/cloud-desktop-host.prev` for a one-line rollback.
5. **No-caps steps.** As today, after 1–3.
6. **Session restart.** If any step applied (`APPLIED` accumulated into an `APPLIED_ANY` counter) and no client is connected: `systemctl --user restart cloud-desktop-host.service` as `CT_USER`, exit 12. If a client is connected: print what changed, do not restart, exit 0 with a warning. `--update --force-restart` overrides.

"Client connected" needs a marker. Options, pick one:

- The prep scripts (`sunshine-prep-*.sh`) touch `$CDH_STATE_DIR/stream-active` and the undo scripts remove it. Cheap and already in the scripts' control flow (`cdh_env` sets `CDH_STATE_DIR`).
- Query CDH's idle state over D-Bus (`idle.cpp` leaves idle on the first `zwlr_screencopy_frame_v1`, so "not idle" = a capture client is active). Needs a getter on the D-Bus interface; more precise but more code.

### 4.4 Host side of `install.sh --update`

- `cdh_input_guard.ko` for the running kernel (the existing `chk_guard_file` step keyed by `GUARD_KO_NAME` already covers a kernel upgrade; make sure the host phase runs in update mode).
- `host-persist.sh` settings (modeset, uinput at boot): existing steps.
- Driver mismatch is detected inside (NVIDIA userspace step), so the host script does nothing special; it just runs the inside script with `--update` and reports the exit code. If the inside script returns 11 (container restart needed), the host script restarts the CT like `RESTART_CT` does today.
- Self-update: when run via `curl`, the script is already the latest; from a checkout it is `git pull`. Do not build a self-updater.

### 4.5 Dry run and scheduling

- `--check --update` falls out of the step engine and lists what would change. Recommended first command after a host upgrade.
- Because `ct-install.sh` is standalone, a systemd timer **inside the CT** can run `ct-install.sh --update` on a quiet schedule (e.g. weekly at night). The connected-client guard is what makes that safe. Ship the timer as `files/systemd/cdh-update.timer` + `.service`, disabled by default, enabled with `INSTALL_UPDATE_TIMER=1`.

---

## 5. Implementation order

Each step leaves the repo working; CI (`build.sh --check`, `shell.yml`) runs on each.

1. **Split without behaviour change.** Move `53`/`54` into `install-parts/ct/`, add the `ct*` shims, teach `build.sh` to emit `ct-install.sh`, add `55-phase-run-inside.sh`, define the env contract and exit codes. Still Fedora-only. Test: `install.sh --check` output identical to before on an existing CT.
2. **Package backend.** Introduce `ct/20-distro.sh` and replace `dnf`/`rpm` calls in the ct parts with `pkg_*`. Still Fedora-only in practice, but the Ubuntu branch exists.
3. **Ubuntu build.** `Dockerfile` base arg, apt dependency list, matrix entry `ubuntu2604`, asset naming, `DISTRO_TAG` in `30-release.sh`. Fix the two libexec paths in `scripts/`. Verify the wlroots version floors on the real template first (§3.2).
4. **Ubuntu install path.** Package names, Steam enablement, Sunshine deb selection, Cloud Mouse deb (or warning), `--distro` on the host script, `ubuntu-26.04-standard` template. Test end to end on a fresh CT.
5. **Update mode.** `ct/60-phase-update.sh`, version checks, `.prev` binary, stream-active marker, session restart, exit code 12, host pass-through, optional timer.
6. **Docs.** `PVE_INSTALLER.md` (host script), a new `CT_INSTALLER.md` (contract, standalone use, update mode), `INSTALL_AND_CONFIG.md` Part II gets an Ubuntu column, `RELEASE_BUILD.md` the new matrix.

---

## 6. Open questions

- Exact Ubuntu 26.04 versions of wayland, libdrm, xkbcommon, pixman (§3.2): decides whether 26.04 is enough or a PPA/backport is needed.
- Whether LizardByte ships a 26.04 deb at the time of implementation (§3.5).
- Debian/Ubuntu libexec layout for the KF6 polkit agent and `kactivitymanagerd` (§3.6).
- Stream-active marker: state file vs D-Bus getter (§4.3).
- Should `CT_USER` creation move inside the script entirely (needed for standalone use) or stay on the host for the Proxmox path too? Moving it is simpler: one place.
