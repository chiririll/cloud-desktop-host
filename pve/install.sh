#!/usr/bin/env bash
# cloud-desktop-host in an unprivileged Proxmox LXC: idempotent installer.
#
# Run on the Proxmox host as root. Binary, scripts and configs come from the
# GitHub release (built by .github/workflows/release.yml), unless run from a
# repo checkout that has dist/cloud-desktop-host (docker build -o dist .).
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/chiririll/cloud-desktop-host/main/pve/install.sh)" -- --check
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/chiririll/cloud-desktop-host/main/pve/install.sh)"
#   ./pve/install.sh [--check]        # from a checkout
#
# Every step: check → (apply if needed) → check again. Safe to re-run any time,
# e.g. after a host driver update or when /dev/dri/cardN got renumbered.
#
# Settings (env vars):
#   CTID=180  CT_HOSTNAME=gaming  CT_STORAGE=local-lvm  CT_DISK=64  CT_CORES=8
#   CT_MEMORY=16384  CT_BRIDGE=vmbr0  TEMPLATE_STORAGE=local  FEDORA=43
#   CT_USER=user  INSTALL_STEAM=1  SHM_SIZE=4G
#   NVIDIA_PCI=0000:01:00.0   pick the GPU if there are several NVIDIA cards
#   CDH_VERSION=v0.1.0   use this release (default: local dist/, else latest)
#   CDH_GH_REPO=chiririll/cloud-desktop-host   SUNSHINE_RPM=<url or local .rpm>
#   CSRF_EXTRA=https://gaming.example.org   extra Sunshine web UI origins
set -euo pipefail

CTID=${CTID:-180}
CT_HOSTNAME=${CT_HOSTNAME:-gaming}
CT_STORAGE=${CT_STORAGE:-local-lvm}
CT_DISK=${CT_DISK:-64}
CT_CORES=${CT_CORES:-8}
CT_MEMORY=${CT_MEMORY:-16384}
CT_BRIDGE=${CT_BRIDGE:-vmbr0}
TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-local}
FEDORA=${FEDORA:-43}
CT_USER=${CT_USER:-user}
INSTALL_STEAM=${INSTALL_STEAM:-1}
SHM_SIZE=${SHM_SIZE:-4G}
NVIDIA_PCI=${NVIDIA_PCI:-}
CSRF_EXTRA=${CSRF_EXTRA:-}

CDH_GH_REPO=${CDH_GH_REPO:-chiririll/cloud-desktop-host}
CDH_VERSION=${CDH_VERSION:-}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]:-.}")/.." && pwd)
CDH_BIN=$REPO/dist/cloud-desktop-host
SUNSHINE_RPM=${SUNSHINE_RPM:-https://github.com/LizardByte/Sunshine/releases/latest/download/sunshine-fedora-${FEDORA}-amd64.rpm}
CT_HOME=/home/$CT_USER
CT_CDH=$CT_HOME/cloud-desktop-host
CONF=/etc/pve/lxc/$CTID.conf
LOG=/var/log/cdh-lxc-install.log

CT_PACKAGES=(dbus-daemon dbus-tools dbus-x11 pipewire wireplumber pipewire-pulseaudio
  pipewire-utils xorg-x11-server-Xwayland kwin plasma-desktop grim curl libcap xprop)

CHECK_ONLY=0
case "${1:-}" in
  --check|-n) CHECK_ONLY=1 ;;
  "") ;;
  -h|--help) echo "usage: install.sh [--check]   (settings: see the script header)"; exit 0 ;;
  *) echo "unknown option: $1 (use --check)"; exit 2 ;;
esac

# ── output, community-scripts style ────────────────────────────
if [[ -t 1 ]]; then
  GN=$'\e[32m' YW=$'\e[33m' RD=$'\e[31m' BL=$'\e[36m' DM=$'\e[2m' CL=$'\e[0m'
