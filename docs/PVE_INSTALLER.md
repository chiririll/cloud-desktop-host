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
- **A free ID:** it asks for hostname, storage, disk, cores, memory and bridge (Enter accepts the default), then confirms before creating the CT.

With `--check` it only asks for the ID, and changes nothing.

Output looks like:

```
── Host
 ✔ Release latest downloaded (sha256 ok)
 ✔ NVIDIA driver loaded (595.80)
 ✔ nvidia-drm modeset=Y
 ✔ uinput loaded + persistent
 ✔ nvidia-uvm device + persistent (done)
── Container 180 (gaming)
 ✔ CT exists
 ◦ GPU/uinput passthrough (/dev/dri/card1, /dev/dri/renderD129) (needed)
 …
```

`✔` means already in place, `✔ … (done)` means changed now, and `◦ … (needed)` means it would change (in `--check` mode).

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
| `CT_BRIDGE` | asked, `vmbr0` | `net0` bridge, DHCP (creation only) |
| `TEMPLATE_STORAGE` | `local` | where the Fedora template is downloaded |
| `FEDORA` | `43` | template version, and which release bundle to download |
| `CT_USER` | `user` | desktop user inside the CT |
| `INSTALL_STEAM` | `1` | `0` skips RPM Fusion, Steam, Gamescope and MangoHud |
| `SHM_SIZE` | `4G` | size of the CT's `/dev/shm` tmpfs |
| `NVIDIA_PCI` | first NVIDIA GPU | e.g. `0000:01:00.0`, when the host has several NVIDIA cards |
| `CDH_VERSION` | local `dist/`, else `latest` | release tag to install |
| `CDH_GH_REPO` | `chiririll/cloud-desktop-host` | where releases come from |
| `SUNSHINE_RPM` | LizardByte latest `sunshine-fedora-$FEDORA-amd64.rpm` | URL or a local `.rpm` path |
| `CSRF_EXTRA` | empty | extra Sunshine web UI origins, e.g. `https://gaming.example.org` |

Settings marked "creation only" do not change an existing CT.

---

## Steps

### Host

| Step | Check | Apply |
|---|---|---|
| CDH files | local `dist/` present, or a download is needed | download the release, verify sha256 |
| NVIDIA driver | `/sys/module/nvidia/version` exists and an NVIDIA render node exists | **stops**: install the driver yourself |
| `nvidia-drm modeset=Y` | `/sys/module/nvidia_drm/parameters/modeset` | writes `/etc/modprobe.d/nvidia-drm.conf`, runs `update-initramfs -u`, then **stops and asks for a reboot** |
| uinput | `/dev/uinput` exists, listed in `/etc/modules-load.d/uinput.conf` | `modprobe uinput`, persist |
| nvidia-uvm | `/dev/nvidia-uvm` exists, module + udev rule persisted | `/etc/modules-load.d/nvidia-uvm.conf`, `/etc/udev/rules.d/70-nvidia-uvm.rules` (runs `nvidia-modprobe -c0 -u`), create the node now |

### Container config

| Step | Check | Apply |
|---|---|---|
| Fedora template | present in `TEMPLATE_STORAGE` (skipped if the CT exists) | `pveam update` + download the newest `fedora-$FEDORA-default` |
| CT exists | `pct status` | `pct create … --unprivileged 1 --features nesting=1,fuse=1` |
| Unprivileged | `unprivileged: 1`, no `lxc.idmap` | **stops**: the script assumes the default uid shift of 100000 |
| `nesting=1` | in `features` | `pct set --features nesting=1,fuse=1` (restart needed) |
| CT running | `pct status` | `pct start` |
| Raw `lxc.*` lines | every line present in the main section of `/etc/pve/lxc/$CTID.conf` | inserts the missing lines before any `[snapshot]` section (restart needed) |
| CT user | user exists and is in `render` and `input` | `useradd -m`, `usermod -aG video,render,input,wheel` |
| GPU/uinput passthrough | `devN` entries exactly match the wanted set | removes stale `/dev/nvidia*`, `/dev/dri/*` and `/dev/uinput` entries, adds missing ones (restart needed) |

