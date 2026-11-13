# Input isolation: kernel module plan

Status: plan. Nothing here is implemented. The module design comes from reading the kernel input core, not from a build. Items marked **unverified** must be confirmed in phase 1 before anything else is built on them.

This replaces the "Options" and "Proposed order" sections of [06_input_isolation_plan.md](06_input_isolation_plan.md). The problem description there still stands.

## Decision

1. Host mitigation now: mask Ctrl+Alt+Del, disable SysRq, keep logind away from virtual input devices.
2. A small host kernel module, `cdh_input_guard`, that keeps virtual input devices away from the host console and records which container created each one.
3. A host udev rule and helper that put each device node only into its own container's `/dev/input`.
4. Fallback if the module does not work: a host CUSE proxy in front of `/dev/uinput`.

Sunshine, Steam and CDH stay unchanged. The container keeps the real `/dev/uinput`.

## Why not the options from 06

- **Option A (FUSE file inside the container): ruled out by test.** A plain FUSE file was driven with the calls libevdev makes (kernel 7.0). `UI_SET_EVBIT`, `UI_SET_KEYBIT` and the other `UI_SET_*BIT` calls fail with `EFAULT` and never reach the FUSE server. They pass an int by value, and FUSE treats the argument as a pointer. `UI_SET_PHYS` delivers only 8 bytes of the string. Only CUSE receives raw ioctl arguments, and CUSE cannot be served from an unprivileged container.
- **Option B (CUSE with full uinput emulation):** works in principle, but needs a uinput emulation, a rumble proxy and a new input path in CDH.
- **Option C (detect and grab):** leaves a short window before the grab and needs `pidfd_getfd` introspection to find the owner. The module gives the owner directly and has no window.
- **Forking evdev or uinput into a module:** gives isolation without udev, but it is over a thousand lines of forked kernel code to keep in sync.

## How the module works

`cdh_input_guard` registers an input handler that matches virtual devices, meaning input devices with no parent device. This is what uinput creates and what the current udev rule matches as `/devices/virtual/input/*`. USB and BMC keyboards have a parent and are not touched.

In its `connect()` callback the module does two things:

1. **Detach every handler except evdev and joydev.** It walks the device's handle list and calls `disconnect()` on all other handles (`kbd`, `sysrq`, `rfkill`, `mousedev`, `leds`, ...). This is the call the input core makes when a device is removed. `/dev/input/event*` and `js*` work as before. Handlers that register after the module are caught by a periodic sweep (see the module README).
2. **Record the owner.** `connect()` runs inside the `UI_DEV_CREATE` ioctl, so `current` is the process that created the device. The module stores that process's cgroup path, exposes it as a root-only sysfs attribute on the input device, and sends a `change` uevent so udev runs after the attribute exists.

Devices created through uhid are detached the same way but get no owner, because uhid registers them from a workqueue. The container is not given `/dev/uhid` today.

The module only covers kernel handlers. evdev stays attached, so host userspace can still read the devices; logind is handled by a udev rule in phase 0.

Properties this should give:

- No window. uinput rejects `write()` until `UI_DEV_CREATE` returns, and by then the console handlers are detached.
- Covers every uinput client (Sunshine, Steam Input, anything else), and every device type. A device that claims to be a gamepad but declares Ctrl, Alt and Del is handled the same way.
- No state to keep in sync afterwards. `EVIOCGRAB` and device removal behave normally.

**Unverified:**

- `kbd` and `sysrq` are built in and registered before the module, so their handles already exist when our `connect()` runs.
- Calling another handler's `disconnect()` from inside `connect()` is safe. Both run under `input_mutex` in the core.
- Calling `disconnect()` on the other handlers that attach on the PVE kernel (`rfkill`, `mousedev`, `leds`) is as safe as for `kbd` and `sysrq`. The module now detaches everything except evdev and joydev.
- Re-registering the detach handler every second (the sweep) causes no trouble on a busy host.
- The sysfs attribute plus `change` uevent is the simplest way to hand the owner to udev. A small child device with its own uevent variables is the alternative.

