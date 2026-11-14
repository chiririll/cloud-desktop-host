# ── interactive/env resolution: which CT, which distro, which options ──
resolve_ctid() {
  if [[ -z $CTID ]]; then
    have_tty || die "no terminal to ask on: set CTID=<id> (and optionally CT_* settings)"
    header "Container"
    if [[ -n "$(pct list 2>/dev/null | tail -n +2)" ]]; then
      echo "   Existing containers:"; pct list | sed 's/^/     /'
    fi
    ask CTID "Container ID (existing to update it, or a free one to create it)" \
      "$(pvesh get /cluster/nextid 2>/dev/null || echo 100)" '^[1-9][0-9]{2,8}$'
  fi
  [[ $CTID =~ ^[1-9][0-9]{2,8}$ ]] || die "CTID must be a number ≥ 100, got '$CTID'"
  CONF=/etc/pve/lxc/$CTID.conf
}

# ── checks before anything is asked or changed ────────────────
preflight() {
  local c missing=()
  [[ $EUID -eq 0 ]] || die "run as root on the Proxmox host"
  for c in pct pveam pvesm pvesh qm curl tar sha256sum awk sed flock udevadm modprobe; do
    command -v "$c" >/dev/null || missing+=("$c")
  done
  ((${#missing[@]} == 0)) || die "missing on the host: ${missing[*]} (is this a Proxmox VE host?)"

  [[ $CT_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "CT_USER '$CT_USER' is not a valid user name"
  [[ $SHM_SIZE =~ ^[0-9]+[KMG]?$ ]] || die "SHM_SIZE must look like 4G, got '$SHM_SIZE'"
  [[ -z $NVIDIA_PCI || $NVIDIA_PCI =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] \
    || die "NVIDIA_PCI must look like 0000:01:00.0, got '$NVIDIA_PCI'"
  [[ $INSTALL_INPUT_GUARD =~ ^[01]$ ]] || die "INSTALL_INPUT_GUARD must be 1 or 0, got '$INSTALL_INPUT_GUARD'"
  pvesm status 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$TEMPLATE_STORAGE" \
    || die "TEMPLATE_STORAGE '$TEMPLATE_STORAGE' is not a Proxmox storage"
}

# values from the environment skip ask(): validate them before a CT is created
validate_new_ct() {
  local n
  for n in CT_DISK CT_CORES CT_MEMORY; do
    [[ ${!n} =~ ^[0-9]+$ ]] || die "$n must be a number, got '${!n}'"
  done
  pvesm status -content rootdir 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$CT_STORAGE" \
    || die "CT_STORAGE '$CT_STORAGE' is not a storage that can hold container disks"
  [[ -d /sys/class/net/$CT_BRIDGE ]] || die "network bridge '$CT_BRIDGE' does not exist on this host"
}

# existing CT → confirm; free ID → ask creation settings and confirm
resolve_ct() {
  if pct status "$CTID" >/dev/null 2>&1; then
    resolve_existing_ct
  elif ((!CHECK_ONLY)); then
    resolve_new_ct
  fi
}

resolve_existing_ct() {
  CT_NAME=$(pct config "$CTID" | awk '/^hostname:/{print $2}')
  ((CHECK_ONLY)) && return 0
  confirm "Install into existing CT $CTID (${CT_NAME:-?})? Its config may be changed and it may be restarted" \
    || die "aborted"
}

resolve_new_ct() {
  local default_storage
  if qm status "$CTID" >/dev/null 2>&1; then die "ID $CTID is used by a VM"; fi
  default_storage=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3=="active"{print $1; exit}' | grep . || echo local-lvm)

  echo "   CT $CTID does not exist and will be created:"
  ask CT_HOSTNAME "Hostname"         "cloud-desktop"   '^[a-zA-Z0-9][a-zA-Z0-9.-]*$'
  ask CT_STORAGE  "Root disk storage" "$default_storage" '^[A-Za-z0-9_.-]+$'
  ask CT_DISK     "Root disk size, GB" 64              '^[0-9]+$'
  ask CT_CORES    "CPU cores"        8                 '^[0-9]+$'
  ask CT_MEMORY   "Memory, MB"       16384             '^[0-9]+$'
  ask CT_BRIDGE   "Network bridge"   vmbr0             '^[A-Za-z0-9_.-]+$'
  resolve_ct_network
  validate_new_ct

  confirm "Create CT $CTID '$CT_HOSTNAME' on $CT_STORAGE (${CT_DISK} GB, $CT_CORES cores, $CT_MEMORY MB, $CT_BRIDGE, ip $CT_IP${CT_GATEWAY:+ via $CT_GATEWAY})?" \
    || die "aborted"
}

# CT_IP = dhcp | a.b.c.d/nn (+ CT_GATEWAY). Env values are validated too, ask() keeps them as is.
resolve_ct_network() {
  ask CT_IP "IPv4 address: dhcp, or static in CIDR form like 192.168.1.50/24" dhcp "^(dhcp|$IPV4_RE/[0-9]{1,2})\$"
  [[ $CT_IP =~ ^(dhcp|$IPV4_RE/[0-9]{1,2})$ ]] || die "CT_IP must be 'dhcp' or a.b.c.d/nn, got '$CT_IP'"
  if [[ $CT_IP == dhcp ]]; then CT_GATEWAY=''; return 0; fi
  ask CT_GATEWAY "Gateway" "$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')" "^$IPV4_RE\$"
  [[ $CT_GATEWAY =~ ^$IPV4_RE$ ]] || die "static CT_IP needs CT_GATEWAY=a.b.c.d, got '${CT_GATEWAY:-}'"
}

# DISTRO = fedora-NN | ubuntu-NN.NN. An existing running CT decides for itself.
resolve_distro() {
  local ct_distro
  if [[ -n $CT_NAME ]] && ct_up; then
    ct_distro=$(ct sh -c '. /etc/os-release && echo "$ID-$VERSION_ID"' 2>/dev/null || true)
    if [[ -n $ct_distro ]]; then
      [[ -z $DISTRO || $DISTRO == "$ct_distro" ]] || die "CT $CTID runs $ct_distro but $DISTRO was requested (upgrade or recreate the CT first)"
      DISTRO=$ct_distro
    fi
  fi
  if [[ -z $DISTRO ]]; then
    if [[ -z $CT_NAME ]] && ((!CHECK_ONLY)); then
      ask DISTRO "Distro (${SUPPORTED_DISTROS[*]})" "$DEFAULT_DISTRO" '^[a-z]+-[0-9.]+$'
    else
      DISTRO=$DEFAULT_DISTRO
    fi
  fi
  is_supported_distro "$DISTRO" || die "'$DISTRO' has no release bundle; supported: ${SUPPORTED_DISTROS[*]}"
  OS_TYPE=${DISTRO%%-*}
}

resolve_options() {
  if [[ -z $INSTALL_STEAM ]]; then
    confirm "Install Steam + Gamescope + MangoHud?" y && INSTALL_STEAM=1 || INSTALL_STEAM=0
  fi
  [[ $INSTALL_STEAM =~ ^[01]$ ]] || die "INSTALL_STEAM must be 1 or 0, got '$INSTALL_STEAM'"
  [[ $INSTALL_UPDATE_TIMER =~ ^[01]$ ]] || die "INSTALL_UPDATE_TIMER must be 1 or 0, got '$INSTALL_UPDATE_TIMER'"
  ((!FORCE_RESTART || UPDATE)) || die "--force-restart only makes sense with --update"
}
