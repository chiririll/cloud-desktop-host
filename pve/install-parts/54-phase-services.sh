# ── phase: user service ────────────────────────────────────────
# The whole stack (compositor, KWin, Plasma, Sunshine) as a user service,
# started at boot thanks to linger. Last, so it starts with everything installed.
SESSION_UNIT=cloud-desktop-host.service
SESSION_UNIT_FILE=/etc/systemd/user/$SESSION_UNIT
session_unit_txt() {
  cat <<EOF
[Unit]
Description=cloud-desktop-host session (compositor, KWin, Plasma, Sunshine)

[Service]
Type=simple
# run.sh starts its own D-Bus session (dbus-launch) when this is unset
UnsetEnvironment=DBUS_SESSION_BUS_ADDRESS
ExecStart=$CT_CDH/scripts/run.sh
# run.sh exits when the compositor dies: bring the whole stack back
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
}
chk_session() {
  [[ "$(ct cat "$SESSION_UNIT_FILE" 2>/dev/null)" == "$(session_unit_txt)" ]] \
    || { why "$SESSION_UNIT_FILE missing or outdated"; return; }
  ct_systemctl is-enabled -q "$SESSION_UNIT" || why "$SESSION_UNIT not enabled for '$CT_USER'"
}
do_session() {
  session_unit_txt | pct exec "$CTID" -- sh -c "mkdir -p ${SESSION_UNIT_FILE%/*} && cat > $SESSION_UNIT_FILE"
  ct rm -f /etc/systemd/user/cdh-sunshine.service   # earlier Sunshine-only unit
  ct_systemctl daemon-reload
  ct_systemctl enable --now "$SESSION_UNIT"
}

phase_services() {
  step "user service $SESSION_UNIT (starts at boot)" chk_session do_session
}

phase_summary() {
  local ip
  echo
  if ((CHECK_ONLY)); then
    if ((NEEDED)); then echo "${YW}$NEEDED step(s) needed.${CL} Run without --check to apply."
    else echo "${GN}Everything is in place.${CL}"; fi
    return 0
  fi
  ip=$(ct_ip)
  cat <<EOF
${GN}Done.${CL} Log: $LOG
  Session: runs at boot as $CT_USER's user service $SESSION_UNIT. Control it with:
    pct exec $CTID -- runuser -l $CT_USER -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user restart $SESSION_UNIT'
    logs: journalctl --user -u $SESSION_UNIT, and /tmp/cdhost-logs/ in the CT
  Web UI:  https://$ip:47990   (create the Sunshine login on first visit)
  Moonlight: add $ip, enter the PIN in the web UI.
  Set a password for '$CT_USER' if you need it:  pct exec $CTID -- passwd $CT_USER
EOF
}
