#!/usr/bin/env bash
# Optional: make the Proxmox host's GPU/input setup survive a reboot.
#
# pve/install.sh only fixes the current boot (loads uinput, creates
# /dev/nvidia-uvm) and warns when that would be lost on reboot. This script
# writes the boot-time config. Skip it if you load these some other way.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/chiririll/cloud-desktop-host/main/pve/host-persist.sh)" -- --check
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/chiririll/cloud-desktop-host/main/pve/host-persist.sh)"
#   ./pve/host-persist.sh [--check]
#
# Writes:
#   /etc/modprobe.d/nvidia-drm.conf         options nvidia-drm modeset=1 (+ update-initramfs -u)
#   /etc/modules-load.d/uinput.conf         uinput
#   /etc/modules-load.d/nvidia-uvm.conf     nvidia_uvm
#   /etc/modules-load.d/cdh_input_guard.conf  cdh_input_guard (only if install.sh installed it for this kernel)
#   /etc/udev/rules.d/70-nvidia-uvm.rules   creates /dev/nvidia-uvm when the module loads
# Each step: check → (apply if needed) → check again. Safe to re-run.
set -euo pipefail

LOG=/var/log/cdh-lxc-install.log

CHECK_ONLY=0
case "${1:-}" in
  --check|-n) CHECK_ONLY=1 ;;
  "") ;;
  -h|--help) echo "usage: host-persist.sh [--check]"; exit 0 ;;
  *) echo "unknown option: $1 (use --check)"; exit 2 ;;
esac

if [[ -t 1 ]]; then
  GN=$'\e[32m' YW=$'\e[33m' RD=$'\e[31m' BL=$'\e[36m' DM=$'\e[2m' CL=$'\e[0m'
else GN='' YW='' RD='' BL='' DM='' CL=''; fi
msg_info() { printf ' %s…%s %s' "$YW" "$CL" "$1"; }
msg_ok()   { printf '\r\e[K %s✔%s %s%s%s\n' "$GN" "$CL" "$1" "$DM" "${2:+ ($2)}$CL"; }
msg_todo() { printf '\r\e[K %s◦%s %s %s(needed)%s\n' "$BL" "$CL" "$1" "$YW" "$CL"; }
msg_warn() { printf '\r\e[K %s!%s %s\n' "$YW" "$CL" "$1"; }
die()      { printf '\r\e[K %s✘%s %s\n' "$RD" "$CL" "$1"; exit 1; }
header()   { printf '\n%s── %s%s\n' "$BL" "$1" "$CL"; }
why()      { echo "$*"; return 1; }
show_why() { [[ -n $1 ]] && sed -n '1,8p' <<<"$1" | sed "s/^/     $DM/; s/\$/$CL/"; return 0; }

NEEDED=0
step() {
  local name=$1 check=$2 apply=$3 rc out
  if out=$($check 2>&1); then msg_ok "$name"; return 0; fi
  if ((CHECK_ONLY)); then msg_todo "$name"; show_why "$out"; NEEDED=$((NEEDED + 1)); return 0; fi
  msg_info "$name"
  printf '=== %s %s\n%s\n' "$(date -Is)" "$name" "$out" >>"$LOG"
  set +e; ( set -e; $apply ) >>"$LOG" 2>&1; rc=$?; set -e
  ((rc == 0)) || die "$name: failed (exit $rc), see $LOG"
  if ! out=$($check 2>&1); then
    printf '\r\e[K'; show_why "$out"; die "$name: still not satisfied after applying, see $LOG"
  fi
  msg_ok "$name" "done"
}

[[ $EUID -eq 0 ]] || die "run as root on the Proxmox host"
((CHECK_ONLY)) && echo "${YW}check mode: nothing will be changed${CL}"
header "Host: survive reboot"

# modeset=1 from modprobe.d or the kernel command line
modeset_now() { [[ "$(cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null)" == Y ]]; }
chk_modeset() {
  grep -qsE '^[[:space:]]*options[[:space:]]+nvidia[-_]drm[[:space:]].*modeset=1' /etc/modprobe.d/*.conf && return 0
  grep -qE '(^| )nvidia[-_]drm\.modeset=1( |$)' /proc/cmdline && return 0
  why "modeset=1 not in /etc/modprobe.d or the kernel command line"
}
do_modeset() { echo "options nvidia-drm modeset=1" >/etc/modprobe.d/nvidia-drm.conf; update-initramfs -u; }
step "nvidia-drm modeset=1 at boot" chk_modeset do_modeset

mod_persisted() { # any file, so a missing /etc/modules doesn't make grep fail
  local f; for f in /etc/modules /etc/modules-load.d/*.conf; do grep -qsxE "[[:space:]]*$1[[:space:]]*" "$f" && return 0; done; return 1
}

chk_uinput() { mod_persisted uinput || why "uinput not in /etc/modules-load.d"; }
do_uinput()  { echo uinput >/etc/modules-load.d/uinput.conf; modprobe uinput; }
step "uinput loaded at boot" chk_uinput do_uinput

UVM_RULE=/etc/udev/rules.d/70-nvidia-uvm.rules
UVM_RULE_TXT='KERNEL=="nvidia_uvm", RUN+="/usr/bin/nvidia-modprobe -c0 -u"'
chk_uvm() {
  local r=0
  mod_persisted nvidia_uvm || { echo "nvidia_uvm not in /etc/modules-load.d"; r=1; }
  grep -qsE 'nvidia-modprobe.* -u' /etc/udev/rules.d/*.rules || { echo "no udev rule creating /dev/nvidia-uvm"; r=1; }
  return $r
}
do_uvm() {
  mod_persisted nvidia_uvm || echo nvidia_uvm >/etc/modules-load.d/nvidia-uvm.conf
  grep -qsE 'nvidia-modprobe.* -u' /etc/udev/rules.d/*.rules || echo "$UVM_RULE_TXT" >"$UVM_RULE"
  udevadm control --reload
  modprobe nvidia_uvm
  nvidia-modprobe -c0 -u
}
step "nvidia-uvm module + device node at boot" chk_uvm do_uvm

# the module itself is installed by install.sh; without it for this kernel, modules-load.d would only log an error
GUARD_LOAD=/etc/modules-load.d/cdh_input_guard.conf
chk_guard() { mod_persisted cdh_input_guard || why "cdh_input_guard not in /etc/modules-load.d"; }
do_guard()  { echo cdh_input_guard >"$GUARD_LOAD"; }
if [[ -f /lib/modules/$(uname -r)/extra/cdh_input_guard.ko ]]; then
  step "cdh_input_guard loaded at boot" chk_guard do_guard
else
  msg_warn "cdh_input_guard.ko not installed for $(uname -r): run pve/install.sh first to load it at boot"
fi

echo
if ((CHECK_ONLY)); then
  ((NEEDED)) && echo "${YW}$NEEDED step(s) needed.${CL} Run without --check to apply." \
             || echo "${GN}Everything is in place.${CL}"
else
  echo "${GN}Done.${CL} Log: $LOG"
fi
modeset_now || msg_warn "nvidia-drm modeset is not active yet: reboot the host"
exit 0
