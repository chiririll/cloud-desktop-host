# Input isolation plan

Status: proposal, partly superseded. Option A was tested and does not work on plain FUSE. The chosen approach and the order of work are in [07_input_isolation_kmod_plan.md](07_input_isolation_kmod_plan.md). The problem description below still stands. Items marked **unverified** are assumptions.

## Problem

Sunshine creates its virtual keyboard, mouse and gamepads through `/dev/uinput`. A uinput device is a real kernel input device, global to the host. There is no input namespace. Findings so far:

1. **Host console receives the keys.** The kernel VT keyboard handler (`kbd`) attaches to every keyboard device, including uinput ones. If the Proxmox host sits on a text VT (getty on tty1), keys typed in the stream reach it:
   - Ctrl+Alt+Del reboots the Proxmox host (confirmed in practice).
   - Ctrl+Alt+Fn and Alt+Left/Right switch the host VT.
   - Alt+SysRq+key can run SysRq actions, depending on `kernel.sysrq`.
   - Text typed in the stream (including passwords) lands at the host login prompt, where it can end up in auth logs (**unverified**; check `journalctl -u getty@tty1`).
2. **Containers see each other's devices.** `pve/install.sh` bind-mounts the whole host `/dev/input` into every container (line ~454), and the udev rule in `pve/install-parts/72-phase-inside.sh` gives every virtual device the same owner (`100000 + uid`). So every CDH can open every container's keyboard and mouse:
   - Typing in container A is injected into container B's desktop.
   - Container A can read container B's keystrokes.

Related finding, already fixed: `kwin_wayland --no-global-shortcuts` disabled the Super key. Removing it in `scripts/sunshine-prep-desktop.sh` and `scripts/run.sh` was enough.

## Immediate mitigation (host side, small, do first)

Run on the Proxmox host and add as an installer step next to the udev rule step:

```
systemctl mask ctrl-alt-del.target
sed -i 's/^#\?CtrlAltDelBurstAction=.*/CtrlAltDelBurstAction=none/' /etc/systemd/system.conf
systemctl daemon-reexec
echo 'kernel.sysrq = 0' > /etc/sysctl.d/99-no-sysrq.conf && sysctl --system
```

Do not disable the host gettys. Losing the physical console makes recovery harder.

Check whether Sunshine's device reaches the console handler: `grep -B1 -A6 -i sunshine /proc/bus/input/devices` and look for `kbd` in the Handlers line.

This stops the reboot and SysRq. It does not stop VT switching or text reaching the login prompt, and it does not fix the cross-container problem.

## Design goal

Keyboard and mouse input from Sunshine should never become a kernel input device. Gamepads must stay real kernel devices, because Steam and gamescope read them through evdev and udev.

A chroot or mount namespace cannot do this on its own. It only decides which files a process sees. `/dev/uinput` behaves according to the kernel driver, so the real node always creates a global device. The fix is to put a different file at `/dev/uinput`, one whose behaviour is implemented in userspace.

## Options

### Option A: CDH hosts a fake `/dev/uinput` with FUSE inside the container (preferred)

- CDH mounts a small FUSE filesystem and bind-mounts one file from it over `/dev/uinput`.
- Sunshine opens it normally. Setup calls (`UI_SET_EVBIT`, `UI_SET_KEYBIT`, `UI_DEV_SETUP`, `UI_DEV_CREATE`) are recorded in memory.
- For keyboard and mouse, CDH parses `write(input_event)` and injects events straight into its seat. No kernel device exists, so nothing reaches the host console or other containers, and there is no race window.
- For gamepads, CDH forwards setup calls and events one for one to a real `/dev/uinput`, including force-feedback upload for rumble. Steam sees a real device.
- No host service. Needs `/dev/fuse` and FUSE mounts in the unprivileged container (LXC `fuse` feature).
- **Unverified:** whether FUSE passes the uinput ioctls through on a regular file. Normally only CUSE does fully general ioctl handling. The uinput ioctls encode their size (`_IOW`, `_IOR`), so restricted ioctls may be enough.
- **Unverified:** whether Sunshine's input library tolerates a device with no `/sys/devices/virtual/input/...` node. If it looks the node up after creation, keyboard and mouse might fail.

### Option B: per-container CUSE node on the host

- One CUSE proxy per container on the host, for example `/dev/uinput-ct105`, passed into the container as `/dev/uinput` through the existing `devN` entry (`pve/install.sh`, ~line 499).
- Same split as A: keyboard and mouse are forwarded to that container's CDH over a socket, gamepads go to the real uinput.
- Ownership is known by construction. Avoids the FUSE ioctl question but adds a root service on the host and needs CUSE unrestricted-ioctl handling.

### Option C: detect and grab (fallback, smaller)

- A root daemon on the host watches for new virtual input devices.
- For each device it finds the owning container: duplicate Sunshine's `/dev/uinput` fd with `pidfd_getfd`, run `UI_GET_SYSNAME` on it, and read the process cgroup.
- For keyboard and mouse it opens the node, calls `EVIOCGRAB`, and passes the open fd to the container's CDH over a unix socket. The grab belongs to the open file, so it survives the fd passing. While grabbed, events do not reach the VT handler.
- It `mknod`s the node into `/run/cdh/input/<ctid>/` and bind-mounts that directory as the container's `/dev/input`.
- Gap of a few milliseconds between device creation and grab. Host mask plus `sysrq=0` covers it.
- Needs the container device cgroup to allow char major 13. **Unverified**; the current bind mount suggests it does.

### Not recommended

- A bare `EVIOCGRAB` in CDH's `open_restricted` (`src/input.cpp:62`). With several containers, whichever CDH opens a device first holds the grab, and others get `EBUSY` and silently lose input.
- Faking Steam's gamepads with CUSE. Steam needs real evdev nodes, per-container udev entries, and hotplug notification, which an unprivileged container does not receive.
- `LD_PRELOAD` shim in front of Sunshine. Lighter, but only works if all calls go through libc, and it does not protect against another process opening the real `/dev/uinput`.

## Isolation each option gives

| | Keyboard/mouse reach host console | Cross-container keystroke leak | Gamepad nodes visible to other containers |
|---|---|---|---|
| Host mask only | no reboot, but VT switch and login prompt text remain | yes | yes |
| A (FUSE in container) | no | no | yes, until a per-container `/dev/input` directory is added |
| B (CUSE per container) | no | no | no, with per-container `/dev/input` |
| C (detect and grab) | no, except a short window | no | no |

For a hostile tenant, the real `/dev/uinput` must be reachable only by CDH, not by the user's processes, and `/dev/input` must be per-container.

## Proposed order

1. Add the host mask and `sysrq=0` to the installer. Check the Sunshine device's Handlers line and the tty1 login prompt for leaked text.
2. Prototype Option A in the scratchpad: a FUSE file that a test program can drive with `UI_SET_EVBIT`, `UI_DEV_SETUP`, `UI_DEV_CREATE`, `write()`. Confirm the ioctls pass through.
3. Check whether Sunshine tolerates a keyboard or mouse with no sysfs node. Read Sunshine's input code path.
4. If both pass, build it into CDH: keyboard and mouse in memory, gamepads forwarded to the real uinput.
5. Add a per-container `/dev/input` directory to close the remaining gamepad visibility.
6. If step 2 or 3 fails, fall back to Option C (or B).

## Open questions

- Do tenants get a shell or root inside their container, or is it a trusted desktop? This decides between the cooperative fix (A without step 5) and hard isolation.
- Is the Proxmox host actually sitting on a text VT with a getty, and does anyone use that console?
- Does the container device cgroup already allow `c 13:*`?
