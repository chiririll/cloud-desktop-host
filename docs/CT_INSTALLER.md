# In-container installer: `pve/ct-install.sh`

Sets up CDH + KWin/Plasma + Sunshine (+ Steam/Gamescope) **inside** a container or VM. On Proxmox it is run for you by [`pve/install.sh`](PVE_INSTALLER.md); it also works on its own in any LXC, Incus, Docker container or VM. Supported: Fedora 43–45 and Ubuntu 26.04 (what has a release bundle).

Like the host script it is **idempotent** (check → apply → check again) and has `--check`. Unlike it, it is **non-interactive**: a `curl | bash` pipe has no tty, so everything comes from environment variables.

## Standalone use

The container must already have what only a host can give: `/dev/dri/renderD*`, `/dev/uinput`, `/dev/input/*`, the `/dev/nvidia*` nodes and the host's udev database (bind-mounted at `/mnt/host-udev`, or already at `/run/udev`). Also not done for you: the `sys_nice` cap override for KWin and a big enough `/dev/shm`. The LXC config block in [INSTALL_AND_CONFIG.md](INSTALL_AND_CONFIG.md) is that list.

```bash
# as root, prefer a tag over main
bash -c "$(curl -fsSL https://raw.githubusercontent.com/chiririll/cloud-desktop-host/v1.2.0/pve/ct-install.sh)" -- --check
CT_USER=user INSTALL_STEAM=1 bash -c "$(curl -fsSL …/v1.2.0/pve/ct-install.sh)"
```

The script ends with `main "$@"`, so a truncated download runs nothing. The release bundle it downloads is verified against `SHA256SUMS`. It installs `curl` first if the container has none.

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `CT_USER` | `user` | session user, created if missing |
| `INSTALL_STEAM` | `1` | Steam + Gamescope + MangoHud (RPM Fusion on Fedora, i386 + multiverse on Ubuntu) |
| `CDH_INPUT_ISOLATED` | `0` | `1`: the host gives this CT its own `/dev/input`, so the shared udev rule is removed. `keep`: leave the rule alone (other CTs still share `/dev/input`). `0`: install it |
| `CDH_GH_REPO`, `CDH_VERSION` | `chiririll/cloud-desktop-host`, latest | release source |
| `CDH_LOCAL_BUNDLE` | empty | directory with `cloud-desktop-host`, `scripts/`, `configs/` instead of a download |
| `SUNSHINE_PKG` | latest release asset for the distro | URL or file; `SUNSHINE_VERSION` pins a release |
| `CLOUD_MOUSE_PKG` | latest release for the distro, skipped with a warning if there is none | URL, file or `none` |
| `CSRF_EXTRA` | empty | extra Sunshine web UI origins |
| `INSTALL_UPDATE_TIMER` | `0` | `1`: weekly update timer |
| `CT_CDH` | `/opt/cloud-desktop-host` | scripts + configs |
| `LOG` | `/var/log/cdh-ct-install.log` | log of the apply commands |

Flags: `--check`, `--update`, `--force-restart` (with `--update`).

**Exit codes:** `0` done or nothing needed · `10` `--check`: steps needed (last line `NEEDED=<n>`) · `11` applied, the container must be restarted · `12` applied, the session was restarted (`--update`) · `1` a step failed · `2` usage or unsupported distro.

Facts the host script used to provide are read from inside: the NVIDIA driver version from `/sys/module/nvidia/version` (fallback `/proc/driver/nvidia/version`), the host uid of `CT_USER` from `/proc/self/uid_map`, the IP from `ip`.

## Steps

| Step | Check | Apply |
|---|---|---|
| curl + CA certificates | packages installed | install (the Fedora template has no curl) |
| Release | manifest readable / bundle downloaded and verified | `--check` only reads the manifest |
| Host udev db | `/run/udev/data` non-empty; with `/mnt/host-udev`, the fstab bind | add the fstab line, mount |
| Host udev rule | per `CDH_INPUT_ISOLATED` | write / remove `60-lxc-virtual-input.rules` |
| Packages | per-distro list (`ct/distro/<distro>.sh`) | `dnf` / `apt-get install`; a non-zero exit from a container-hostile postinst is not the verdict, the re-check is |
| User | exists, in `video`/`render`/`input` | `useradd`, add to the groups (+ `wheel` / `sudo`) |
| NVIDIA userspace | `libnvidia-glcore.so.<host version>` in `/usr/lib64` or `/usr/lib/x86_64-linux-gnu` | the matching `.run` with `--no-kernel-module --install-compat32-libs -s` |
| `nvidia-smi` | works | **stops** |
| Linger | `/var/lib/systemd/linger/$CT_USER` | `loginctl enable-linger` |
| CDH binary, scripts + configs | sha256 against the manifest | install; the previous binary is kept as `cloud-desktop-host.prev` |
| Sunshine | package installed (`--update`: latest or pinned release) | install the `.rpm` / `.deb` |
| Sunshine caps | no file caps | `setcap -r` (file caps set `AT_SECURE`, which breaks ENet) |
| Sunshine config | files exist | defaults, never overwritten |
| Cloud Mouse | package installed (`--update`: latest release) | install; skipped with a warning when the release has no build for the distro |
| Steam | repos (Fedora: RPM Fusion; Ubuntu: i386 + multiverse), packages, Gamescope without caps | install |
| User service | unit file content, enabled | write, enable |

On Ubuntu the Sunshine `.deb` must exist for the release (LizardByte may lag a new LTS); if not, the step fails with a hint to build it (`docs/BUILD.md`) and pass `SUNSHINE_PKG=<file>`. Cloud Mouse has an Ubuntu `.deb` release asset (`kcm-cloud-mouse-ubuntu2604-x86_64.deb`).

## Update mode

`--update` is the same step engine with the target moved to "latest":

1. **Distro packages** are upgraded first, so a Sunshine upgrade restoring its file caps is undone by the no-caps step that follows.
2. **Sunshine** and **Cloud Mouse** are compared with their latest release (`SUNSHINE_VERSION` pins one) and reinstalled on a mismatch.
3. **CDH bundle** as in a plain run (`CDH_VERSION` pins one); the old binary stays as `.prev` for rollback: `mv /usr/local/bin/cloud-desktop-host.prev /usr/local/bin/cloud-desktop-host`.
4. A **plain re-run already** handles host driver upgrades (NVIDIA userspace) and caps.
5. If anything changed, the session is **restarted** (`systemctl --user restart cloud-desktop-host.service`, exit 12), unless a client is streaming: then it only prints what changed (exit 0). `--force-restart` overrides.

"Client is streaming" is the file `$XDG_RUNTIME_DIR/cdh/stream-active`: `sunshine-prep-*.sh` create it, `sunshine-undo-*.sh` and a session start remove it.

`--check --update` lists what would change. With `INSTALL_UPDATE_TIMER=1` a systemd timer **inside the CT** runs the update weekly (Sunday 04:00 + up to 1 h); the streaming guard makes that safe. Its settings are in `/etc/cdh/ct-install.env`, the units fetch `ct-install.sh` of the configured release each time. From Proxmox: `install.sh --update` does its host steps and runs this with `--update`.
