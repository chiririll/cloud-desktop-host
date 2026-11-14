# ════════════════════════════════════════════════════════════════
# Shared by install.sh (host) and ct-install.sh (container): output, step engine, embedded files.
#   1. output          msg_*, die, header
#   2. step engine     why, step, require
#   3. embedded files  render_file
# ════════════════════════════════════════════════════════════════

# ── 1. output, community-scripts style ─────────────────────────
if [[ -t 1 || ${CDH_COLOR:-} == 1 ]]; then
  GN=$'\e[32m' YW=$'\e[33m' RD=$'\e[31m' BL=$'\e[36m' DM=$'\e[2m' CL=$'\e[0m'
else
  GN='' YW='' RD='' BL='' DM='' CL=''
fi
msg_info() { printf ' %s…%s %s' "$YW" "$CL" "$1"; }
msg_ok()   { printf '\r\e[K %s✔%s %s%s%s\n' "$GN" "$CL" "$1" "$DM" "${2:+ ($2)}$CL"; }
msg_todo() { printf '\r\e[K %s◦%s %s %s(needed)%s\n' "$BL" "$CL" "$1" "$YW" "$CL"; }
msg_warn() { printf '\r\e[K %s!%s %s\n' "$YW" "$CL" "$1"; }
die()      { printf '\r\e[K %s✘%s %s\n' "$RD" "$CL" "$1"; exit 1; }
header()   { printf '\n%s── %s%s\n' "$BL" "$1" "$CL"; }


APPLIED_ANY=0    # steps applied in this run (update mode: restart the session if > 0)

# ── 2. step engine ─────────────────────────────────────────────
# step "description" check apply
#   check/apply are function names; extra words become arguments
#   ("chk_nocaps sunshine"), so one pair of functions can serve several steps.
#   Checks print WHY they fail (one reason per line, see why()); shown under "needed".
#   Globals: CHECK_ONLY (read), NEEDED (counted in --check), APPLIED (set to 1 if applied).
# require "description" check "hint": a check we can't fix automatically.

# why <reason>: print the reason and fail; the last line of a failing check
why() { echo "$*"; return 1; }

# show_why <check output>: first lines of a check's output, dimmed and indented
show_why() { [[ -n $1 ]] && sed -n '1,8p' <<<"$1" | sed "s/^/     $DM/; s/\$/$CL/"; return 0; }

step() {
  local name=$1 check=$2 apply=$3 rc out
  APPLIED=0

  if out=$($check 2>&1); then msg_ok "$name"; return 0; fi

  if ((CHECK_ONLY)); then
    msg_todo "$name"; show_why "$out"
    NEEDED=$((NEEDED + 1))
    return 0
  fi

  msg_info "$name"
  printf '=== %s %s\n%s\n' "$(date -Is)" "$name" "$out" >>"$LOG"
  set +e; ( set -e; $apply ) >>"$LOG" 2>&1; rc=$?; set -e
  ((rc == 0)) || die "$name: failed (exit $rc), see $LOG"

  if ! out=$($check 2>&1); then
    printf '\r\e[K'; show_why "$out"
    die "$name: still not satisfied after applying, see $LOG"
  fi
  APPLIED=1; APPLIED_ANY=$((APPLIED_ANY + 1))
  msg_ok "$name" "done"
}

require() {
  local name=$1 check=$2 hint=$3 out
  out=$($check 2>&1) && { msg_ok "$name"; return 0; }
  if ((CHECK_ONLY)); then
    msg_todo "$name: $hint"; show_why "$out"
    NEEDED=$((NEEDED + 1))
    return 0
  fi
  show_why "$out"; die "$name: $hint"
}

# call right after a step whose change needs a CT restart
restart_if_applied() { if ((APPLIED)); then RESTART_CT=1; fi; }


# ── 3. embedded files ──────────────────────────────────────────
# install-parts/files/* are inlined by build.sh into get_file() (see build.sh), so the
# installer stays one file. Files may hold @VAR@ placeholders.

# render_file <file> [VAR…]: the file with every @VAR@ replaced by the value of $VAR
render_file() {
  local out v; out=$(get_file "$1"); shift
  for v; do out=${out//@$v@/${!v}}; done
  printf '%s\n' "$out"
}
