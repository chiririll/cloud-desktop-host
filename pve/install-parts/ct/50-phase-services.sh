# ── phase: user service ────────────────────────────────────────
# The whole stack (compositor, KWin, Plasma, Sunshine) as a user service,
# started at boot thanks to linger. Last, so it starts with everything installed.
SESSION_UNIT=cloud-desktop-host.service
SESSION_UNIT_FILE=/etc/systemd/user/$SESSION_UNIT
session_unit_txt() { render_file systemd/cloud-desktop-host.service CT_CDH; }
chk_session() {
  [[ "$(cat "$SESSION_UNIT_FILE" 2>/dev/null)" == "$(session_unit_txt)" ]] \
    || { why "$SESSION_UNIT_FILE missing or outdated"; return; }
  user_systemctl is-enabled -q "$SESSION_UNIT" || why "$SESSION_UNIT not enabled for '$CT_USER'"
}
do_session() {
  mkdir -p "${SESSION_UNIT_FILE%/*}"
  session_unit_txt >"$SESSION_UNIT_FILE"
  rm -f /etc/systemd/user/cdh-sunshine.service   # earlier Sunshine-only unit
  user_systemctl daemon-reload
  user_systemctl enable --now "$SESSION_UNIT"
}

phase_services() {
  header "Session"
  step "user service $SESSION_UNIT (starts at boot)" chk_session do_session
  SESSION_APPLIED=$APPLIED
}
