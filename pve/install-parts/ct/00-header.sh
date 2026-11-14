#!/usr/bin/env bash
# cloud-desktop-host inside a container or VM: idempotent, NON-interactive installer.
#
# This is the in-container half of pve/install.sh (which pushes it into the CT and runs it), but it
# also works on its own in any LXC/Incus/Docker/VM that already has what only a host can give:
# a render node (/dev/dri/renderD*), /dev/uinput, /dev/input/*, /dev/nvidia* and the host's udev
# database at /run/udev (or bind-mounted at /mnt/host-udev). Run as root:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/chiririll/cloud-desktop-host/v1.2.0/pve/ct-install.sh)" -- --check
#   CT_USER=user INSTALL_STEAM=1 bash -c "$(curl -fsSL …/ct-install.sh)"
#   … -- --update            # bring everything to the latest version (see below)
#
# Prefer a tag in the URL over main. The release bundle it then downloads is verified by SHA256SUMS.
#
# Nothing is asked: a `curl | bash` pipe has no tty. Settings come from the environment:
#   CT_USER=user            session user, created if missing
#   INSTALL_STEAM=1         Steam + Gamescope + MangoHud
#   CDH_INPUT_ISOLATED=0    1: the host gives this CT its own /dev/input (cdh_input_guard), so the shared
#                           udev rule for virtual input is removed; keep: leave that rule alone; 0: install it
#   CDH_GH_REPO=chiririll/cloud-desktop-host   CDH_VERSION=v1.2.0   (empty = latest release)
#   CDH_LOCAL_BUNDLE=<dir>  use <dir>/{cloud-desktop-host,scripts,configs} instead of a download
#   SUNSHINE_PKG=<url|file> Sunshine package (empty = latest release asset for this distro)
#   SUNSHINE_VERSION=<tag>  pin a Sunshine release
#   CLOUD_MOUSE_PKG=<url|file|none>   KCM Cloud Mouse (empty = latest for this distro, skipped if there is none)
#   CSRF_EXTRA=https://gaming.example.org   extra Sunshine web UI origins
#   INSTALL_UPDATE_TIMER=1  weekly systemd timer that runs this script with --update
#   CT_CDH=/opt/cloud-desktop-host   LOG=/var/log/cdh-ct-install.log
#
# Flags: --check (report only), --update, --force-restart (with --update).
#
# Exit codes: 0 done / nothing needed; 10 --check found steps needed (last line: NEEDED=<n>);
#   11 applied, the container must be restarted; 12 applied, the user session was restarted (--update);
#   1 a step failed; 2 usage or unsupported distro.
set -euo pipefail