else GN='' YW='' RD='' BL='' DM='' CL=''; fi
msg_info() { printf ' %s…%s %s' "$YW" "$CL" "$1"; }
msg_ok()   { printf '\r\e[K %s✔%s %s%s%s\n' "$GN" "$CL" "$1" "$DM" "${2:+ ($2)}$CL"; }
msg_todo() { printf '\r\e[K %s◦%s %s %s(needed)%s\n' "$BL" "$CL" "$1" "$YW" "$CL"; }
msg_warn() { printf '\r\e[K %s!%s %s\n' "$YW" "$CL" "$1"; }
die()      { printf '\r\e[K %s✘%s %s\n' "$RD" "$CL" "$1"; exit 1; }
header()   { printf '\n%s── %s%s\n' "$BL" "$1" "$CL"; }

NEEDED=0
RESTART_CT=0
APPLIED=0   # set by step() when it changed something
# step "description" check_fn apply_fn
step() {
  local name=$1 check=$2 apply=$3 rc
  APPLIED=0
  if $check >/dev/null 2>&1; then msg_ok "$name"; return 0; fi
  if ((CHECK_ONLY)); then msg_todo "$name"; NEEDED=$((NEEDED + 1)); return 0; fi
  msg_info "$name"
  echo "=== $(date -Is) $name" >>"$LOG"
  set +e; ( set -e; $apply ) >>"$LOG" 2>&1; rc=$?; set -e
  ((rc == 0)) || die "$name: failed (exit $rc), see $LOG"
  $check >/dev/null 2>&1 || die "$name: still not satisfied after applying, see $LOG"
  APPLIED=1
  msg_ok "$name" "done"
}
# check-only step: nothing we can safely automate
require() {
  local name=$1 check=$2 hint=$3
  $check >/dev/null 2>&1 && { msg_ok "$name"; return 0; }
  ((CHECK_ONLY)) && { msg_todo "$name: $hint"; NEEDED=$((NEEDED + 1)); return 0; }
  die "$name: $hint"
}

ct()      { pct exec "$CTID" -- "$@"; }
ct_ip()   { ct ip -4 -o addr show dev eth0 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4; exit}'; }
ct_sh()   { pct exec "$CTID" -- bash -c "$1"; }
ct_user() { pct exec "$CTID" -- runuser -l "$CT_USER" -c "$1"; }
ct_up()   { [[ "$(pct status "$CTID" 2>/dev/null)" == "status: running" ]]; }
ct_gid()  { ct getent group "$1" | cut -d: -f3; }

