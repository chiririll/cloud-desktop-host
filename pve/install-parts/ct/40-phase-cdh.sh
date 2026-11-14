# ── phase: release bundle, CDH, Sunshine, Cloud Mouse, Steam ───
# Decides where scripts/configs/binary come from: CDH_LOCAL_BUNDLE or the release. Sets MANIFEST.
phase_bundle() {
  header "Release"
  if [[ -n $CDH_LOCAL_BUNDLE ]]; then
    REPO=$CDH_LOCAL_BUNDLE CDH_BIN=$CDH_LOCAL_BUNDLE/cloud-desktop-host
    [[ -x $CDH_BIN && -d $REPO/scripts ]] || die "CDH_LOCAL_BUNDLE=$CDH_LOCAL_BUNDLE has no cloud-desktop-host + scripts/"
    MANIFEST=$(local_manifest)
    msg_ok "Using local bundle" "$CDH_LOCAL_BUNDLE"
  elif ! command -v curl >/dev/null; then
    BUNDLE_SKIP=1   # only reachable with --check: do_curl installs it otherwise
    msg_warn "no curl yet: the release can't be compared (run without --check once)"
  elif ((CHECK_ONLY)) && fetch_manifest; then
    msg_ok "Release ${CDH_VERSION:-latest} manifest" "bundle not downloaded in check mode"
  else
    ((CHECK_ONLY)) && die "could not read the MANIFEST of release ${CDH_VERSION:-latest} from $CDH_GH_REPO (no $DISTRO_TAG build?)"
    msg_info "Downloading release ${CDH_VERSION:-latest} from $CDH_GH_REPO"
    fetch_release || die "could not download/verify cdh-$DISTRO_TAG-x86_64.tar.gz from $CDH_GH_REPO (${CDH_VERSION:-latest})"
    MANIFEST=$(local_manifest)
    msg_ok "Release ${CDH_VERSION:-latest} downloaded" "sha256 ok"
  fi
}

CDH_INSTALLED=/usr/local/bin/cloud-desktop-host
chk_cdh() {
  [[ -x $CDH_INSTALLED ]] || { why "$CDH_INSTALLED not installed"; return; }
  [[ "$(awk '$2=="cloud-desktop-host"{print $1}' <<<"$MANIFEST")" == "$(sha256sum <"$CDH_INSTALLED" | cut -d' ' -f1)" ]] \
    || why "$CDH_INSTALLED differs from the release/local build"
}
do_cdh() {
  # the previous binary stays as .prev for a one-line rollback; mv instead of cp: the old one may be running
  if [[ -x $CDH_INSTALLED ]]; then cp -p "$CDH_INSTALLED" "$CDH_INSTALLED.prev"; fi
  install -m 0755 "$CDH_BIN" "$CDH_INSTALLED.new"
  mv -f "$CDH_INSTALLED.new" "$CDH_INSTALLED"
}

