# ── phase: run ct-install.sh inside the container ──────────────
# Everything inside the CT (udev db, packages, NVIDIA userspace, CDH, Sunshine, Steam, the user
# service, and in --update mode the upgrades) is pve/ct-install.sh. It is pushed in instead of
# fetched there: a fresh CT has no curl. Contract (env vars, exit codes): see its header.
CT_TMP=/tmp/cdh-ct

# a local build (checkout with dist/) replaces the release download inside the CT
local_build() { [[ -z $CDH_VERSION && -x $CDH_BIN && -d $REPO/scripts ]]; }

# CT_INSTALLER: the checkout's copy; else the same ref install.sh itself comes from (CDH_REF, default main),
# so the two halves never differ; with CDH_VERSION pinned, that release's asset (verified against SHA256SUMS)
find_ct_installer() {
  [[ -f $CT_INSTALLER ]] && return 0
  BUNDLE_TMP=$(mktemp -d /tmp/cdh-release.XXXXXX)
  CT_INSTALLER=$BUNDLE_TMP/ct-install.sh
  if [[ -n $CDH_VERSION && $CDH_VERSION != latest ]]; then
    fetch_release_file ct-install.sh "$CT_INSTALLER" \
      || die "could not download/verify ct-install.sh of release $CDH_VERSION from $CDH_GH_REPO"
  else
    curl -fsSL -o "$CT_INSTALLER" "https://raw.githubusercontent.com/$CDH_GH_REPO/$CDH_REF/pve/ct-install.sh" \
      || die "could not download pve/ct-install.sh from $CDH_GH_REPO@$CDH_REF; run from a checkout or set CDH_REF/CDH_VERSION"
  fi
}

# push_pkg <VAR>: when $VAR is a local file on the host, push it into the CT and point VAR at the copy
push_pkg() {
  local var=$1 src=${!1} dst
  [[ -n $src && -f $src ]] || return 0
  dst=$CT_TMP/${var%_PKG}.${src##*.}
  pct push "$CTID" "$src" "$dst"
  printf -v "$var" '%s' "$dst"
}

restart_ct() {
  msg_info "Restarting CT (full stop/start to apply config)"
  { pct stop "$CTID" && pct start "$CTID" && sleep 5; } >>"$LOG" 2>&1 || die "CT restart failed, see $LOG"
  msg_ok "CT restarted"
}

phase_run_inside() {
  local out rc=0 n flags=() vars
  find_ct_installer
  ct mkdir -p "$CT_TMP"
  pct push "$CTID" "$CT_INSTALLER" "$CT_TMP/ct-install.sh" --perms 0755
  push_pkg SUNSHINE_PKG
  push_pkg CLOUD_MOUSE_PKG
  if local_build; then
    ct mkdir -p "$CT_TMP/bundle"
    tar -C "$REPO" -c scripts configs | pct exec "$CTID" -- tar -C "$CT_TMP/bundle" -x
    pct push "$CTID" "$CDH_BIN" "$CT_TMP/bundle/cloud-desktop-host" --perms 0755
  fi

  vars=(CT_USER="$CT_USER" INSTALL_STEAM="$INSTALL_STEAM" CT_CDH="$CT_CDH"
    CDH_INPUT_ISOLATED="$(input_isolation_mode)"
    CDH_GH_REPO="$CDH_GH_REPO" CDH_VERSION="$CDH_VERSION" CSRF_EXTRA="$CSRF_EXTRA"
    SUNSHINE_PKG="$SUNSHINE_PKG" SUNSHINE_VERSION="$SUNSHINE_VERSION" CLOUD_MOUSE_PKG="$CLOUD_MOUSE_PKG"
    INSTALL_UPDATE_TIMER="$INSTALL_UPDATE_TIMER" CDH_COLOR="$([[ -t 1 ]] && echo 1 || echo 0)")
  if local_build; then vars+=(CDH_LOCAL_BUNDLE="$CT_TMP/bundle"); fi
  if ((CHECK_ONLY)); then flags+=(--check); fi
  if ((UPDATE)); then flags+=(--update); fi
  if ((FORCE_RESTART)); then flags+=(--force-restart); fi

  out=$(mktemp)
  set +e
  pct exec "$CTID" -- env "${vars[@]}" bash "$CT_TMP/ct-install.sh" "${flags[@]}" 2>&1 | tee "$out" | sed '/^NEEDED=/d'
  rc=${PIPESTATUS[0]}
  set -e
  ct rm -rf "$CT_TMP" || true

  case $rc in
    0|12) ;;   # 12: the user session was restarted (update mode), informational
    10) n=$(sed -n 's/^NEEDED=//p' "$out" | tail -1); NEEDED=$((NEEDED + ${n:-0})) ;;
    11) RESTART_CT=1 ;;
    *) rm -f "$out"; die "ct-install.sh failed inside CT $CTID (exit $rc), see its output above and $LOG_CT in the CT" ;;
  esac
  rm -f "$out"
  if ((RESTART_CT && !CHECK_ONLY && rc == 11)); then restart_ct; fi
}

phase_summary() {
  local ip
  echo
  if ((CHECK_ONLY)); then
    if ((NEEDED)); then echo "${YW}$NEEDED step(s) needed.${CL} Run without --check to apply."
    elif ((SKIPPED)); then echo "${YW}Nothing needed in what could be checked,${CL} but the CT itself was not checked: see the warning above."
    else echo "${GN}Everything is in place.${CL}"; fi
    return 0
  fi
  ip=$(ct_ip)
  cat <<EOT
${GN}Done.${CL} Log: $LOG (host), $LOG_CT (in the CT)
  Session: runs at boot as $CT_USER's user service cloud-desktop-host.service. Control it with:
    pct exec $CTID -- runuser -l $CT_USER -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user restart cloud-desktop-host.service'
    logs: journalctl --user -u cloud-desktop-host.service, and /tmp/cdhost-logs/ in the CT
  Web UI:  https://$ip:47990   (create the Sunshine login on first visit)
  Moonlight: add $ip, enter the PIN in the web UI.
  Set a password for '$CT_USER' if you need it:  pct exec $CTID -- passwd $CT_USER
  Update later:  install.sh --update   (--check --update first to see what would change)
EOT
}