# ── GPU discovery ──────────────────────────────────────────────
drm_node() { # $1 = card|renderD → /dev/dri/<node> of the chosen NVIDIA GPU
  local d n
  for d in /sys/class/drm/"$1"*; do
    n=${d##*/}; [[ $n =~ ^$1[0-9]+$ ]] || continue
    [[ "$(cat "$d/device/vendor" 2>/dev/null)" == 0x10de ]] || continue
    [[ -z $NVIDIA_PCI || "$(basename "$(readlink -f "$d/device")")" == "$NVIDIA_PCI" ]] || continue
    echo "/dev/dri/$n"; return 0
  done
  return 1
}
nvidia_minor() { # /dev/nvidiaN of the chosen GPU
  local pci=${NVIDIA_PCI:-$(basename "$(readlink -f "/sys/class/drm/$(basename "$(drm_node card)")/device")")}
  local m; m=$(awk '/^Device Minor:/{print $3}' "/proc/driver/nvidia/gpus/$pci/information" 2>/dev/null)
  echo "${m:-0}"
}
host_driver() { cat /sys/module/nvidia/version 2>/dev/null; }

# ── release bundle: cdh/{cloud-desktop-host,scripts,configs,pve} ──
fetch_release() {
  local asset="cdh-fc$FEDORA-x86_64.tar.gz" base tmp
  if [[ -z $CDH_VERSION || $CDH_VERSION == latest ]]; then
    base="https://github.com/$CDH_GH_REPO/releases/latest/download"
  else
    base="https://github.com/$CDH_GH_REPO/releases/download/$CDH_VERSION"
  fi
  tmp=$(mktemp -d /tmp/cdh-release.XXXXXX)
  trap "rm -rf '$tmp'" EXIT   # expand now: tmp is local
  curl -fsSL -o "$tmp/$asset" "$base/$asset" || return 1
  curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" || return 1
  (cd "$tmp" && grep " $asset\$" SHA256SUMS | sha256sum -c --quiet -) || return 1
  tar -C "$tmp" -xzf "$tmp/$asset"
  REPO=$tmp/cdh CDH_BIN=$tmp/cdh/cloud-desktop-host
}

# ════════════════════════════════════════════════════════════════
[[ $EUID -eq 0 ]] || die "run as root on the Proxmox host"
command -v pct >/dev/null || die "pct not found: this must run on a Proxmox VE host"
((CHECK_ONLY)) && echo "${YW}check mode: nothing will be changed${CL}"

header "Host"
if [[ -n $CDH_VERSION || ! -x $CDH_BIN || ! -d $REPO/scripts ]]; then
  msg_info "Downloading release ${CDH_VERSION:-latest} from $CDH_GH_REPO"
  fetch_release || die "could not download/verify cdh-fc$FEDORA-x86_64.tar.gz from $CDH_GH_REPO (${CDH_VERSION:-latest})"
  msg_ok "Release ${CDH_VERSION:-latest} downloaded" "sha256 ok"
else
  msg_ok "Using local build" "$CDH_BIN"
fi

chk_driver() { [[ -n "$(host_driver)" ]] && drm_node renderD; }
require "NVIDIA driver loaded ($(host_driver || echo none))" chk_driver \
  "install the NVIDIA driver on the host first (nvidia-smi must work)"

chk_modeset() { [[ "$(cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null)" == Y ]]; }
if chk_modeset; then msg_ok "nvidia-drm modeset=Y"
elif ((CHECK_ONLY)); then msg_todo "nvidia-drm modeset=Y (needs a host reboot)"; NEEDED=$((NEEDED + 1))
else
  echo "options nvidia-drm modeset=1" >/etc/modprobe.d/nvidia-drm.conf
  update-initramfs -u >>"$LOG" 2>&1
  die "nvidia-drm modeset=1 configured: reboot the host, then re-run this script"
fi

chk_uinput() { [[ -c /dev/uinput ]] && grep -qx uinput /etc/modules-load.d/uinput.conf; }
do_uinput()  { modprobe uinput; echo uinput >/etc/modules-load.d/uinput.conf; }
step "uinput loaded + persistent" chk_uinput do_uinput

UVM_RULE=/etc/udev/rules.d/70-nvidia-uvm.rules
UVM_RULE_TXT='KERNEL=="nvidia_uvm", RUN+="/usr/bin/nvidia-modprobe -c0 -u"'
chk_uvm() { [[ -c /dev/nvidia-uvm ]] && grep -qx nvidia_uvm /etc/modules-load.d/nvidia-uvm.conf && [[ "$(cat $UVM_RULE)" == "$UVM_RULE_TXT" ]]; }
do_uvm() {
  echo nvidia_uvm >/etc/modules-load.d/nvidia-uvm.conf
  echo "$UVM_RULE_TXT" >$UVM_RULE
  udevadm control --reload
  modprobe nvidia_uvm
  nvidia-modprobe -c0 -u
}
step "nvidia-uvm device + persistent" chk_uvm do_uvm

header "Container $CTID"
template() { pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk -v p="fedora-$FEDORA-default" '$1 ~ p {print $1}' | sort | tail -1; }
chk_template() { pct status "$CTID" >/dev/null 2>&1 || [[ -n "$(template)" ]]; }
do_template() {
  pveam update
  local t; t=$(pveam available --section system | awk -v p="fedora-$FEDORA-default" '$2 ~ p {print $2}' | sort | tail -1)
  [[ -n $t ]] || { echo "no fedora-$FEDORA template in pveam"; return 1; }
  pveam download "$TEMPLATE_STORAGE" "$t"
}
step "Fedora $FEDORA template" chk_template do_template

chk_ct() { pct status "$CTID" >/dev/null 2>&1; }
do_ct() {
  pct create "$CTID" "$(template)" \
    --unprivileged 1 --features nesting=1,fuse=1 --ostype fedora \
    --hostname "$CT_HOSTNAME" --cores "$CT_CORES" --memory "$CT_MEMORY" --swap 1024 \
    --rootfs "$CT_STORAGE:$CT_DISK" --net0 "name=eth0,bridge=$CT_BRIDGE,ip=dhcp"
}
step "CT exists" chk_ct do_ct

chk_unpriv() { grep -q '^unprivileged: 1' "$CONF" && ! grep -q '^lxc.idmap' "$CONF"; }
require "CT is unprivileged (default idmap)" chk_unpriv \
  "CT $CTID is privileged or uses a custom lxc.idmap; this script assumes uid shift 100000"

chk_nesting() { pct config "$CTID" | grep -q '^features:.*nesting=1'; }
do_nesting()  { pct set "$CTID" --features nesting=1,fuse=1; }
step "features nesting=1 (Steam bubblewrap)" chk_nesting do_nesting
((APPLIED)) && RESTART_CT=1

chk_running() { ct_up; }
do_running()  { pct start "$CTID"; sleep 5; }
step "CT running" chk_running do_running

# raw lxc.* keys, kept in the main section (before any [snapshot])
RAW_LINES=(
  "lxc.cgroup2.devices.allow: c 13:* rwm"
  "lxc.mount.entry: /dev/input dev/input none bind,optional,create=dir"
  "lxc.mount.entry: /run/udev mnt/host-udev none bind,ro,optional,create=dir"
  "lxc.cap.drop:"
  "lxc.cap.drop: mac_admin mac_override sys_module sys_pacct sys_rawio sys_time"
  "lxc.mount.entry: tmpfs dev/shm tmpfs rw,nosuid,nodev,mode=1777,size=$SHM_SIZE,create=dir 0 0"
)
main_conf() { sed '/^\[/,$d' "$CONF"; }
missing_raw() { local l; for l in "${RAW_LINES[@]}"; do main_conf | grep -qxF "$l" || echo "$l"; done; }
chk_raw() { [[ -z "$(missing_raw)" ]]; }
do_raw() {
  local add; add=$(missing_raw)
  # "lxc.cap.drop:" (reset) must come right before the explicit list
  if grep -q '^lxc.cap.drop: mac_admin' <<<"$add" || grep -qx 'lxc.cap.drop:' <<<"$add"; then
    sed -i '1,/^\[/{/^lxc\.cap\.drop:/d}' "$CONF"   # main section only
    add=$(missing_raw)
  fi
  ADD="$add" awk 'BEGIN{a=ENVIRON["ADD"]} /^\[/ && !d {print a; d=1} {print} END{if(!d) print a}' \
    "$CONF" >/tmp/cdh-lxc.conf && cat /tmp/cdh-lxc.conf >"$CONF" && rm -f /tmp/cdh-lxc.conf
}
step "lxc.conf: input bind, host udev, caps, /dev/shm" chk_raw do_raw
((APPLIED)) && RESTART_CT=1

chk_user() { ct id "$CT_USER" && ct_sh "id -nG $CT_USER | tr ' ' '\n' | grep -qx render && id -nG $CT_USER | tr ' ' '\n' | grep -qx input"; }
do_user() {
  ct_sh "id $CT_USER >/dev/null 2>&1 || useradd -m $CT_USER"
  ct usermod -aG video,render,input,wheel "$CT_USER"
}
step "CT user '$CT_USER' (video,render,input,wheel)" chk_user do_user

desired_devs() {
  local v r i card render minor
  v=$(ct_gid video) r=$(ct_gid render) i=$(ct_gid input)
  [[ -n $v && -n $r && -n $i ]] || return 1
  card=$(drm_node card) render=$(drm_node renderD) minor=$(nvidia_minor)
  local p
  for p in /dev/nvidia"$minor" /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
    [[ -e $p ]] && echo "$p,gid=$v,mode=0660"
  done
  echo "$render,gid=$r,mode=0660"
  echo "/dev/uinput,gid=$i,mode=0660"
  echo "$card,gid=$v,mode=0660"           # Sunshine's CUDA/NVENC path opens cardN
}
current_devs() { pct config "$CTID" | sed -n 's/^\(dev[0-9]*\): \(.*\)$/\1 \2/p'; }
chk_devs() {
  local want have; want=$(desired_devs) || return 1; have=$(current_devs | cut -d' ' -f2-)
  [[ "$(sort <<<"$want")" == "$(grep -E '^/dev/(nvidia|dri/|uinput)' <<<"$have" | sort)" ]]
}
do_devs() {
  local want; want=$(desired_devs)
  # drop stale GPU/input entries (e.g. cardN renumbered after a reboot)
  local key val
  while read -r key val; do
    [[ $val =~ ^/dev/(nvidia|dri/|uinput) ]] || continue
    grep -qxF "$val" <<<"$want" || pct set "$CTID" --delete "$key"
  done < <(current_devs)
  local spec n
  while read -r spec; do
    current_devs | cut -d' ' -f2- | grep -qxF "$spec" && continue
    n=0; while current_devs | grep -q "^dev$n "; do n=$((n + 1)); done
    pct set "$CTID" --"dev$n" "$spec"
  done <<<"$want"
}
step "GPU/uinput passthrough ($(drm_node card 2>/dev/null), $(drm_node renderD 2>/dev/null))" chk_devs do_devs
((APPLIED)) && RESTART_CT=1

if ((RESTART_CT && !CHECK_ONLY)); then
  msg_info "Restarting CT (full stop/start to apply config)"
  { pct stop "$CTID" && pct start "$CTID" && sleep 5; } >>"$LOG" 2>&1 || die "CT restart failed, see $LOG"
  msg_ok "CT restarted"
fi

header "Inside the container"
FSTAB_LINE='/mnt/host-udev  /run/udev  none  bind,ro  0 0'
chk_udevdb() { ct grep -qxF "$FSTAB_LINE" /etc/fstab && ct_sh 'ls /run/udev/data | grep -q .'; }
do_udevdb() {
  ct_sh "grep -qxF '$FSTAB_LINE' /etc/fstab || echo '$FSTAB_LINE' >> /etc/fstab"
  ct_sh 'mountpoint -q /run/udev && ls /run/udev/data >/dev/null 2>&1 || mount /run/udev'
}
step "host udev db at /run/udev" chk_udevdb do_udevdb

CT_UID=$(ct id -u "$CT_USER" 2>/dev/null || true)
HOST_UID=$((100000 + ${CT_UID:-1000}))
INPUT_RULE=/etc/udev/rules.d/60-lxc-virtual-input.rules
INPUT_RULE_TXT="SUBSYSTEM==\"input\", KERNEL==\"event*\", DEVPATH==\"/devices/virtual/input/*\", OWNER=\"$HOST_UID\", MODE=\"0600\""
chk_inrule() { [[ "$(cat $INPUT_RULE)" == "$INPUT_RULE_TXT" ]]; }
do_inrule()  { echo "$INPUT_RULE_TXT" >$INPUT_RULE; udevadm control --reload; }
step "host udev rule: Sunshine virtual input → host uid $HOST_UID" chk_inrule do_inrule

chk_pkgs() { ct rpm -q "${CT_PACKAGES[@]}"; }
do_pkgs()  { ct dnf install -y "${CT_PACKAGES[@]}"; }
step "packages (KWin, Plasma, PipeWire, Xwayland…)" chk_pkgs do_pkgs

DRV=$(host_driver || true)
chk_nvuser() { [[ -n $DRV ]] && ct test -e "/usr/lib64/libnvidia-glcore.so.$DRV"; }
do_nvuser() {
  ct curl -fsSLo /tmp/nvidia.run "https://download.nvidia.com/XFree86/Linux-x86_64/$DRV/NVIDIA-Linux-x86_64-$DRV.run"
  ct sh /tmp/nvidia.run --no-kernel-module --install-compat32-libs -s
  ct rm -f /tmp/nvidia.run
}
step "NVIDIA userspace $DRV (matches host)" chk_nvuser do_nvuser

chk_smi() { ct nvidia-smi -L; }
require "nvidia-smi works in CT" chk_smi "check devN entries and driver version, see $LOG"

chk_linger() { ct test -e "/var/lib/systemd/linger/$CT_USER"; }
do_linger()  { ct loginctl enable-linger "$CT_USER"; }
step "linger for '$CT_USER'" chk_linger do_linger

chk_cdh() { [[ "$(sha256sum <"$CDH_BIN" | cut -d' ' -f1)" == "$(ct sha256sum /usr/local/bin/cloud-desktop-host | cut -d' ' -f1)" ]]; }
do_cdh()  { pct push "$CTID" "$CDH_BIN" /usr/local/bin/cloud-desktop-host --perms 0755; }
step "cloud-desktop-host binary" chk_cdh do_cdh

manifest() { (cd "$REPO" && find scripts configs -type f | sort | xargs sha256sum); }
chk_scripts() { manifest | pct exec "$CTID" -- runuser -u "$CT_USER" -- sh -c "cd $CT_CDH && sha256sum -c --quiet --status -"; }
do_scripts() {
  tar -C "$REPO" -c scripts configs | pct exec "$CTID" -- runuser -u "$CT_USER" -- \
    sh -c "mkdir -p $CT_CDH && tar -C $CT_CDH -x && chmod +x $CT_CDH/scripts/*.sh"
}
step "CDH scripts + configs in $CT_CDH" chk_scripts do_scripts

chk_sunshine() { ct rpm -q sunshine; }
do_sunshine() {
  if [[ -f $SUNSHINE_RPM ]]; then
    pct push "$CTID" "$SUNSHINE_RPM" /tmp/sunshine.rpm
    ct dnf install -y /tmp/sunshine.rpm || true   # postinst modprobe/udevadm fail in a CT
    ct rm -f /tmp/sunshine.rpm
  else
    ct dnf install -y "$SUNSHINE_RPM" || true
  fi
}
step "Sunshine" chk_sunshine do_sunshine

chk_sscap() { ct_sh 'f=$(readlink -f "$(command -v sunshine)") && [ -z "$(getcap "$f")" ]'; }
do_sscap()  { ct_sh 'setcap -r "$(readlink -f "$(command -v sunshine)")"'; }
step "Sunshine has no file caps (AT_SECURE breaks ENet)" chk_sscap do_sscap

chk_ssconf() { ct_user 'test -s ~/.config/sunshine/sunshine.conf && test -s ~/.config/sunshine/apps.json'; }
do_ssconf() {
  local ip origins
  ip=$(ct_ip)
  origins="https://$ip:47990${CSRF_EXTRA:+,$CSRF_EXTRA}"
  ct_user "mkdir -p ~/.config/sunshine
    test -s ~/.config/sunshine/sunshine.conf || printf '%s\n' \
      'capture = wlr' 'encoder = nvenc' 'gamepad = xone' 'system_tray = disabled' \
      'csrf_allowed_origins = $origins' > ~/.config/sunshine/sunshine.conf
    test -s ~/.config/sunshine/apps.json || cp $CT_CDH/configs/sunshine/apps.json ~/.config/sunshine/"
}
step "Sunshine config (kept if it already exists)" chk_ssconf do_ssconf

if ((INSTALL_STEAM)); then
  chk_rpmfusion() { ct rpm -q rpmfusion-nonfree-release; }
  do_rpmfusion()  { ct dnf install -y "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$FEDORA.noarch.rpm"; }
  step "RPM Fusion nonfree" chk_rpmfusion do_rpmfusion

  chk_steam() { ct rpm -q steam gamescope mangohud; }
  do_steam()  { ct dnf install -y steam gamescope mangohud; }
  step "Steam + Gamescope + MangoHud" chk_steam do_steam

  chk_gscap() { ct_sh 'f=$(command -v gamescope) && [ -z "$(getcap "$f")" ]'; }
  do_gscap()  { ct_sh 'setcap -r "$(command -v gamescope)"'; }
  step "Gamescope has no file caps" chk_gscap do_gscap
fi

echo
if ((CHECK_ONLY)); then
  ((NEEDED)) && echo "${YW}$NEEDED step(s) needed.${CL} Run without --check to apply." \
             || echo "${GN}Everything is in place.${CL}"
  exit 0
fi
IP=$(ct_ip)
cat <<EOF
${GN}Done.${CL} Log: $LOG
  Start:   pct exec $CTID -- runuser -l $CT_USER -c '$CT_CDH/scripts/run.sh'
  Web UI:  https://$IP:47990   (create the Sunshine login on first visit)
  Moonlight: add $IP, enter the PIN in the web UI.
  Set a password for '$CT_USER' if you need it:  pct exec $CTID -- passwd $CT_USER
EOF
