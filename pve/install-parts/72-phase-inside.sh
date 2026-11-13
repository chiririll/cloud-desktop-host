# ── phase: inside the container (system, GPU userspace, Sunshine, Steam) ──
UDEV_FSTAB_LINE='/mnt/host-udev  /run/udev  none  bind,ro  0 0'
chk_udevdb() { ct grep -qxF "$UDEV_FSTAB_LINE" /etc/fstab && ct_sh 'ls /run/udev/data | grep -q .'; }
do_udevdb() {
  ct_sh "grep -qxF '$UDEV_FSTAB_LINE' /etc/fstab || echo '$UDEV_FSTAB_LINE' >> /etc/fstab"
  ct_sh 'mountpoint -q /run/udev && ls /run/udev/data >/dev/null 2>&1 || mount /run/udev'
}

# Sunshine's virtual input devices must be owned by the CT user's uid as seen from the host
INPUT_RULE=/etc/udev/rules.d/60-lxc-virtual-input.rules
host_uid() { local u; u=$(ct id -u "$CT_USER" 2>/dev/null) || u=''; echo $((100000 + ${u:-1000})); }
input_rule_txt() { echo "SUBSYSTEM==\"input\", KERNEL==\"event*\", DEVPATH==\"/devices/virtual/input/*\", OWNER=\"$(host_uid)\", MODE=\"0600\""; }
chk_inrule() { [[ "$(cat $INPUT_RULE 2>/dev/null)" == "$(input_rule_txt)" ]]; }
do_inrule()  { input_rule_txt >$INPUT_RULE; udevadm control --reload; }

chk_pkgs() { rpm_missing "${CT_PACKAGES[@]}"; }
do_pkgs()  { ct dnf install -y "${CT_PACKAGES[@]}"; }

chk_nvuser() { local drv; drv=$(host_driver) && [[ -n $drv ]] && ct test -e "/usr/lib64/libnvidia-glcore.so.$drv"; }
do_nvuser() {
  local drv; drv=$(host_driver)
  ct curl -fsSLo /tmp/nvidia.run "https://download.nvidia.com/XFree86/Linux-x86_64/$drv/NVIDIA-Linux-x86_64-$drv.run"
  ct sh /tmp/nvidia.run --no-kernel-module --install-compat32-libs -s
  ct rm -f /tmp/nvidia.run
}

chk_smi() { ct nvidia-smi -L; }

chk_linger() { ct test -e "/var/lib/systemd/linger/$CT_USER"; }
do_linger()  { ct loginctl enable-linger "$CT_USER"; }

chk_cdh() {
  ct test -x /usr/local/bin/cloud-desktop-host || { why "/usr/local/bin/cloud-desktop-host not installed"; return; }
  [[ "$(awk '$2=="cloud-desktop-host"{print $1}' <<<"$MANIFEST")" == "$(ct sha256sum /usr/local/bin/cloud-desktop-host | cut -d' ' -f1)" ]] \
    || why "/usr/local/bin/cloud-desktop-host differs from the release/local build"
}
do_cdh()  { pct push "$CTID" "$CDH_BIN" /usr/local/bin/cloud-desktop-host --perms 0755; }

manifest() { grep -E '  (scripts|configs)/' <<<"$MANIFEST"; }
chk_scripts() { manifest | pct exec "$CTID" -- sh -c "cd $CT_CDH 2>/dev/null || { echo '$CT_CDH missing'; exit 1; }
    out=\$(sha256sum -c --quiet - 2>/dev/null); rc=\$?
    printf '%s\n' \"\$out\" | sed -n 's/: FAILED.*/ differs or is missing/p'; exit \$rc"; }
