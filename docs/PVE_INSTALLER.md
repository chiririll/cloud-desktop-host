# Proxmox installer: `pve/install.sh`

One script, run on the Proxmox host, that sets up CDH + KWin/Plasma + Sunshine (+ Steam/Gamescope) in an **unprivileged** LXC container that shares the NVIDIA GPU.

It is **idempotent**. Each step:

1. **checks** whether its result is already in place,
2. **applies** the change only if it is not,
3. **checks again**, and stops with an error if the step still is not satisfied.

Running it again is always safe. Re-run it after a host NVIDIA driver update, after `/dev/dri/cardN` got renumbered, or after a Sunshine upgrade restored its file capabilities. Each time it fixes only what drifted.

---

## Quick start

On the Proxmox host, as root:

```bash
# see what would be done; changes nothing
bash -c "$(curl -fsSL https://raw.githubusercontent.com/chiririll/cloud-desktop-host/main/pve/install.sh)" -- --check

# do it
bash -c "$(curl -fsSL https://raw.githubusercontent.com/chiririll/cloud-desktop-host/main/pve/install.sh)"
```

From a checkout:

```bash
./pve/install.sh --check
./pve/install.sh
```

The script first asks which container to use. It lists the existing CTs and suggests the next free ID:

- **An existing CT ID:** it asks for confirmation, because the CT's config may change and the CT may be restarted.
- **A free ID:** it asks for hostname, storage, disk, cores, memory, bridge and IP (`dhcp` or static + gateway) (Enter accepts the default), then confirms before creating the CT.

With `--check` it only asks for the ID, and changes nothing.

Output looks like:

```
── Host
 ✔ Release latest downloaded (sha256 ok)
 ✔ NVIDIA driver loaded (595.80)
 ✔ nvidia-drm modeset=Y
 ✔ uinput loaded
 ✔ nvidia-uvm device (done)
 ! uinput/nvidia-uvm not set up at boot, load them before starting the CT (or run pve/host-persist.sh)
     nvidia_uvm not in /etc/modules-load.d
── Container 180 (gaming)
 ✔ CT exists
 ◦ GPU/uinput passthrough (/dev/dri/card1, /dev/dri/renderD129) (needed)
 …
```

`✔` means already in place, `✔ … (done)` means changed now, `◦ … (needed)` means it would change (in `--check` mode), and `!` is a warning that `install.sh` does not act on.

At the end the script prints the CT's IP, how to start the stack, and the Sunshine web UI address.

---

## Prerequisites

- Proxmox VE 8.1+ (`pct set --devN` passthrough).
- The NVIDIA driver installed **on the host** and loaded (`nvidia-smi` works). The script does not install host drivers.
- Internet access from the host and the container (template, NVIDIA `.run`, Sunshine RPM, Fedora packages).

---

## Where the CDH files come from

| Situation | Source |
|---|---|
| Run via `curl`, or from a checkout without `dist/` | latest GitHub release `cdh-fc$FEDORA-x86_64.tar.gz`, verified against `SHA256SUMS` |
| `CDH_VERSION=v1.0.0` | that release |
| Run from a checkout that has `dist/cloud-desktop-host` | the local build plus the checkout's `scripts/` and `configs/` |

How releases are built: [RELEASE_BUILD.md](RELEASE_BUILD.md).

---

## Settings

Everything you are asked for can also be set as an environment variable, which skips that question. Without a terminal (cron, `ssh host cmd`), `CTID` is required. Missing creation settings then use their defaults, and confirmations are skipped.

```bash
CTID=181 CT_HOSTNAME=gaming2 INSTALL_STEAM=0 ./pve/install.sh
CTID=181 YES=1 bash -c "$(curl -fsSL …/pve/install.sh)"     # no questions at all
```

