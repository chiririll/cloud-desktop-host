# ── phase: system (udev db, packages, user, NVIDIA userspace) ──
chk_curl() { pkg_missing curl ca-certificates; }
do_curl()  { pkg_install curl ca-certificates; }

# The host's udev database: the container has no udev of its own, libinput/KWin need the host's.
# In an LXC it is bind-mounted at /mnt/host-udev (lxc.mount.entry, see 52-phase-container.sh) and re-mounted
# on /run/udev through fstab; on a VM /run/udev is populated by its own udev and nothing is needed.
UDEV_FSTAB_LINE='/mnt/host-udev  /run/udev  none  bind  0 0'   # no ro: the source is already ro (lxc.mount.entry) and a ro remount is EPERM in an unprivileged CT
UDEV_FSTAB_OLD='/mnt/host-udev  /run/udev  none  bind,ro  0 0'
chk_udevdb() {
  ls /run/udev/data 2>/dev/null | grep -q . || { why "/run/udev/data is empty: the host's udev database is not mounted"; return; }
  if [[ -d /mnt/host-udev ]]; then grep -qxF "$UDEV_FSTAB_LINE" /etc/fstab || why "/etc/fstab has no bind mount of /mnt/host-udev"; fi
}
do_udevdb() {
  if [[ ! -d /mnt/host-udev ]]; then
    echo "no /mnt/host-udev: bind-mount the host's /run/udev (read-only) there, or at /run/udev"
    return 1
  fi
  sed -i "\|^$UDEV_FSTAB_OLD\$|d" /etc/fstab   # older versions wrote bind,ro
  grep -qxF "$UDEV_FSTAB_LINE" /etc/fstab || echo "$UDEV_FSTAB_LINE" >>/etc/fstab
  if mountpoint -q /run/udev && ls /run/udev/data >/dev/null 2>&1; then return 0; fi
  mkdir -p /run/udev   # absent when no udev runs in the CT (Ubuntu); /run is tmpfs
  mount /run/udev
}

# Sunshine's virtual input devices must be owned by the CT user's uid as seen from the host.
# With the input guard the CT has its own /dev/input and cdh-input-node sets the owner (host side); this rule
# is only for containers on the host's shared /dev/input (CDH_INPUT_ISOLATED=0). "keep" leaves it alone.
INPUT_RULE=/etc/udev/rules.d/60-lxc-virtual-input.rules
input_rule_txt() { local HOST_UID; HOST_UID=$(host_uid); render_file udev/60-lxc-virtual-input.rules HOST_UID; }
chk_inrule() { [[ "$(cat $INPUT_RULE 2>/dev/null)" == "$(input_rule_txt)" ]] || why "$INPUT_RULE missing or outdated"; }
do_inrule()  { input_rule_txt >$INPUT_RULE; udevadm control --reload; }
chk_no_inrule() { [[ ! -e $INPUT_RULE ]] || why "$INPUT_RULE still gives every virtual input device to one uid"; }
do_no_inrule()  { rm -f "$INPUT_RULE"; udevadm control --reload; }
phase_input_rule() {
  case $CDH_INPUT_ISOLATED in
    1) step "shared udev rule ${INPUT_RULE##*/} removed" chk_no_inrule do_no_inrule ;;
    keep) msg_warn "other containers still share /dev/input: ${INPUT_RULE##*/} left as it is" ;;
    *) step "host udev rule: Sunshine virtual input → host uid $(host_uid)" chk_inrule do_inrule ;;
  esac
}

chk_pkgs() { local p; mapfile -t p < <(ct_packages); pkg_missing "${p[@]}"; }
do_pkgs()  { local p; mapfile -t p < <(ct_packages); pkg_install "${p[@]}"; }

chk_user() {
  id "$CT_USER" >/dev/null 2>&1 || { why "user '$CT_USER' does not exist"; return; }
  local g groups; groups=$(id -nG "$CT_USER")
  for g in video render input; do
    getent group "$g" >/dev/null || continue
    grep -qw "$g" <<<"$groups" || { why "'$CT_USER' is not in group $g"; return; }
  done
}
do_user() {
  id "$CT_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$CT_USER"
  local g
  for g in video render input "$(admin_group)"; do
    if getent group "$g" >/dev/null; then usermod -aG "$g" "$CT_USER"; fi
  done
}

# the .run installer puts the libraries in /usr/lib64 (Fedora) or /usr/lib/x86_64-linux-gnu (Debian)
nv_libs_present() { ls /usr/lib64/libnvidia-glcore.so."$1" /usr/lib/x86_64-linux-gnu/libnvidia-glcore.so."$1" >/dev/null 2>&1; }
chk_nvuser() {
  local drv; drv=$(host_driver) || { why "cannot read the host's NVIDIA driver version (/sys/module/nvidia, /proc/driver/nvidia)"; return; }
  nv_libs_present "$drv" || why "NVIDIA userspace $drv not installed"
}
do_nvuser() {
  local drv; drv=$(host_driver)
  curl -fsSLo /tmp/nvidia.run "https://download.nvidia.com/XFree86/Linux-x86_64/$drv/NVIDIA-Linux-x86_64-$drv.run"
  sh /tmp/nvidia.run --no-kernel-module --install-compat32-libs -s
  rm -f /tmp/nvidia.run
}

chk_smi() { nvidia-smi -L; }

chk_linger() { [[ -e "/var/lib/systemd/linger/$CT_USER" ]]; }
do_linger()  { loginctl enable-linger "$CT_USER"; }

phase_system() {
  header "System"
  step "host udev db at /run/udev" chk_udevdb do_udevdb
  phase_input_rule
  step "packages (KWin, Plasma, PipeWire, Xwayland…)" chk_pkgs do_pkgs
  step "user '$CT_USER' (video,render,input)" chk_user do_user
  step "NVIDIA userspace $(host_driver || echo '?') (matches host)" chk_nvuser do_nvuser
  require "nvidia-smi works in the container" chk_smi "check the /dev/nvidia* nodes and the driver version, see $LOG"
  step "linger for '$CT_USER'" chk_linger do_linger
}
