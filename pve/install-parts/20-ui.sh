# ── output, community-scripts style ────────────────────────────
if [[ -t 1 ]]; then
  GN=$'\e[32m' YW=$'\e[33m' RD=$'\e[31m' BL=$'\e[36m' DM=$'\e[2m' CL=$'\e[0m'
else GN='' YW='' RD='' BL='' DM='' CL=''; fi
msg_info() { printf ' %s…%s %s' "$YW" "$CL" "$1"; }
msg_ok()   { printf '\r\e[K %s✔%s %s%s%s\n' "$GN" "$CL" "$1" "$DM" "${2:+ ($2)}$CL"; }
msg_todo() { printf '\r\e[K %s◦%s %s %s(needed)%s\n' "$BL" "$CL" "$1" "$YW" "$CL"; }
msg_warn() { printf '\r\e[K %s!%s %s\n' "$YW" "$CL" "$1"; }
die()      { printf '\r\e[K %s✘%s %s\n' "$RD" "$CL" "$1"; exit 1; }
header()   { printf '\n%s── %s%s\n' "$BL" "$1" "$CL"; }

# ── prompts (read from /dev/tty so `bash -c "$(curl …)"` works too) ──
have_tty() { { : </dev/tty; } 2>/dev/null; }
# ask VAR "question" default [regex]: keeps VAR if already set (env)
ask() {
  local var=$1 q=$2 def=$3 re=${4:-.} ans
  [[ -n ${!var} ]] && return 0
  if ! have_tty; then printf -v "$var" '%s' "$def"; return 0; fi
  while :; do
    read -rp " ${BL}?${CL} $q [${def}]: " ans </dev/tty || exit 1
    ans=${ans:-$def}
    [[ $ans =~ $re ]] && break
    echo "   invalid value"
  done
  printf -v "$var" '%s' "$ans"
}
confirm() { # confirm "question" [default y|n, n] → 0 if yes
  local ans def=${2:-n} hint=y/N
  [[ $def == y ]] && hint=Y/n
  ((YES)) && return 0
  have_tty || return 0
  read -rp " ${YW}?${CL} $1 [$hint]: " ans </dev/tty || exit 1
  [[ ${ans:-$def} =~ ^[Yy] ]]
}
