#!/usr/bin/env bash
# cloud-desktop-host in an unprivileged Proxmox LXC: idempotent installer.
#
# Run on the Proxmox host as root. Binary, scripts and configs come from the
# GitHub release (built by .github/workflows/release.yml), unless run from a
# repo checkout that has dist/cloud-desktop-host (docker build -o dist .).
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/chiririll/cloud-desktop-host/main/pve/install.sh)" -- --check
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/chiririll/cloud-desktop-host/main/pve/install.sh)"
#   ./pve/install.sh [--check] [--fedora 44]   # from a checkout
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
#   FEDORA=43|44|45   Fedora release of the CT (same as --fedora; asked when creating a CT,
#                     an existing running CT is detected). Must have a release bundle.
#   INSTALL_STEAM=1|0   Steam + Gamescope + MangoHud (asked; default yes without a tty)
#   YES=1   don't ask for confirmation before changing an existing CT
#   NVIDIA_PCI=0000:01:00.0   pick the GPU if there are several NVIDIA cards
#   CDH_VERSION=v1.0.0   use this release (default: local dist/, else latest)
#   CDH_GH_REPO=chiririll/cloud-desktop-host   SUNSHINE_RPM=<url or local .rpm>
#   CLOUD_MOUSE_RPM=<url or local .rpm>   (default: latest kcm-cloud-mouse release for the Fedora version, skipped with a warning if there is none; "none" to skip)
#   CSRF_EXTRA=https://gaming.example.org   extra Sunshine web UI origins
set -euo pipefail