do_scripts() {
  tar -C "$REPO" -c scripts configs | pct exec "$CTID" -- sh -c "mkdir -p $CT_CDH &&
    tar -C $CT_CDH --no-same-owner --no-same-permissions -x &&
    chown -R root:root $CT_CDH && chmod -R u=rwX,go=rX $CT_CDH && chmod 0755 $CT_CDH/scripts/*.sh"
}

# ── Sunshine ──
# The RPM is named "Sunshine" (capital S): match case-insensitively
chk_sunshine() { ct_sh 'rpm -qa --qf "%{NAME}\n" | grep -qix sunshine' || why "Sunshine RPM not installed"; }
latest_sunshine_rpm() {
  curl -fsSL https://api.github.com/repos/LizardByte/Sunshine/releases/latest \
    | grep -o '"browser_download_url": *"[^"]*\.fc'"$FEDORA"'\.x86_64\.rpm"' \
    | head -1 | sed 's/.*"\(https:[^"]*\)"/\1/'
}
do_sunshine() {
  if [[ -z $SUNSHINE_RPM ]]; then
    SUNSHINE_RPM=$(latest_sunshine_rpm)
    [[ -n $SUNSHINE_RPM ]] || { echo "no fc$FEDORA x86_64 RPM in latest Sunshine release"; return 1; }
    echo "Sunshine: $SUNSHINE_RPM"
  fi
  ct_install_rpm "$SUNSHINE_RPM" 1   # postinst modprobe/udevadm fail in a CT
}

chk_ssconf() { ct_user 'test -s ~/.config/sunshine/sunshine.conf && test -s ~/.config/sunshine/apps.json'; }
do_ssconf() {
  local ip origins apps=apps-desktop.json
  ip=$(ct_ip)
  origins="https://$ip:47990${CSRF_EXTRA:+,$CSRF_EXTRA}"
  ct_user "mkdir -p ~/.config/sunshine
    test -s ~/.config/sunshine/sunshine.conf || printf '%s\n' \
      'capture = wlr' 'encoder = nvenc' 'gamepad = xone' 'system_tray = disabled' \
      'csrf_allowed_origins = $origins' > ~/.config/sunshine/sunshine.conf"
  if ct_user 'test -s ~/.config/sunshine/apps.json'; then return 0; fi
  if ((INSTALL_STEAM)); then apps=apps.json; fi   # no Steam: only the Desktop app
  ct_user "cp $CT_CDH/configs/sunshine/$apps ~/.config/sunshine/apps.json"
}

# ── KCM Cloud Mouse ──
# The default RPM is only built for some Fedora releases: skip with a warning instead of failing.
chk_cloudmouse() { rpm_missing kcm-cloud-mouse; }
do_cloudmouse()  { ct_install_rpm "$CLOUD_MOUSE_RPM"; }
phase_cloudmouse() {
  if ((CLOUD_MOUSE_DEFAULT)) && ! curl -fsIL -o /dev/null "$CLOUD_MOUSE_RPM"; then
    msg_warn "KCM Cloud Mouse: no fc$FEDORA build in kcm-cloud-mouse releases, skipped (set CLOUD_MOUSE_RPM=<rpm> to install your own)"
    return 0
  fi
  if [[ $CLOUD_MOUSE_RPM != none ]]; then
    step "KCM Cloud Mouse (System Settings → Input Devices)" chk_cloudmouse do_cloudmouse
  fi
}

# ── Steam ──
chk_rpmfusion() { rpm_missing rpmfusion-nonfree-release; }
do_rpmfusion()  { ct dnf install -y "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$FEDORA.noarch.rpm"; }
chk_steam() { rpm_missing steam gamescope mangohud; }
do_steam()  { ct dnf install -y steam gamescope mangohud; }
phase_steam() {
  if ((INSTALL_STEAM)); then
    step "RPM Fusion nonfree" chk_rpmfusion do_rpmfusion
    step "Steam + Gamescope + MangoHud" chk_steam do_steam
    step "Gamescope has no file caps" "chk_nocaps gamescope" "do_nocaps gamescope"
  fi
}

phase_inside() {
  header "Inside the container"
  step "host udev db at /run/udev" chk_udevdb do_udevdb
  step "host udev rule: Sunshine virtual input → host uid $(host_uid)" chk_inrule do_inrule
  step "packages (KWin, Plasma, PipeWire, Xwayland…)" chk_pkgs do_pkgs
  step "NVIDIA userspace $(host_driver || true) (matches host)" chk_nvuser do_nvuser
  require "nvidia-smi works in CT" chk_smi "check devN entries and driver version, see $LOG"
  step "linger for '$CT_USER'" chk_linger do_linger
  step "cloud-desktop-host binary" chk_cdh do_cdh
  step "CDH scripts + configs in $CT_CDH" chk_scripts do_scripts
  step "Sunshine" chk_sunshine do_sunshine
  step "Sunshine has no file caps (AT_SECURE breaks ENet)" "chk_nocaps sunshine" "do_nocaps sunshine"
  step "Sunshine config (kept if it already exists)" chk_ssconf do_ssconf
  phase_cloudmouse
  phase_steam
}
