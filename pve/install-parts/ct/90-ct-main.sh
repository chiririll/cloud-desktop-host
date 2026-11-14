# ── main: the order of things lives here ───────────────────────
# To add a step: write chk_*/do_* in the matching phase part and call `step` from its phase_* function.
preflight() {
  local c missing=()
  [[ $EUID -eq 0 ]] || die "run as root"
  for c in awk sed tar sha256sum getent runuser useradd; do
    command -v "$c" >/dev/null || missing+=("$c")
  done
  if ((${#missing[@]})); then die "missing: ${missing[*]}"; fi
  [[ $CT_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "CT_USER '$CT_USER' is not a valid user name"
  [[ $INSTALL_STEAM =~ ^[01]$ ]] || die "INSTALL_STEAM must be 1 or 0, got '$INSTALL_STEAM'"
  [[ $INSTALL_UPDATE_TIMER =~ ^[01]$ ]] || die "INSTALL_UPDATE_TIMER must be 1 or 0, got '$INSTALL_UPDATE_TIMER'"
  [[ $CDH_INPUT_ISOLATED =~ ^(0|1|keep)$ ]] || die "CDH_INPUT_ISOLATED must be 0, 1 or keep, got '$CDH_INPUT_ISOLATED'"
  if ((!CHECK_ONLY)); then mkdir -p "${LOG%/*}" && : >>"$LOG"; fi
}

cleanup() { if [[ -n $BUNDLE_TMP ]]; then rm -rf -- "$BUNDLE_TMP"; fi; }

main() {
  parse_args "$@"
  trap cleanup EXIT
  detect_distro
  preflight
  if ((CHECK_ONLY)); then echo "${YW}check mode: nothing will be changed${CL}"; fi
  echo "${DM}$DISTRO $DISTRO_VERSION ($DISTRO_TAG)$( ((UPDATE)) && echo ', update mode')${CL}"

  header "Bootstrap"
  step "curl + CA certificates (to download releases)" chk_curl do_curl
  phase_bundle
  phase_system
  phase_update_pkgs
  phase_cdh
  phase_services
  phase_update_timer
  phase_update_finish

  echo
  if ((CHECK_ONLY)); then
    if ((NEEDED)); then echo "${YW}$NEEDED step(s) needed.${CL} Run without --check to apply."
    else echo "${GN}Everything is in place.${CL}"; fi
    echo "NEEDED=$NEEDED"
    if ((NEEDED)); then exit 10; fi
    exit 0
  fi
  echo "${GN}Done.${CL} Log: $LOG"
  if ((RESTART_CT)); then exit 11; fi
  if ((SESSION_RESTARTED)); then exit 12; fi
  exit 0
}

main "$@"
