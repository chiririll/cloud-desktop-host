# ── phase: input guard kernel module (skipped with INSTALL_INPUT_GUARD=0) ──
# cdh_input_guard (github.com/chiririll/cdh-input-guard) keeps virtual input devices
# away from the host console. The release has one cdh_input_guard-<kver>.ko per Proxmox
# kernel, the udev rule and SHA256SUMS. Loaded for the current boot only; loading it
# at boot is pve/host-persist.sh.
#
# The module alone does not keep containers apart: it only records, per device, the
# cgroup of the process that created it. The second half of this file uses that to
# give every CT its own /dev/input.
GUARD_KVER=$(uname -r)
GUARD_KO_NAME=cdh_input_guard-$GUARD_KVER.ko
GUARD_KO=/lib/modules/$GUARD_KVER/extra/cdh_input_guard.ko
GUARD_RULE_NAME=71-cdh-virtual-input.rules
GUARD_RULE=/etc/udev/rules.d/$GUARD_RULE_NAME
GUARD_LOAD=/etc/modules-load.d/cdh_input_guard.conf   # written by host-persist.sh

guard_base() {
  if [[ -z $CDH_GUARD_VERSION || $CDH_GUARD_VERSION == latest ]]; then
    echo "https://github.com/$CDH_GUARD_REPO/releases/latest/download"
  else
    echo "https://github.com/$CDH_GUARD_REPO/releases/download/$CDH_GUARD_VERSION"
  fi
}
guard_fetch() { curl -fsSL "$(guard_base)/$1"; }

# expected sha256 of a release asset
guard_sum() {
  local sums sum
  sums=$(guard_fetch SHA256SUMS) || { echo "cannot fetch SHA256SUMS from $CDH_GUARD_REPO (${CDH_GUARD_VERSION:-latest})" >&2; return 1; }
  sum=$(awk -v f="$1" '$2 == f {print $1}' <<<"$sums")
  [[ -n $sum ]] || { echo "release has no $1 (no module built for kernel $GUARD_KVER?)" >&2; return 1; }
  echo "$sum"
}

# chk_guard_file <asset> <dest>: installed file matches the release
chk_guard_file() {
  local want; want=$(guard_sum "$1") || return 1
  [[ -f $2 && $(sha256sum <"$2" | cut -d' ' -f1) == "$want" ]] || why "$2 missing or differs from the release"
}
do_guard_file() {
  local want tmp; want=$(guard_sum "$1")
  tmp=$(mktemp)
  guard_fetch "$1" >"$tmp"
  [[ $(sha256sum <"$tmp" | cut -d' ' -f1) == "$want" ]] || { rm -f "$tmp"; echo "sha256 mismatch for $1"; return 1; }
  install -D -m 0644 "$tmp" "$2"; rm -f "$tmp"
  case $2 in
    *.ko)    depmod -a "$GUARD_KVER" ;;
    *.rules) udevadm control --reload ;;
  esac
}

chk_guard_loaded() { [[ -d /sys/module/cdh_input_guard ]] || why "cdh_input_guard not loaded"; }
do_guard_loaded()  { modprobe cdh_input_guard; }

phase_guard() {
  [[ $INSTALL_INPUT_GUARD != 0 ]] || return 0
  header "Input guard (kernel $GUARD_KVER)"
  step "cdh_input_guard.ko for this kernel" "chk_guard_file $GUARD_KO_NAME $GUARD_KO" "do_guard_file $GUARD_KO_NAME $GUARD_KO"
  step "udev rule $GUARD_RULE_NAME" "chk_guard_file $GUARD_RULE_NAME $GUARD_RULE" "do_guard_file $GUARD_RULE_NAME $GUARD_RULE"
  step "cdh_input_guard loaded" chk_guard_loaded do_guard_loaded
  step "per-container input nodes (cdh-input-node + udev rule)" chk_input_helper do_input_helper
  if grep -qsxF cdh_input_guard "$GUARD_LOAD"; then
    msg_ok "cdh_input_guard loaded at boot"
  else
    msg_warn "cdh_input_guard not loaded at boot: after a host reboot the CT gets no input devices until it is loaded (run $PERSIST_HINT)"
  fi
}