chk_scripts() {
  [[ -d $CT_CDH ]] || { why "$CT_CDH missing"; return; }
  local out rc=0
  out=$(cd "$CT_CDH" && manifest | sha256sum -c --quiet - 2>/dev/null) || rc=$?
  sed -n 's/: FAILED.*/ differs or is missing/p' <<<"$out"
  return "$rc"
}
do_scripts() {
  mkdir -p "$CT_CDH"
  tar -C "$REPO" -c scripts configs | tar -C "$CT_CDH" --no-same-owner --no-same-permissions -x
  chown -R root:root "$CT_CDH"
  chmod -R u=rwX,go=rX "$CT_CDH"
  chmod 0755 "$CT_CDH"/scripts/*.sh
}

# ── Sunshine ──
# The package is called "Sunshine" (RPM) or "sunshine" (deb): matched case-insensitively.
# SUNSHINE_JSON: the GitHub release (SUNSHINE_VERSION, else latest), loaded once.
sunshine_load() {
  [[ -n ${SUNSHINE_JSON:-} ]] && return 0
  local ep=latest; [[ -z $SUNSHINE_VERSION ]] || ep=tags/$SUNSHINE_VERSION
  SUNSHINE_JSON=$(curl -fsSL "https://api.github.com/repos/LizardByte/Sunshine/releases/$ep") && [[ -n $SUNSHINE_JSON ]]
}
sunshine_tag() { sunshine_load && grep -o '"tag_name": *"[^"]*"' <<<"$SUNSHINE_JSON" | head -1 | sed 's/.*"\([^"]*\)"$/\1/'; }
sunshine_asset() {
  local pat; pat=$(sunshine_pattern)
  sunshine_load && grep -oi '"browser_download_url": *"[^"]*'"$pat"'"' <<<"$SUNSHINE_JSON" | head -1 | sed 's/.*"\(https:[^"]*\)"/\1/'
}
chk_sunshine() {
  local name want have
  name=$(pkg_name_ci sunshine) || { why "Sunshine package not installed"; return; }
  # update mode: the latest (or pinned) release must be installed, unless a package was given explicitly
  ((UPDATE)) && [[ -z $SUNSHINE_PKG ]] || return 0
  want=$(sunshine_tag) || want=''
  if [[ -z $want ]]; then echo "Sunshine: could not look up the latest release, version not compared" >&2; return 0; fi
  have=$(pkg_version "$name")
  [[ $have == "${want#v}"* ]] || why "Sunshine $have installed, $want available"
}
do_sunshine() {
  local src=$SUNSHINE_PKG
  if [[ -z $src ]]; then
    src=$(sunshine_asset) || src=''
    if [[ -z $src ]]; then
      echo "no $DISTRO_TAG asset in the Sunshine release ${SUNSHINE_VERSION:-latest}."
      sunshine_missing_hint
      return 1
    fi
    echo "Sunshine: $src"
  fi
  pkg_install_file "$src" 1   # postinst modprobe/udevadm fail in a container
}

chk_ssconf() { as_user 'test -s ~/.config/sunshine/sunshine.conf && test -s ~/.config/sunshine/apps.json'; }
do_ssconf() {
  local ip origins apps=apps-desktop.json
  ip=$(ct_ip)
  origins="https://$ip:47990${CSRF_EXTRA:+,$CSRF_EXTRA}"
  as_user "mkdir -p ~/.config/sunshine
    test -s ~/.config/sunshine/sunshine.conf || printf '%s\n' \
      'capture = wlr' 'encoder = nvenc' 'gamepad = xone' 'system_tray = disabled' \
      'csrf_allowed_origins = $origins' > ~/.config/sunshine/sunshine.conf"
  if as_user 'test -s ~/.config/sunshine/apps.json'; then return 0; fi
  if ((INSTALL_STEAM)); then apps=apps.json; fi   # no Steam: only the Desktop app
  as_user "cp $CT_CDH/configs/sunshine/$apps ~/.config/sunshine/apps.json"
}

# ── KCM Cloud Mouse ──
# Default: the release asset of this distro. Not built for every release: skip with a warning instead of failing.
CLOUD_MOUSE_REPO=chiririll/kcm-cloud-mouse
cloudmouse_src() {
  echo "${CLOUD_MOUSE_PKG:-https://github.com/$CLOUD_MOUSE_REPO/releases/latest/download/kcm-cloud-mouse-$DISTRO_TAG-x86_64.$(pkg_ext)}"
}
chk_cloudmouse() {
  local want have
  pkg_missing kcm-cloud-mouse || return 1
  ((UPDATE)) && [[ -z $CLOUD_MOUSE_PKG ]] || return 0
  want=$(curl -fsSL "https://api.github.com/repos/$CLOUD_MOUSE_REPO/releases/latest" 2>/dev/null \
    | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/') || want=''
  want=${want#v}; have=$(pkg_version kcm-cloud-mouse)
  # only compare plain numeric versions: an odd tag scheme must not make every update reinstall
  [[ $want =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 0
  [[ $have == "$want"* ]] || why "Cloud Mouse $have installed, $want available"
}
do_cloudmouse() { pkg_install_file "$(cloudmouse_src)"; }
phase_cloudmouse() {
  [[ $CLOUD_MOUSE_PKG != none ]] || return 0
  if [[ -z $CLOUD_MOUSE_PKG ]] && command -v curl >/dev/null && ! curl -fsIL -o /dev/null "$(cloudmouse_src)"; then
    msg_warn "KCM Cloud Mouse: no $DISTRO_TAG build in kcm-cloud-mouse releases, skipped (set CLOUD_MOUSE_PKG=<file> to install your own)"
    return 0
  fi
  step "KCM Cloud Mouse (System Settings → Input Devices)" chk_cloudmouse do_cloudmouse
}

# ── Steam ── (the repo prerequisites differ per distro: chk_/do_steamrepos, see 20-distro.sh)
chk_steam() { local p; mapfile -t p < <(steam_packages); pkg_missing "${p[@]}"; }
do_steam() {
  local p; mapfile -t p < <(steam_packages)
  steam_prepare
  pkg_install "${p[@]}"
}
phase_steam() {
  if ((INSTALL_STEAM)); then
    step "$(steam_repos_label)" chk_steamrepos do_steamrepos
    step "Steam + Gamescope + MangoHud" chk_steam do_steam
    step "Gamescope has no file caps" "chk_nocaps gamescope" "do_nocaps gamescope"
  fi
}

phase_cdh() {
  header "cloud-desktop-host, Sunshine, Steam"
  if ((BUNDLE_SKIP)); then
    msg_warn "CDH binary and scripts: not compared (no release information)"
  else
    step "cloud-desktop-host binary" chk_cdh do_cdh
    step "CDH scripts + configs in $CT_CDH" chk_scripts do_scripts
  fi
  step "Sunshine" chk_sunshine do_sunshine
  step "Sunshine has no file caps (AT_SECURE breaks ENet)" "chk_nocaps sunshine" "do_nocaps sunshine"
  step "Sunshine config (kept if it already exists)" chk_ssconf do_ssconf
  phase_cloudmouse
  phase_steam
}
