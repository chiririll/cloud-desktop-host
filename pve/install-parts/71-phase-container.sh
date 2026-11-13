# ── phase: the LXC container itself (config, devices, restart) ──
template() { pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk -v p="fedora-$FEDORA-default" '$1 ~ p {print $1}' | sort | tail -1; }
chk_template() { pct status "$CTID" >/dev/null 2>&1 || [[ -n "$(template)" ]]; }
do_template() {
  pveam update
  local t; t=$(pveam available --section system | awk -v p="fedora-$FEDORA-default" '$2 ~ p {print $2}' | sort | tail -1)
  [[ -n $t ]] || { echo "no fedora-$FEDORA template in pveam"; return 1; }
  pveam download "$TEMPLATE_STORAGE" "$t"
}

chk_ct() { pct status "$CTID" >/dev/null 2>&1; }
do_ct() {
  pct create "$CTID" "$(template)" \
    --unprivileged 1 --features nesting=1,fuse=1 --ostype fedora \
    --hostname "$CT_HOSTNAME" --cores "$CT_CORES" --memory "$CT_MEMORY" --swap 1024 \
    --rootfs "$CT_STORAGE:$CT_DISK" --net0 "name=eth0,bridge=$CT_BRIDGE,ip=$CT_IP${CT_GATEWAY:+,gw=$CT_GATEWAY}"
}

chk_unpriv() { grep -q '^unprivileged: 1' "$CONF" && ! grep -q '^lxc.idmap' "$CONF"; }

chk_nesting() { pct config "$CTID" | grep -q '^features:.*nesting=1'; }
do_nesting()  { pct set "$CTID" --features nesting=1,fuse=1; }

chk_running() { ct_up; }
do_running()  { pct start "$CTID"; sleep 5; }

# raw lxc.* keys, kept in the main section (before any [snapshot])
raw_lines() {
  cat <<EOF
lxc.cgroup2.devices.allow: c 13:* rwm
lxc.mount.entry: /dev/input dev/input none bind,optional,create=dir
lxc.mount.entry: /run/udev mnt/host-udev none bind,ro,optional,create=dir
lxc.cap.drop:
lxc.cap.drop: mac_admin mac_override sys_module sys_pacct sys_rawio sys_time
lxc.mount.entry: tmpfs dev/shm tmpfs rw,nosuid,nodev,mode=1777,size=$SHM_SIZE,create=dir 0 0
EOF
}
main_conf() { sed -e '/^\[/,$d' -e 's/[[:space:]]*$//' "$CONF"; }   # pve may keep "key: " with a trailing space
missing_raw() { local l; while IFS= read -r l; do main_conf | grep -qxF "$l" || echo "$l"; done < <(raw_lines); }
chk_raw() { local m; m=$(missing_raw); [[ -z $m ]] || { sed 's/^/missing: /' <<<"$m"; return 1; }; }
do_raw() {
  local add tmp; add=$(missing_raw)
  # "lxc.cap.drop:" (reset) must come right before the explicit list
  if grep -q '^lxc.cap.drop: mac_admin' <<<"$add" || grep -qx 'lxc.cap.drop:' <<<"$add"; then
    sed -i '1,/^\[/{/^lxc\.cap\.drop:/d}' "$CONF"   # main section only
    add=$(missing_raw)
  fi
  tmp=$(mktemp)
  ADD="$add" awk 'BEGIN{a=ENVIRON["ADD"]} /^\[/ && !d {print a; d=1} {print} END{if(!d) print a}' "$CONF" >"$tmp"
  cat "$tmp" >"$CONF"   # not mv: /etc/pve is pmxcfs
  rm -f "$tmp"
}

chk_user() {
  ct id "$CT_USER" >/dev/null 2>&1 || { why "user '$CT_USER' does not exist"; return; }
  local g groups; groups=$(ct id -nG "$CT_USER")
  for g in render input; do
    grep -qw "$g" <<<"$groups" || { why "'$CT_USER' is not in group $g"; return; }
  done
}
do_user() {
  ct_sh "id $CT_USER >/dev/null 2>&1 || useradd -m $CT_USER"
  ct usermod -aG video,render,input,wheel "$CT_USER"
}

# GPU/uinput passthrough entries (devN) wanted in the CT config, one per line
desired_devs() {
  local v r i card render minor p
  v=$(ct_gid video) r=$(ct_gid render) i=$(ct_gid input)
  [[ -n $v && -n $r && -n $i ]] || return 1
  card=$(drm_node card) render=$(drm_node renderD) minor=$(nvidia_minor)
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
  local want key val spec n; want=$(desired_devs)
  # drop stale GPU/input entries (e.g. cardN renumbered after a reboot)
  while read -r key val; do
    [[ $val =~ ^/dev/(nvidia|dri/|uinput) ]] || continue
    grep -qxF "$val" <<<"$want" || pct set "$CTID" --delete "$key"
  done < <(current_devs)
  while read -r spec; do
    current_devs | cut -d' ' -f2- | grep -qxF "$spec" && continue
    n=0; while current_devs | grep -q "^dev$n "; do n=$((n + 1)); done
    pct set "$CTID" --"dev$n" "$spec"
  done <<<"$want"
}

phase_container() {
  header "Container $CTID${CT_NAME:+ ($CT_NAME)}"
  step "Fedora $FEDORA template" chk_template do_template
  step "CT exists" chk_ct do_ct
  require "CT is unprivileged (default idmap)" chk_unpriv \
    "CT $CTID is privileged or uses a custom lxc.idmap; this script assumes uid shift 100000"

  step "features nesting=1 (Steam bubblewrap)" chk_nesting do_nesting
  restart_if_applied
  step "CT running" chk_running do_running
  step "lxc.conf: input bind, host udev, caps, /dev/shm" chk_raw do_raw
  restart_if_applied
  step "CT user '$CT_USER' (video,render,input,wheel)" chk_user do_user
  step "GPU/uinput passthrough ($(drm_node card 2>/dev/null), $(drm_node renderD 2>/dev/null))" chk_devs do_devs
  restart_if_applied

  if ((RESTART_CT && !CHECK_ONLY)); then
    msg_info "Restarting CT (full stop/start to apply config)"
    { pct stop "$CTID" && pct start "$CTID" && sleep 5; } >>"$LOG" 2>&1 || die "CT restart failed, see $LOG"
    msg_ok "CT restarted"
  fi
}