# ── per-container /dev/input ───────────────────────────────────
# Each CT bind-mounts $INPUT_ROOT/<ctid> as its /dev/input, and the host helper
# cdh-input-node (run by udev) puts the nodes of a virtual input device only into the
# directory of the CT that created it. So a CT cannot open another CT's keyboard,
# mouse or gamepad. Without the module (INSTALL_INPUT_GUARD=0) nobody knows who
# created a device, and every CT keeps the host's whole /dev/input.
#
# The directories are under /dev because device nodes need a filesystem mounted
# without "nodev", which /run is not. They are root-owned: the CT must not be able
# to create or rename entries in a directory where root makes device nodes.
INPUT_ROOT=/dev/cdh-input                      # <ctid>/eventN, jsN     (the same paths are in input_helper_txt)
INPUT_CONF=/etc/cdh-input                      # <ctid>.uid: host uid that owns the CT's nodes
INPUT_HELPER=/usr/local/sbin/cdh-input-node
INPUT_NODE_RULE=/etc/udev/rules.d/72-cdh-input-node.rules

input_helper_txt() { get_file bin/cdh-input-node.sh; }

input_node_rule_txt() { get_file udev/72-cdh-input-node.rules; }

chk_input_helper() {
  [[ -x $INPUT_HELPER && "$(cat "$INPUT_HELPER")" == "$(input_helper_txt)" ]] || { why "$INPUT_HELPER missing or outdated"; return; }
  [[ "$(cat "$INPUT_NODE_RULE" 2>/dev/null)" == "$(input_node_rule_txt)" ]] || why "$INPUT_NODE_RULE missing or outdated"
}
do_input_helper() {
  input_helper_txt >"$INPUT_HELPER.new"
  chmod 0755 "$INPUT_HELPER.new"
  mv -f "$INPUT_HELPER.new" "$INPUT_HELPER"    # udev may be running the old one
  input_node_rule_txt >"$INPUT_NODE_RULE"
  udevadm control --reload
  "$INPUT_HELPER" sync
}

# The directory must exist before the CT starts (its mount entry is not "optional"),
# and /dev is empty after a host reboot: tmpfiles.d recreates it early at boot.
# Never remove it while the CT runs: the CT would keep the deleted directory mounted.
input_tmpfiles()     { echo "/etc/tmpfiles.d/cdh-input-$CTID.conf"; }
input_tmpfiles_txt() { echo "d $INPUT_ROOT/$CTID 0755 root root -"; }
chk_input_dir() {
  [[ -d $INPUT_ROOT/$CTID ]] || { why "$INPUT_ROOT/$CTID missing"; return; }
  [[ "$(cat "$(input_tmpfiles)" 2>/dev/null)" == "$(input_tmpfiles_txt)" ]] \
    || why "$(input_tmpfiles) missing or outdated ($INPUT_ROOT/$CTID would be gone after a host reboot)"
}
do_input_dir() {
  input_tmpfiles_txt >"$(input_tmpfiles)"
  install -d -m 0755 -o root -g root "$INPUT_ROOT" "$INPUT_ROOT/$CTID"
}

# host uid of the CT user: the helper makes the CT's nodes 0600 for it
chk_input_owner() {
  [[ "$(cat "$INPUT_CONF/$CTID.uid" 2>/dev/null)" == "$(host_uid)" ]] || why "$INPUT_CONF/$CTID.uid is not $(host_uid)"
}
do_input_owner() {
  install -d -m 0755 "$INPUT_CONF"
  host_uid >"$INPUT_CONF/$CTID.uid"
  "$INPUT_HELPER" sync                         # devices the CT already has
}

# Other CTs on this host that still bind the host's whole /dev/input (main section only).
legacy_input_cts() {
  local f id out=()
  for f in /etc/pve/lxc/*.conf; do
    id=${f##*/}; id=${id%.conf}
    [[ $id != "$CTID" && -f $f ]] || continue
    if awk '/^\[/ {exit} /^lxc\.mount\.entry: \/dev\/input dev\/input / {f=1; exit} END {exit !f}' "$f"; then
      out+=("$id")
    fi
  done
  echo "${out[*]}"
}

# What ct-install.sh does about 60-lxc-virtual-input.rules (it hands every virtual device on the host to
# one uid; only CTs on the shared /dev/input need it): 0 = install it, 1 = this CT has its own /dev/input,
# remove it, keep = other CTs still share /dev/input, leave it alone.
input_isolation_mode() {
  local others
  if ! input_isolated; then echo 0; return; fi
  others=$(legacy_input_cts)
  if [[ -n $others ]]; then
    msg_warn "still on the host's shared /dev/input: CT $others. Re-run install.sh for each: until then they can read CT $CTID's input devices" >&2
    echo keep
  else
    echo 1
  fi
}