| Variable | Default | Meaning |
|---|---|---|
| `CTID` | asked; suggests `pvesh get /cluster/nextid` | container ID; created if it does not exist |
| `YES` | `0` | `1` skips the confirmations |
| `CT_HOSTNAME` | asked, `cloud-desktop` | used only when creating the CT |
| `CT_STORAGE` | asked, first active storage with `rootdir` content | rootfs storage (creation only) |
| `CT_DISK` | asked, `64` | rootfs size in GB (creation only) |
| `CT_CORES` | asked, `8` | creation only |
| `CT_MEMORY` | asked, `16384` | MB, creation only |
| `CT_BRIDGE` | asked, `vmbr0` | `net0` bridge (creation only) |
| `CT_IP` | asked, `dhcp` | `dhcp`, or a static address in CIDR form, e.g. `192.168.1.50/24` (creation only) |
| `CT_GATEWAY` | asked, host default route | gateway for a static `CT_IP` (creation only) |
| `TEMPLATE_STORAGE` | `local` | where the Fedora template is downloaded |
| `FEDORA` / `--fedora N` | asked for a new CT (default `43`); detected for a running existing CT | `43`, `44` or `45`: template version and release bundle |
| `CT_USER` | `user` | desktop user inside the CT |
| `INSTALL_STEAM` | `1` | `0` skips RPM Fusion, Steam, Gamescope and MangoHud |
| `SHM_SIZE` | `4G` | size of the CT's `/dev/shm` tmpfs |
| `NVIDIA_PCI` | first NVIDIA GPU | e.g. `0000:01:00.0`, when the host has several NVIDIA cards |
| `CDH_VERSION` | local `dist/`, else `latest` | release tag to install |
| `CDH_GH_REPO` | `chiririll/cloud-desktop-host` | where releases come from |
| `SUNSHINE_RPM` | LizardByte latest `sunshine-fedora-$FEDORA-amd64.rpm` | URL or a local `.rpm` path |
| `CSRF_EXTRA` | empty | extra Sunshine web UI origins, e.g. `https://gaming.example.org` |
| `INSTALL_INPUT_GUARD` | `1` | `0` skips the `cdh_input_guard` host kernel module. The CT then shares the host's `/dev/input` with every other such CT |
| `CDH_GUARD_REPO` | `chiririll/cdh-input-guard` | where the module release comes from |
| `CDH_GUARD_VERSION` | `latest` | release tag of the module |

Settings marked "creation only" do not change an existing CT.

---

## Steps

### Host