Two designs that look simpler and do not work:

- A filter handler. A filter that swallows an event hides it from all later handlers, including evdev, so the container gets nothing.
- An in-kernel grab. A grab is exclusive to one handle. Grabbing with the module's own handle starves evdev. Grabbing on evdev's handle is released when the last reader closes the node.

Limits to accept:

- Devices that already exist when the module loads get their console handlers detached, but the owner is unknown (`current` is `modprobe`). The module must load at boot, before any container starts.
- Unloading the module does not re-attach `kbd` to existing devices. New devices are unprotected until it is loaded again.

## Per-container `/dev/input`

Today every container bind-mounts the host's whole `/dev/input`, and one udev rule gives every virtual device the same owner. The rule file holds a single uid, so installing a second container whose user has a different uid breaks input in the first.

New layout:

- Host directory `/run/cdh/input/<ctid>/`, created by a `tmpfiles.d` entry so it exists before the container starts.
- Container config: replace `lxc.mount.entry: /dev/input dev/input …` in `pve/install-parts/71-phase-container.sh` with a bind mount of that directory. Keep `lxc.cgroup2.devices.allow: c 13:* rwm`. The installer must also remove the old line from existing containers; `missing_raw` only adds lines.
- Udev rule replacing `60-lxc-virtual-input.rules` in `pve/install-parts/72-phase-inside.sh`. For each `event*` and `js*` node of a device that has the owner attribute, it runs a helper.
- Helper `cdh-input-node add|remove`:
  - Reads the cgroup path from sysfs itself and extracts the container id from a match of `^/lxc/([0-9]+)/` at the start. The rest of the path is named by the container and may contain spaces or a segment like `lxc/102`, so it must not go through `$attr{}` substitution in the udev rule, and a path that does not match is ignored.
  - Reads the owner uid for that container from a per-container file written by the installer (`100000 + uid`).
  - Creates the node under a temporary name, sets owner and mode `0600`, then renames it to `eventN`. CDH's inotify watch already handles `IN_MOVED_TO` and ignores names that do not start with `event`.
  - On `remove`, deletes the node.

The container cannot create device nodes itself and sees only its own, so it cannot open another container's keyboard, mouse or gamepad.

What stays visible: device names of other containers through `/sys` and the read-only `/run/udev` bind mount. No events.

No change expected in CDH. The path backend in `src/input.cpp` keeps watching `/dev/input`, and libinput finds udev properties by device number, not by path. **Unverified** until tested.

## Phases

### Phase 0: host mitigation (do now)

```
systemctl mask ctrl-alt-del.target
mkdir -p /etc/systemd/system.conf.d
printf '[Manager]\nCtrlAltDelBurstAction=none\n' > /etc/systemd/system.conf.d/10-cdh-no-cad.conf
systemctl daemon-reexec
echo 'kernel.sysrq = 0' > /etc/sysctl.d/99-cdh-no-sysrq.conf
sysctl --system
cp ../cdh-input-guard/udev/71-cdh-virtual-input.rules /etc/udev/rules.d/
udevadm control --reload
```

The udev rule removes the `power-switch` tag from virtual input devices. Without it logind opens every container keyboard and acts on `KEY_POWER`, `KEY_SLEEP`, `KEY_SUSPEND` and the lid switch, so a container can power off or suspend the host.

- Add as a `step` in `phase_host` (`pve/install-parts/70-phase-host.sh`), then run `pve/build.sh`.
- This is persistent host config, which `install.sh` otherwise leaves to `pve/host-persist.sh`. It is a safety fix, so it belongs in the main installer. Decide before implementing.
- Stays in place after the module ships, as a backstop.
- Done when: Ctrl+Alt+Del in the stream no longer reboots the host, including seven presses within two seconds, and `KEY_POWER` from a uinput device does not power it off.

