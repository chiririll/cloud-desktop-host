# ── container + host helpers ───────────────────────────────────
ct()      { pct exec "$CTID" -- "$@"; }
ct_ip()   { ct ip -4 -o addr show dev eth0 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4; exit}'; }
ct_sh()   { pct exec "$CTID" -- bash -c "$1"; }
ct_user() { pct exec "$CTID" -- runuser -l "$CT_USER" -c "$1"; }
ct_up()   { [[ "$(pct status "$CTID" 2>/dev/null)" == "status: running" ]]; }
ct_gid()  { ct getent group "$1" | cut -d: -f3; }

# ct_install_rpm <url|local .rpm> [lenient]
# lenient=1: ignore dnf's exit code (e.g. Sunshine's postinst modprobe/udevadm fail in a CT)
ct_install_rpm() {
  local src=$1 lenient=${2:-0} rc=0 tmp
  if [[ -f $src ]]; then
    tmp=/tmp/cdh-install-$(basename "$src")
    pct push "$CTID" "$src" "$tmp"
    ct dnf install -y "$tmp" || rc=$?
    ct rm -f "$tmp"
  else
    ct dnf install -y "$src" || rc=$?
  fi
  if ((lenient)); then return 0; fi
  return "$rc"
}

# rpm_missing pkg… → prints missing package names, fails if any
rpm_missing() {
  local out rc=0 m
  out=$(ct rpm -q "$@" 2>&1) || rc=$?
  ((rc == 0)) && return 0
  m=$(awk '/is not installed/{print $2}' <<<"$out" | xargs)
  [[ -n $m ]] && { why "missing: $m"; return; }
  why "rpm -q failed: $(head -1 <<<"$out")"
}

# step "…has no file caps" "chk_nocaps <binary>" "do_nocaps <binary>"
chk_nocaps() { ct bash -c 'f=$(readlink -f "$(command -v "$1")") && [ -z "$(getcap "$f")" ]' _ "$1"; }
do_nocaps()  { ct bash -c 'setcap -r "$(readlink -f "$(command -v "$1")")"' _ "$1"; }

# ── GPU discovery (on the Proxmox host) ────────────────────────
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
