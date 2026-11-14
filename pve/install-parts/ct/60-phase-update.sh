# ── update mode (--update) ─────────────────────────────────────
# Not a separate script: the step engine already means "make the system match the target". Update mode moves
# the target to "latest" (version checks in chk_sunshine / chk_cloudmouse, the release bundle, which is
# `latest` unless CDH_VERSION is pinned) and adds the package upgrade and the session restart below.

chk_upgrades() {
  local n; n=$(pkg_upgrades)
  ((n == 0)) || why "$n package(s) can be upgraded"
}
do_upgrades() { pkg_upgrade; }

# Runs before the Sunshine/Gamescope no-caps steps: a Sunshine package upgrade restores its file
# capability and ENet then breaks silently (AT_SECURE).
phase_update_pkgs() {
  ((UPDATE)) || return 0
  step "distro packages up to date" chk_upgrades do_upgrades
}

# Weekly update from inside the container. The settings are kept in /etc/cdh/ct-install.env.
UPDATE_ENV=/etc/cdh/ct-install.env
update_env_txt() {
  printf '%s=%s\n' CT_USER "$CT_USER" INSTALL_STEAM "$INSTALL_STEAM" CDH_INPUT_ISOLATED "$CDH_INPUT_ISOLATED" \
    CDH_GH_REPO "$CDH_GH_REPO" CDH_VERSION "$CDH_VERSION" SUNSHINE_VERSION "$SUNSHINE_VERSION" \
    CSRF_EXTRA "$CSRF_EXTRA" CT_CDH "$CT_CDH"
}
update_unit_txt() { local RELEASE_BASE; RELEASE_BASE=$(release_base); render_file "systemd/$1" RELEASE_BASE; }
chk_updtimer() {
  [[ "$(cat $UPDATE_ENV 2>/dev/null)" == "$(update_env_txt)" ]] || { why "$UPDATE_ENV missing or outdated"; return; }
  local u
  for u in cdh-update.service cdh-update.timer; do
    [[ "$(cat "/etc/systemd/system/$u" 2>/dev/null)" == "$(update_unit_txt "$u")" ]] || { why "$u missing or outdated"; return; }
  done
  systemctl is-enabled -q cdh-update.timer || why "cdh-update.timer not enabled"
}
do_updtimer() {
  local u
  mkdir -p "${UPDATE_ENV%/*}"
  update_env_txt >"$UPDATE_ENV"
  for u in cdh-update.service cdh-update.timer; do update_unit_txt "$u" >"/etc/systemd/system/$u"; done
  systemctl daemon-reload
  systemctl enable --now cdh-update.timer
}
phase_update_timer() {
  [[ $INSTALL_UPDATE_TIMER == 1 ]] || return 0
  step "weekly update timer (cdh-update.timer)" chk_updtimer do_updtimer
}

# A Moonlight client is streaming: the prep scripts create the marker, the undo scripts remove it.
client_connected() { [[ -e "/run/user/$(id -u "$CT_USER")/cdh/stream-active" ]]; }

# After any change: restart the session so it runs the new versions, unless somebody is playing.
phase_update_finish() {
  local changed=$((APPLIED_ANY - SESSION_APPLIED))   # the session step starts the unit itself
  ((UPDATE && !CHECK_ONLY)) || return 0
  if ((changed <= 0)); then msg_ok "Session unchanged" "nothing was updated"; return 0; fi
  header "Restarting the session"
  if client_connected && ((!FORCE_RESTART)); then
    msg_warn "$changed step(s) updated, but a client is streaming: session not restarted. Restart when done: systemctl --user restart $SESSION_UNIT (as $CT_USER), or re-run with --force-restart"
    return 0
  fi
  user_systemctl restart "$SESSION_UNIT" || die "could not restart $SESSION_UNIT"
  SESSION_RESTARTED=1
  msg_ok "Session restarted" "$changed step(s) updated"
}