| Step | Check | Apply |
|---|---|---|
| CDH files | local `dist/` present, or a download is needed | download the release, verify sha256 |
| NVIDIA driver | `/sys/module/nvidia/version` exists and an NVIDIA render node exists | **stops**: install the driver yourself |
| `nvidia-drm modeset=Y` | `/sys/module/nvidia_drm/parameters/modeset` | **stops**: set `modeset=1` (e.g. with [`host-persist.sh`](#optional-survive-a-host-reboot-pvehost-persistsh)) and reboot |
| uinput | `/dev/uinput` exists | `modprobe uinput` (this boot only) |
| nvidia-uvm | `/dev/nvidia-uvm` exists | `nvidia-modprobe -c0 -u` (this boot only) |
| Boot setup | `uinput` and `nvidia_uvm` in `/etc/modules-load.d`, a udev rule runs `nvidia-modprobe -u` | **warning only**, nothing is written |

`install.sh` does not write the host boot config for modules. Whatever it loads is gone after a host reboot, unless you load it yourself (for example by running CUDA or `nvidia-smi` before the CT starts) or run `host-persist.sh`.

### Input guard

Skipped with `INSTALL_INPUT_GUARD=0`.

Sunshine's virtual keyboard, mouse and gamepads are kernel input devices, global to the host. Two things keep them where they belong:

- The module `cdh_input_guard` detaches them from the host console, and records which container created each one.
- The host helper `cdh-input-node`, run by udev, puts the device nodes only into the directory of the container that created the device. That directory is the container's `/dev/input`, so one CT cannot read or inject another CT's keyboard, mouse or gamepad.

| Step | Check | Apply |
|---|---|---|
| Module file | `/lib/modules/$(uname -r)/extra/cdh_input_guard.ko` matches the release (sha256) | download the `.ko` built for this kernel, `depmod` |
| udev rule (logind) | `/etc/udev/rules.d/71-cdh-virtual-input.rules` matches the release | download, `udevadm control --reload` |
| Module loaded | `/sys/module/cdh_input_guard` exists | `modprobe` (this boot only) |
| Per-container input nodes | `/usr/local/sbin/cdh-input-node` and `/etc/udev/rules.d/72-cdh-input-node.rules` match the installer's copies | write both, reload udev, `cdh-input-node sync` |
| Boot setup | `cdh_input_guard` in `/etc/modules-load.d` | **warning only**: run `host-persist.sh` |

A device gets nodes only if the module was loaded when it was created. So the module **must load at boot**: without it, after a host reboot the containers get no input devices at all. The same happens after a host kernel update until the installer is re-run, because the module is built per kernel.

Per container, the installer also writes (see the next table):

```
/dev/cdh-input/<ctid>/              the CT's /dev/input: eventN and jsN of its own devices, mode 0600
/etc/tmpfiles.d/cdh-input-<ctid>.conf   recreates that directory at host boot
/etc/cdh-input/<ctid>.uid           host uid (100000 + uid of CT_USER) that owns the nodes
```

The directories are under `/dev` because `/run` is mounted `nodev`. A device created by the host itself, or before the module loaded, is given to no container.

With several containers, run the installer for each of them. A CT that still mounts the host's `/dev/input` keeps seeing every device, and the installer warns about it. Once no CT is left on the shared `/dev/input`, the old rule `60-lxc-virtual-input.rules` is removed.

### Container config

| Step | Check | Apply |
|---|---|---|
| Fedora template | present in `TEMPLATE_STORAGE` (skipped if the CT exists) | `pveam update` + download the newest `fedora-$FEDORA-default` |
| CT exists | `pct status` | `pct create … --unprivileged 1 --features nesting=1,fuse=1` |
| Unprivileged | `unprivileged: 1`, no `lxc.idmap` | **stops**: the script assumes the default uid shift of 100000 |
| `nesting=1` | in `features` | `pct set --features nesting=1,fuse=1` (restart needed) |
| Input directory² | `/dev/cdh-input/$CTID` and its `tmpfiles.d` entry exist | create both. Done before the CT starts: the CT does not start without the directory |
| CT running | `pct status` | `pct start` |
| Raw `lxc.*` lines | every line present in the main section of `/etc/pve/lxc/$CTID.conf`, and no other `/dev/input` mount entry | removes the other `/dev/input` entry, inserts the missing lines before any `[snapshot]` section (restart needed) |
| CT user | user exists and is in `render` and `input` | `useradd -m`, `usermod -aG video,render,input,wheel` |
| Input owner² | `/etc/cdh-input/$CTID.uid` holds the CT user's host uid | write it, `cdh-input-node sync` |
| GPU/uinput passthrough | `devN` entries exactly match the wanted set | removes stale `/dev/nvidia*`, `/dev/dri/*` and `/dev/uinput` entries, adds missing ones (restart needed) |

² only with the input guard.

If any "restart needed" step changed something, the script does **one** full `pct stop` + `pct start`. A reboot from inside the CT does not apply LXC config changes.

Raw lines it manages:

```ini
lxc.cgroup2.devices.allow: c 13:* rwm                                    # Sunshine's dynamic input nodes
lxc.mount.entry: /dev/cdh-input/<ctid> dev/input none bind,create=dir    # only this CT's devices
lxc.mount.entry: /run/udev mnt/host-udev none bind,ro,optional,create=dir  # host udev db (re-bound in fstab)
lxc.cap.drop:                                                              # reset template drops…
lxc.cap.drop: mac_admin mac_override sys_module sys_pacct sys_rawio sys_time  # …keep sys_nice, setfcap
lxc.mount.entry: tmpfs dev/shm tmpfs rw,nosuid,nodev,mode=1777,size=4G,create=dir 0 0
```

With `INSTALL_INPUT_GUARD=0` the second line is `lxc.mount.entry: /dev/input dev/input none bind,optional,create=dir`: the host's whole `/dev/input`, shared with every other such CT.

Passthrough entries come from sysfs, not hard-coded names. That matters on hosts with an iGPU, where `renderD128` may not be the NVIDIA card.

```
/dev/nvidia<minor>, /dev/nvidiactl, /dev/nvidia-modeset,
/dev/nvidia-uvm, /dev/nvidia-uvm-tools        gid=<video in CT>
/dev/dri/renderD<N> of the NVIDIA GPU          gid=<render in CT>
/dev/dri/card<N> of the NVIDIA GPU             gid=<video in CT>   (Sunshine's CUDA/NVENC path)
/dev/uinput                                     gid=<input in CT>
```

The gids are looked up inside the CT (`getent group`), so they match Fedora's dynamic `render`/`input` groups.

### Inside the container

| Step | Check | Apply |
|---|---|---|
| Host udev db | fstab has the `/mnt/host-udev → /run/udev` bind, and `/run/udev/data` is non-empty | add the fstab line, mount it |
| Host udev rule | without the input guard: `/etc/udev/rules.d/60-lxc-virtual-input.rules` on the **host** gives virtual input devices to the CT user's host uid (`100000 + uid`). With it: the rule is absent, unless another CT still mounts the host's `/dev/input` | write the rule, or remove it; `udevadm control --reload` |
| Packages | `rpm -q` on KWin, Plasma, PipeWire, Xwayland, D-Bus, grim, xprop… | `dnf install` |
| NVIDIA userspace | `/usr/lib64/libnvidia-glcore.so.<host version>` exists | download the matching `.run`, install with `--no-kernel-module --install-compat32-libs -s` |
| `nvidia-smi` | `nvidia-smi -L` works in the CT | **stops**: check passthrough and versions |
| Linger | `/var/lib/systemd/linger/$CT_USER` | `loginctl enable-linger` |
| CDH binary | sha256 equal to `/usr/local/bin/cloud-desktop-host` | `pct push` |
| Scripts + configs | every file matches by sha256 in `/opt/cloud-desktop-host` | copy `scripts/` and `configs/` with `tar`, owned by root, read-only for the user |
| Sunshine | `rpm -q sunshine` | `dnf install` (postinst errors about `modprobe`/`udevadm` are expected in a CT and ignored) |
| Sunshine caps | `getcap` on the real binary is empty | `setcap -r`. File caps set `AT_SECURE`, which breaks ENet, so Moonlight can't connect |
| Sunshine config | `~/.config/sunshine/sunshine.conf` and `apps.json` exist | write defaults: `capture=wlr`, `encoder=nvenc`, `gamepad=xone`, `system_tray=disabled`, `csrf_allowed_origins=https://<CT IP>:47990[,CSRF_EXTRA]`. **Never overwrites** existing files |
| RPM Fusion nonfree¹ | `rpm -q rpmfusion-nonfree-release` | install the release RPM |
| Steam + Gamescope + MangoHud¹ | `rpm -q` | `dnf install` |
| Gamescope caps¹ | `getcap` empty | `setcap -r` |

¹ only with `INSTALL_STEAM=1`.

---

## Optional: survive a host reboot (`pve/host-persist.sh`)

A separate, opt-in script that writes the host's boot config. It has the same check → apply → check steps and the same `--check` flag.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/chiririll/cloud-desktop-host/main/pve/host-persist.sh)" -- --check
bash -c "$(curl -fsSL https://raw.githubusercontent.com/chiririll/cloud-desktop-host/main/pve/host-persist.sh)"
```

| Step | Check | Apply |
|---|---|---|
| `nvidia-drm modeset=1` | `options nvidia-drm modeset=1` in `/etc/modprobe.d/*.conf`, or `nvidia-drm.modeset=1` on the kernel command line | `/etc/modprobe.d/nvidia-drm.conf`, `update-initramfs -u` |
| uinput | `uinput` in `/etc/modules` or `/etc/modules-load.d/*.conf` | `/etc/modules-load.d/uinput.conf`, `modprobe uinput` |
| nvidia-uvm | `nvidia_uvm` in modules-load, a udev rule running `nvidia-modprobe -u` | `/etc/modules-load.d/nvidia-uvm.conf`, `/etc/udev/rules.d/70-nvidia-uvm.rules`, load it now |

Existing config you wrote yourself (another file name, the kernel command line) counts as done. If modeset is not active yet, it tells you to reboot.

---

## What it does not do

- Install or upgrade the **host** NVIDIA driver.
- Write host boot config (`/etc/modprobe.d`, `/etc/modules-load.d`, udev rules for the GPU). That is `host-persist.sh`.
- **Reboot** the host.
- Set a password for the CT user: `pct exec <CTID> -- passwd user`.
- Start the stack or create a systemd service. Start it with `pct exec <CTID> -- runuser -l user -c /opt/cloud-desktop-host/scripts/run.sh`.
- Pair Moonlight. Open `https://<CT IP>:47990`, create the Sunshine login, and enter the PIN.
- Overwrite your Sunshine config. To regenerate it, delete `~/.config/sunshine/sunshine.conf` and re-run.

---

## When to re-run

| Event | What the re-run fixes |
|---|---|
| Host NVIDIA driver updated | CT userspace reinstalled at the new version |
| GPU nodes renumbered after a reboot (`card0` ↔ `card1`) | stale `devN` replaced, CT restarted |
| Sunshine or Gamescope upgraded in the CT | file caps removed again |
| New CDH release | binary and scripts updated (`CDH_VERSION=…` to pin one) |
| Host kernel updated | `cdh_input_guard` installed for the new kernel and loaded. Until then the containers get no input devices |
| Another CT added on the same host | run it for every CT, so each gets its own `/dev/input` |
| Changed `scripts/` in your checkout | copied to the CT |

Run `--check` first to see what will change.

---

## Troubleshooting

All command output goes to `/var/log/cdh-lxc-install.log` on the host, with a `=== <time> <step>` header for each step.

| Message | Meaning |
|---|---|
| `<step>: failed (exit N)` | the apply command failed; the log shows its output |
| `no terminal to ask on: set CTID=<id>` | run without a TTY; pass `CTID=…` |
| `aborted` | you answered no to a confirmation |
| `<step>: still not satisfied after applying` | the command ran but the check still fails. Example: the passthrough step after `pct` stored options in a different form. Compare with `pct config $CTID \| grep ^dev` |
| `could not download/verify cdh-fc43-x86_64.tar.gz` | no release yet, wrong `CDH_VERSION`/`FEDORA`, or a checksum mismatch |
| `nvidia-drm modeset=Y: set nvidia-drm modeset=1 … and reboot` | expected on a fresh host: run `host-persist.sh`, reboot, re-run |
| `! uinput/nvidia-uvm not set up at boot` | only a warning; after a host reboot, load them before starting the CT or run `host-persist.sh` |
| `CT is privileged or uses a custom lxc.idmap` | the script refuses rather than guess uid mappings |
| `nvidia-smi works in CT` fails | passthrough is missing, the CT wasn't restarted, or the host and CT driver versions differ |
| `release has no cdh_input_guard-<kver>.ko` | no module was built for this host kernel yet. `INSTALL_INPUT_GUARD=0` installs without it, with a shared `/dev/input` |
| `! still on the host's shared /dev/input: CT …` | those CTs were set up before per-container input: re-run the installer for each |
| No keyboard/mouse in the stream, `/dev/input` in the CT is empty | `lsmod \| grep cdh_input_guard` on the host. If it is not loaded: `modprobe cdh_input_guard`, run `host-persist.sh`, then reconnect Moonlight so Sunshine creates its devices again |

For the background on each step (why the bind goes through `/mnt/host-udev`, why `sys_nice` is needed, the `AT_SECURE` bug), see the step-by-step guide this script automates.

---

## Development

`pve/install.sh` is **generated**: it has to stay one self-contained file because it is run as `bash -c "$(curl …)"`. The source lives in `pve/install-parts/*.sh`, concatenated in name order by `pve/build.sh`.

| Part | Contents |
|---|---|
| `00-header` | usage comment, `set -euo pipefail` |
| `10-config` | settings, defaults, runtime globals, `parse_args` |
| `20-ui` | output helpers, `ask`/`confirm` |
| `30-step` | the `step` / `require` engine |
| `40-ct` | `ct*` helpers, `ct_install_rpm`, `chk_nocaps`, GPU discovery |
| `50-release` | release bundle download/verify, `phase_bundle` |
| `60-resolve` | which CT, which Fedora, options |
| `70`–`73-phase-*` | one `phase_*` function per stage: host, container, inside the CT, user service |
| `90-main` | `main`: the order of the phases |

To add a step, write its `chk_*` / `do_*` functions in the matching phase part and call `step` from that phase's `phase_*` function. For a new stage, add `NN-phase-<name>.sh` and one line in `90-main.sh`.

After editing a part, run `pve/build.sh` and commit `install.sh` together with it. `pve/build.sh --check` (run in CI) fails if they are out of sync.
