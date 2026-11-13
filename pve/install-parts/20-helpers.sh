# ════════════════════════════════════════════════════════════════
# Helpers: every small reusable function lives in this file.
# The phase files (70-74) only contain their own checks/applies.
#   1. output          msg_*, die, header
#   2. prompts         ask, confirm
#   3. step engine     why, step, require
#   4. validation      is_supported_fedora, IPV4_RE
#   5. container       ct*, rpm_missing, chk_nocaps
#   6. host            GPU discovery, host_uid, mod_persisted, input_isolated
#   7. release bundle  manifest
# ════════════════════════════════════════════════════════════════

# ── 1. output, community-scripts style ─────────────────────────
if [[ -t 1 ]]; then
  GN=$'\e[32m' YW=$'\e[33m' RD=$'\e[31m' BL=$'\e[36m' DM=$'\e[2m' CL=$'\e[0m'
else
  GN='' YW='' RD='' BL='' DM='' CL=''
fi
msg_info() { printf ' %s…%s %s' "$YW" "$CL" "$1"; }
msg_ok()   { printf '\r\e[K %s✔%s %s%s%s\n' "$GN" "$CL" "$1" "$DM" "${2:+ ($2)}$CL"; }
msg_todo() { printf '\r\e[K %s◦%s %s %s(needed)%s\n' "$BL" "$CL" "$1" "$YW" "$CL"; }
msg_warn() { printf '\r\e[K %s!%s %s\n' "$YW" "$CL" "$1"; }
die()      { printf '\r\e[K %s✘%s %s\n' "$RD" "$CL" "$1"; exit 1; }
header()   { printf '\n%s── %s%s\n' "$BL" "$1" "$CL"; }

# ── 2. prompts (read from /dev/tty so `bash -c "$(curl …)"` works too) ──
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

# ── 3. step engine ─────────────────────────────────────────────
# step "description" check apply
#   check/apply are function names; extra words become arguments
#   ("chk_nocaps sunshine"), so one pair of functions can serve several steps.
#   Checks print WHY they fail (one reason per line, see why()); shown under "needed".
#   Globals: CHECK_ONLY (read), NEEDED (counted in --check), APPLIED (set to 1 if applied).
# require "description" check "hint": a check we can't fix automatically.

# why <reason>: print the reason and fail; the last line of a failing check
why() { echo "$*"; return 1; }

# show_why <check output>: first lines of a check's output, dimmed and indented
show_why() { [[ -n $1 ]] && sed -n '1,8p' <<<"$1" | sed "s/^/     $DM/; s/\$/$CL/"; return 0; }

step() {
  local name=$1 check=$2 apply=$3 rc out
  APPLIED=0

  if out=$($check 2>&1); then msg_ok "$name"; return 0; fi

  if ((CHECK_ONLY)); then
    msg_todo "$name"; show_why "$out"
    NEEDED=$((NEEDED + 1))
    return 0
  fi

  msg_info "$name"
  printf '=== %s %s\n%s\n' "$(date -Is)" "$name" "$out" >>"$LOG"
  set +e; ( set -e; $apply ) >>"$LOG" 2>&1; rc=$?; set -e
  ((rc == 0)) || die "$name: failed (exit $rc), see $LOG"

  if ! out=$($check 2>&1); then
    printf '\r\e[K'; show_why "$out"
    die "$name: still not satisfied after applying, see $LOG"
  fi
  APPLIED=1
  msg_ok "$name" "done"
}

require() {
  local name=$1 check=$2 hint=$3 out
  out=$($check 2>&1) && { msg_ok "$name"; return 0; }
  if ((CHECK_ONLY)); then
    msg_todo "$name: $hint"; show_why "$out"
    NEEDED=$((NEEDED + 1))
    return 0
  fi
  show_why "$out"; die "$name: $hint"
}

# call right after a step whose change needs a CT restart
restart_if_applied() { if ((APPLIED)); then RESTART_CT=1; fi; }

# ── 4. validation ──────────────────────────────────────────────
IPV4_RE='([0-9]{1,3}\.){3}[0-9]{1,3}'

is_supported_fedora() {
  local v
  for v in "${SUPPORTED_FEDORA[@]}"; do [[ $v == "$1" ]] && return 0; done
  return 1
}

# ── 5. container ───────────────────────────────────────────────
ct()      { pct exec "$CTID" -- "$@"; }
ct_sh()   { pct exec "$CTID" -- bash -c "$1"; }
ct_user() { pct exec "$CTID" -- runuser -l "$CT_USER" -c "$1"; }
ct_up()   { [[ "$(pct status "$CTID" 2>/dev/null)" == "status: running" ]]; }
ct_gid()  { ct getent group "$1" | cut -d: -f3; }
ct_ip()   { ct ip -4 -o addr show dev eth0 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4; exit}'; }

# the CT user's systemd --user instance: ct_systemctl enable --now foo.service
ct_systemctl() { ct_user "XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user $*"; }

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

# rpm_missing pkg… : prints the missing package names, fails if any
rpm_missing() {
  local out rc=0 m
  out=$(ct rpm -q "$@" 2>&1) || rc=$?
  ((rc == 0)) && return 0
  m=$(awk '/is not installed/{print $2}' <<<"$out" | xargs)
  [[ -n $m ]] && { why "missing: $m"; return; }
  why "rpm -q failed: $(head -1 <<<"$out")"
}

# step "… has no file caps" "chk_nocaps <binary>" "do_nocaps <binary>"
chk_nocaps() { ct bash -c 'f=$(readlink -f "$(command -v "$1")") && [ -z "$(getcap "$f")" ]' _ "$1"; }
do_nocaps()  { ct bash -c 'setcap -r "$(readlink -f "$(command -v "$1")")"' _ "$1"; }

# ── 6. Proxmox host ────────────────────────────────────────────
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

# ── 7. release bundle ──────────────────────────────────────────
# release lines of MANIFEST that belong inside the CT (scripts/, configs/)
manifest() { grep -E '  (scripts|configs)/' <<<"$MANIFEST"; }
