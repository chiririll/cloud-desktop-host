#!/usr/bin/env bash
# cloud-desktop-host in an unprivileged Proxmox LXC: idempotent installer.
#
# Run on the Proxmox host as root. This script does the HOST half (driver, modules,
# input guard, the LXC and its config); everything inside the container is done by
# pve/ct-install.sh, which this script pushes into the CT and runs there (it can also
# be run on its own in any container/VM, see its header). Binary, scripts and configs
# come from the GitHub release (built by .github/workflows/release.yml), unless run from
# a repo checkout that has dist/cloud-desktop-host (docker build -o dist .).
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/chiririll/cloud-desktop-host/main/pve/install.sh)" -- --check
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/chiririll/cloud-desktop-host/main/pve/install.sh)"
#   ./pve/install.sh [--check] [--update] [--distro ubuntu-26.04]   # from a checkout
#
# --update brings everything to the latest version (packages, Sunshine, Cloud Mouse, CDH
# bundle) and restarts the session if no client is connected; --force-restart restarts anyway.
#
# Every step: check → (apply if needed) → check again. Safe to re-run any time,
# e.g. after a host driver update or when /dev/dri/cardN got renumbered.
#
# The container ID is asked interactively (or set CTID=… for unattended runs).
# Creation settings are asked only when a new CT is about to be created.
#
# Settings (env vars, all optional when run interactively):
#   CTID  CT_HOSTNAME  CT_STORAGE  CT_DISK  CT_CORES  CT_MEMORY  CT_BRIDGE
#   CT_IP=dhcp|192.168.1.50/24   CT_GATEWAY=192.168.1.1   (static address; gateway asked/guessed from the host's route)
#   TEMPLATE_STORAGE=local  CT_USER=user  SHM_SIZE=4G
#   DISTRO=fedora-43|fedora-44|fedora-45|ubuntu-26.04   distro of the CT (same as --distro; asked when
#                     creating a CT, an existing running CT is detected). Must have a release bundle.
#                     FEDORA=44 / --fedora 44 still work (= fedora-44).
#   INSTALL_STEAM=1|0   Steam + Gamescope + MangoHud (asked; default yes without a tty)
#   YES=1   don't ask for confirmation before changing an existing CT
#   NVIDIA_PCI=0000:01:00.0   pick the GPU if there are several NVIDIA cards
#   CDH_VERSION=v1.0.0   use this release (default: local dist/, else latest)
#   CDH_GH_REPO=chiririll/cloud-desktop-host   SUNSHINE_PKG=<url or local .rpm/.deb>   SUNSHINE_VERSION=<tag>
#   CLOUD_MOUSE_PKG=<url or local .rpm/.deb>   (default: latest kcm-cloud-mouse release for the distro, skipped with a warning if there is none; "none" to skip)
#   (SUNSHINE_RPM / CLOUD_MOUSE_RPM are accepted as old names)
#   INSTALL_UPDATE_TIMER=1   weekly systemd timer inside the CT that runs ct-install.sh --update
#   INSTALL_INPUT_GUARD=0   don't install the cdh_input_guard host kernel module (default 1).
#                     Without it the CT shares the host's /dev/input with every other such CT.
#   CDH_GUARD_REPO, CDH_GUARD_VERSION   where the module release comes from
#   CSRF_EXTRA=https://gaming.example.org   extra Sunshine web UI origins
set -euo pipefail
