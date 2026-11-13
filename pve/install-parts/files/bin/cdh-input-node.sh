#!/bin/bash
# cdh-input-node add|remove <eventN|jsN>
# cdh-input-node sync
#
# Written by cloud-desktop-host pve/install.sh; a re-run overwrites it.
#
# Gives each container only the virtual input devices it created. cdh_input_guard
# records the cgroup of the process that created a uinput device in the root-only
# sysfs attribute cdh_owner_cgroup. For a device created inside CT <id> this makes
# /dev/cdh-input/<id>/<node>, owned by the uid in /etc/cdh-input/<id>.uid; that
# directory is the CT's /dev/input. A device with no owner (created before the
# module loaded, or by the host) is given to nobody.
#
# udev runs add/remove (72-cdh-input-node.rules); install.sh runs sync.
set -u
shopt -s nullglob
PATH=/usr/sbin:/usr/bin:/sbin:/bin
SYS=/sys/class/input
ROOT=/dev/cdh-input
CONF=/etc/cdh-input

valid() { [[ $1 =~ ^(event|js)[0-9]+$ ]]; }

# Prints the id of the CT that created the device, nothing if there is none.
# The attribute is untrusted: below /lxc/<id>/ the container names its own
# cgroups, so only the start of the path is used.
owner_ct() {
  local f=$SYS/$1/device/cdh_owner_cgroup path=
  [[ -r $f ]] || return 0
  IFS= read -r path <"$f" || true
  if [[ $path =~ ^/lxc/([0-9]+)/ ]]; then echo "${BASH_REMATCH[1]}"; fi
}

# drop <node> [ct]: remove the node from every CT directory except ct's
drop() {
  local d
  for d in "$ROOT"/*/; do
    [[ $d == "$ROOT/${2:-}/" ]] || rm -f -- "$d$1"
  done
}

add() {
  local name=$1 ct dir uid major='' minor='' node tmp
  ct=$(owner_ct "$name")
  # The kernel reuses names and minors: a leftover node with this name in another
  # CT's directory would now open this device.
  drop "$name" "$ct"
  [[ -n $ct ]] || return 0
  dir=$ROOT/$ct
  [[ -d $dir ]] || return 0                    # not a CT set up by install.sh
  uid=$(cat "$CONF/$ct.uid" 2>/dev/null)
  [[ $uid =~ ^[0-9]+$ ]] || return 0
  [[ -r $SYS/$name/dev ]] || return 0          # gone again
  IFS=: read -r major minor <"$SYS/$name/dev" || true
  [[ $major == 13 && $minor =~ ^[0-9]+$ ]] || return 0

  node=$dir/$name
  if [[ -c $node && ! -L $node &&
        $(stat -c '%u %a %t %T' "$node") == "$(printf '%s 600 %x %x' "$uid" "$major" "$minor")" ]]; then
    return 0
  fi
  # Finish the node under a name the CT ignores, then rename it into place.
  tmp=$dir/.$name.new
  rm -f -- "$tmp"
  if mknod -m 0600 "$tmp" c "$major" "$minor" && chown "$uid" "$tmp" && mv -fT -- "$tmp" "$node"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

sync() {
  local node name ct s rc=0
  for node in "$ROOT"/*/* "$ROOT"/*/.[!.]*; do
    name=${node##*/}
    ct=${node%/*}; ct=${ct##*/}
    if ! valid "$name" || [[ ! -e $SYS/$name || $(owner_ct "$name") != "$ct" ]]; then
      rm -f -- "$node"
    fi
  done
  for s in "$SYS"/event* "$SYS"/js*; do
    add "${s##*/}" || rc=1
  done
  return $rc
}

[[ -d $ROOT ]] || exit 0                       # no CT uses this yet
exec 9>"$ROOT/.lock" || exit 1
flock 9 || exit 1                              # udev runs one of these per device, in parallel

case ${1:-} in
  add|remove)
    valid "${2:-}" || { echo "cdh-input-node: bad node name '${2:-}'" >&2; exit 2; }
    if [[ $1 == add ]]; then add "$2"; else drop "$2"; fi
    ;;
  sync) sync ;;
  *) echo "usage: cdh-input-node add|remove <eventN|jsN> | sync" >&2; exit 2 ;;
esac
