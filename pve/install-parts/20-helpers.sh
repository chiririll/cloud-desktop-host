# ════════════════════════════════════════════════════════════════
# Host helpers (the shared output/step engine is in shared/20-engine.sh).
#   1. prompts         ask, confirm
#   2. validation      is_supported_distro, IPV4_RE
#   3. container       ct*
#   4. host            GPU discovery, host_uid, mod_persisted, input_isolated
# ════════════════════════════════════════════════════════════════

# ── 1. prompts (read from /dev/tty so `bash -c "$(curl …)"` works too) ──
have_tty() { { : </dev/tty; } 2>/dev/null; }

# ask VAR "question" default [regex]: keeps VAR if it is already set (env)
ask() {
  local var=$1 q=$2 def=$3 re=${4:-.} ans
  [[ -n ${!var} ]] && return 0
  if ! have_tty; then printf -v "$var" '%s' "$def"; return 0; fi
  while :; do
    read -rp " ${BL}?${CL} $q [${def}]: " ans </dev/tty || exit 1
    ans=${ans:-$def}
    [[ $ans =~ $re ]] && break
    echo "   invalid value"
  done
  printf -v "$var" '%s' "$ans"
}

# confirm "question" [y|n, default n]: returns 0 for yes (always yes with YES=1 or no tty)
confirm() {
  local ans def=${2:-n} hint=y/N
  [[ $def == y ]] && hint=Y/n
  ((YES)) && return 0
  have_tty || return 0
  read -rp " ${YW}?${CL} $1 [$hint]: " ans </dev/tty || exit 1
  [[ ${ans:-$def} =~ ^[Yy] ]]
}


# call right after a step whose change needs a CT restart
restart_if_applied() { if ((APPLIED)); then RESTART_CT=1; fi; }

# ── 2. validation ──────────────────────────────────────────────
IPV4_RE='([0-9]{1,3}\.){3}[0-9]{1,3}'

is_supported_distro() {
  local v
  for v in "${SUPPORTED_DISTROS[@]}"; do [[ $v == "$1" ]] && return 0; done
  return 1
}

# ── 3. container ───────────────────────────────────────────────
ct()      { pct exec "$CTID" -- "$@"; }
ct_sh()   { pct exec "$CTID" -- bash -c "$1"; }
ct_up()   { [[ "$(pct status "$CTID" 2>/dev/null)" == "status: running" ]]; }
ct_gid()  { ct getent group "$1" | cut -d: -f3; }
ct_ip()   { ct ip -4 -o addr show dev eth0 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4; exit}'; }

# ── 4. Proxmox host ────────────────────────────────────────────
host_driver() { cat /sys/module/nvidia/version 2>/dev/null; }

# drm_node card|renderD → /dev/dri/<node> of the chosen NVIDIA GPU
drm_node() {
  local d n
  for d in /sys/class/drm/"$1"*; do
    n=${d##*/}; [[ $n =~ ^$1[0-9]+$ ]] || continue
    [[ "$(cat "$d/device/vendor" 2>/dev/null)" == 0x10de ]] || continue
    [[ -z $NVIDIA_PCI || "$(basename "$(readlink -f "$d/device")")" == "$NVIDIA_PCI" ]] || continue
    echo "/dev/dri/$n"; return 0
  done
  return 1
}

# minor number N of /dev/nvidiaN for the chosen GPU
nvidia_minor() {
  local pci=${NVIDIA_PCI:-$(basename "$(readlink -f "/sys/class/drm/$(basename "$(drm_node card)")/device")")}
  local m; m=$(awk '/^Device Minor:/{print $3}' "/proc/driver/nvidia/gpus/$pci/information" 2>/dev/null)
  echo "${m:-0}"
}

# mod_persisted <module>: listed in /etc/modules or modules-load.d (any file, so a missing /etc/modules is fine)
mod_persisted() {
  local f
  for f in /etc/modules /etc/modules-load.d/*.conf; do
    grep -qsxE "[[:space:]]*$1[[:space:]]*" "$f" && return 0
  done
  return 1
}

# uid on the host of the CT user (unprivileged CT: shift 100000)
host_uid() { local u; u=$(ct id -u "$CT_USER" 2>/dev/null) || u=''; echo $((100000 + ${u:-1000})); }

# true when each CT gets its own /dev/input (needs the cdh_input_guard module)
input_isolated() { [[ $INSTALL_INPUT_GUARD != 0 ]]; }

