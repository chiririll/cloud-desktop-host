# ── step engine ────────────────────────────────────────────────
# step "description" check apply
#   check/apply are function names; extra words become arguments
#   ("chk_nocaps sunshine"), so one pair of functions can serve several steps.
#   Checks print WHY they fail (one reason per line, see why()); shown under "needed".
#   Globals: CHECK_ONLY (read), NEEDED (counted in --check), APPLIED (set to 1 if applied).
# require "description" check "hint": a check we can't fix automatically.
why()  { echo "$*"; return 1; }
show_why() { [[ -n $1 ]] && sed -n '1,8p' <<<"$1" | sed "s/^/     $DM/; s/\$/$CL/"; return 0; }

step() {
  local name=$1 check=$2 apply=$3 rc out
  APPLIED=0
  if out=$($check 2>&1); then msg_ok "$name"; return 0; fi
  if ((CHECK_ONLY)); then msg_todo "$name"; show_why "$out"; NEEDED=$((NEEDED + 1)); return 0; fi
  msg_info "$name"
  printf '=== %s %s\n%s\n' "$(date -Is)" "$name" "$out" >>"$LOG"
  set +e; ( set -e; $apply ) >>"$LOG" 2>&1; rc=$?; set -e
  ((rc == 0)) || die "$name: failed (exit $rc), see $LOG"
  if ! out=$($check 2>&1); then
    printf '\r\e[K'; show_why "$out"; die "$name: still not satisfied after applying, see $LOG"
  fi
  APPLIED=1
  msg_ok "$name" "done"
}

require() {
  local name=$1 check=$2 hint=$3 out
  out=$($check 2>&1) && { msg_ok "$name"; return 0; }
  ((CHECK_ONLY)) && { msg_todo "$name: $hint"; show_why "$out"; NEEDED=$((NEEDED + 1)); return 0; }
  show_why "$out"; die "$name: $hint"
}

# call right after a step whose change needs a CT restart
restart_if_applied() { if ((APPLIED)); then RESTART_CT=1; fi; }
