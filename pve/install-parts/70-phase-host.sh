# ── phase: Proxmox host (driver, modules) ──────────────────────
chk_driver() { [[ -n "$(host_driver)" ]] && drm_node renderD; }

# Only what the current boot needs. Settings that survive a host reboot
# (modeset, modules-load.d, udev rule) are pve/host-persist.sh, opt-in.
PERSIST_HINT="pve/host-persist.sh"
chk_modeset() { [[ "$(cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null)" == Y ]] || why "nvidia_drm modeset is not Y"; }

chk_uinput() { [[ -c /dev/uinput ]] || why "/dev/uinput missing (module not loaded)"; }
do_uinput()  { modprobe uinput; }

chk_uvm() { [[ -c /dev/nvidia-uvm ]] || why "/dev/nvidia-uvm missing"; }
do_uvm()  { nvidia-modprobe -c0 -u; }

# warning only: you may load these some other way (e.g. CUDA/nvidia-smi before the CT starts)
mod_persisted() { # any file, so a missing /etc/modules doesn't make grep fail
  local f; for f in /etc/modules /etc/modules-load.d/*.conf; do grep -qsxE "[[:space:]]*$1[[:space:]]*" "$f" && return 0; done; return 1
}
chk_reboot() {
  local r=0
  mod_persisted uinput || { echo "uinput not in /etc/modules-load.d"; r=1; }
  mod_persisted nvidia_uvm || { echo "nvidia_uvm not in /etc/modules-load.d"; r=1; }
  grep -qsE 'nvidia-modprobe.* -u' /etc/udev/rules.d/*.rules || { echo "no udev rule creating /dev/nvidia-uvm"; r=1; }
  return $r
}

phase_host() {
  local out
  header "Host"
  phase_bundle

  require "NVIDIA driver loaded ($(host_driver || echo none))" chk_driver \
    "install the NVIDIA driver on the host first (nvidia-smi must work)"
  require "nvidia-drm modeset=Y" chk_modeset \
    "set nvidia-drm modeset=1 ($PERSIST_HINT, or yourself) and reboot the host"
  step "uinput loaded" chk_uinput do_uinput
  step "nvidia-uvm device" chk_uvm do_uvm

  if out=$(chk_reboot); then
    msg_ok "uinput + nvidia-uvm set up at boot"
  else
    msg_warn "uinput/nvidia-uvm not set up at boot, load them before starting the CT (or run $PERSIST_HINT)"
    show_why "$out"
  fi
}