### Phase 1: module prototype in a VM

- Throwaway VM running the same PVE kernel as production. Not the production host: a bug here panics the machine.
- Write `cdh_input_guard` (separate repo `../cdh-input-guard/`) and resolve every **unverified** item in "How the module works".
- Done when, for a device created through uinput:
  - `grep -A6 <name> /proc/bus/input/devices` shows only `event*`, `js*` and `cdh_input_guard` in `Handlers`.
  - Typing into the device shows nothing at the VM's tty1 login prompt, Ctrl+Alt+F2 does not switch VT, and Ctrl+Alt+Del does not reboot with the phase 0 mask removed.
  - `evtest` on the event node still receives the keys.
  - The owner attribute shows the creating container's cgroup.
  - Creating and destroying devices in a loop, and loading and unloading the module, leave no warnings in `dmesg`.
- If detaching does not work or is not stable, stop and go to the fallback.

### Phase 2: per-container `/dev/input`

- Implement the directory, the container config change, the udev rule and the helper as described above.
- Done when, with two containers running:
  - `ls /dev/input` in each shows only its own devices.
  - Typing in container A produces no events in container B.
  - Keyboard, mouse and gamepad work in both, including rumble and Steam detecting the gamepad.
  - Input comes back after a Sunshine reconnect, a CDH restart and a container restart.

### Phase 3: packaging and installer

- DKMS package for the module. Needs the PVE kernel headers on the host. The host already builds the NVIDIA module this way.
- If Secure Boot is on (`mokutil --sb-state`), the DKMS signing key must be enrolled.
- `phase_host`: a `require` that the module is loaded, so a failed rebuild after a kernel update is noticed and not silent.
- `pve/host-persist.sh`: load the module at boot through `/etc/modules-load.d`, same as `uinput`.
- Update `docs/PVE_INSTALLER.md` and `docs/INSTALL_AND_CONFIG.md`.
- Done when: a fresh install and an upgrade of an existing container both end with phase 1 and phase 2 checks passing, and a host kernel update rebuilds the module.

### Phase 4: retest per kernel series

The module relies on input core behaviour that is not a stable interface. Repeat the phase 1 checks on every PVE kernel series before upgrading production.

## Fallback: host CUSE proxy

Use this only if phase 1 fails.

- One CUSE device per container on the host, passed into the container as `/dev/uinput`. The real `/dev/uinput` stays on the host.
- The proxy forwards every ioctl and write one for one to the real uinput. No emulation, so rumble and sysfs lookups work.
- For keyboards and mice it opens the new event node, takes `EVIOCGRAB`, and only then forwards the first event. It keeps the grabbed fd and passes a duplicate to CDH over a unix socket, so the grab survives a CDH restart.
- It knows the owning container by construction and fills the same per-container `/dev/input`, so phase 2 is reused.
- Cost: a root service on the host that sits in the input path, a change to `open_restricted` in `src/input.cpp`, and the `cuse` module on the PVE kernel (**unverified**).

## Risks

| Risk | Handling |
|---|---|
| Module bug panics the host and all containers | Prototype only in a VM; keep the module small |
| Kernel update changes input core internals | Phase 4 retest; fallback exists |
| Module fails to build after a kernel update, protection disappears | Installer `require`; phase 0 mitigation stays |
| Module loads after containers start, owner unknown | Load at boot through `modules-load.d` |
| Tenant floods the host with uinput devices | Not addressed here; the real `/dev/uinput` stays reachable |

## Open questions

- Do tenants get a shell or root in their container? For a trusted desktop, phases 0 and 2 matter most; for hostile tenants, the device flood risk and the visible device names need a decision.
- Is Secure Boot enabled on the production host?
- Which PVE kernel series must be supported?
- Phase 0 in `install.sh` or in `host-persist.sh`?
