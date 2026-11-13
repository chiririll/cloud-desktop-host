# ── interactive/env resolution: which CT, which Fedora, which options ──
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

resolve_fedora() {
  local ct_fedora
  if [[ -n $CT_NAME ]] && ct_up; then   # existing running CT: its release decides
    ct_fedora=$(ct sh -c '. /etc/os-release && [ "$ID" = fedora ] && echo "$VERSION_ID"' 2>/dev/null || true)
    if [[ -n $ct_fedora ]]; then
      [[ -z $FEDORA || $FEDORA == "$ct_fedora" ]] || die "CT $CTID runs Fedora $ct_fedora but Fedora $FEDORA was requested (upgrade or recreate the CT first)"
      FEDORA=$ct_fedora
    fi
  fi
  if [[ -z $FEDORA ]]; then
    if [[ -z $CT_NAME ]] && ((!CHECK_ONLY)); then
      ask FEDORA "Fedora release (${SUPPORTED_FEDORA[*]})" "$DEFAULT_FEDORA" '^[0-9]+$'
    else
      FEDORA=$DEFAULT_FEDORA
    fi
  fi
  is_supported_fedora "$FEDORA" || die "Fedora '$FEDORA' has no release bundle; supported: ${SUPPORTED_FEDORA[*]}"
}

# depends on FEDORA
resolve_options() {
  if [[ -z $CLOUD_MOUSE_RPM ]]; then
    CLOUD_MOUSE_DEFAULT=1
    CLOUD_MOUSE_RPM=https://github.com/chiririll/kcm-cloud-mouse/releases/latest/download/kcm-cloud-mouse-fc$FEDORA-x86_64.rpm
  fi
  if [[ -z $INSTALL_STEAM ]]; then
    confirm "Install Steam + Gamescope + MangoHud?" y && INSTALL_STEAM=1 || INSTALL_STEAM=0
  fi
  [[ $INSTALL_STEAM =~ ^[01]$ ]] || die "INSTALL_STEAM must be 1 or 0, got '$INSTALL_STEAM'"
}