If any "restart needed" step changed something, the script does **one** full `pct stop` + `pct start`. A reboot from inside the CT does not apply LXC config changes.

Raw lines it manages:

```ini
lxc.cgroup2.devices.allow: c 13:* rwm                                    # Sunshine's dynamic input nodes
lxc.mount.entry: /dev/input dev/input none bind,optional,create=dir
lxc.mount.entry: /run/udev mnt/host-udev none bind,ro,optional,create=dir  # host udev db (re-bound in fstab)
lxc.cap.drop:                                                              # reset template drops…
lxc.cap.drop: mac_admin mac_override sys_module sys_pacct sys_rawio sys_time  # …keep sys_nice, setfcap
lxc.mount.entry: tmpfs dev/shm tmpfs rw,nosuid,nodev,mode=1777,size=4G,create=dir 0 0
```

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
| Host udev rule | `/etc/udev/rules.d/60-lxc-virtual-input.rules` on the **host** gives virtual input devices to the CT user's host uid (`100000 + uid`) | write the rule, `udevadm control --reload` |
| Packages | `rpm -q` on KWin, Plasma, PipeWire, Xwayland, D-Bus, grim, xprop… | `dnf install` |
| NVIDIA userspace | `/usr/lib64/libnvidia-glcore.so.<host version>` exists | download the matching `.run`, install with `--no-kernel-module --install-compat32-libs -s` |
| `nvidia-smi` | `nvidia-smi -L` works in the CT | **stops**: check passthrough and versions |
| Linger | `/var/lib/systemd/linger/$CT_USER` | `loginctl enable-linger` |
| CDH binary | sha256 equal to `/usr/local/bin/cloud-desktop-host` | `pct push` |
| Scripts + configs | every file matches by sha256 in `~/cloud-desktop-host` | copy `scripts/` and `configs/` with `tar` |
| Sunshine | `rpm -q sunshine` | `dnf install` (postinst errors about `modprobe`/`udevadm` are expected in a CT and ignored) |
| Sunshine caps | `getcap` on the real binary is empty | `setcap -r`. File caps set `AT_SECURE`, which breaks ENet, so Moonlight can't connect |
| Sunshine config | `~/.config/sunshine/sunshine.conf` and `apps.json` exist | write defaults: `capture=wlr`, `encoder=nvenc`, `gamepad=xone`, `system_tray=disabled`, `csrf_allowed_origins=https://<CT IP>:47990[,CSRF_EXTRA]`. **Never overwrites** existing files |
| RPM Fusion nonfree¹ | `rpm -q rpmfusion-nonfree-release` | install the release RPM |
| Steam + Gamescope + MangoHud¹ | `rpm -q` | `dnf install` |
| Gamescope caps¹ | `getcap` empty | `setcap -r` |

¹ only with `INSTALL_STEAM=1`.

---

## What it does not do

- Install or upgrade the **host** NVIDIA driver.
- **Reboot** the host. After enabling `modeset` it stops and asks you to reboot, then re-run.
- Set a password for the CT user: `pct exec <CTID> -- passwd user`.
- Start the stack or create a systemd service. Start it with `pct exec <CTID> -- runuser -l user -c '~/cloud-desktop-host/scripts/run.sh'`.
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
| `nvidia-drm modeset=1 configured: reboot` | expected on the first run on a fresh host |
| `CT is privileged or uses a custom lxc.idmap` | the script refuses rather than guess uid mappings |
| `nvidia-smi works in CT` fails | passthrough is missing, the CT wasn't restarted, or the host and CT driver versions differ |

For the background on each step (why the bind goes through `/mnt/host-udev`, why `sys_nice` is needed, the `AT_SECURE` bug), see the step-by-step guide this script automates.
