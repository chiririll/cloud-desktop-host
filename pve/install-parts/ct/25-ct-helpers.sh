# ── helpers that read facts from inside the container ──────────
as_user()        { runuser -l "$CT_USER" -c "$1"; }
# the CT user's systemd --user instance: user_systemctl enable --now foo.service
user_systemctl() { as_user "XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user $*"; }

# NVIDIA driver version of the HOST: the module's sysfs file is visible in an LXC; /proc/driver/nvidia
# needs the /dev/nvidia* nodes the host mapped in
host_driver() {
  local v; v=$(cat /sys/module/nvidia/version 2>/dev/null) || v=''
  [[ -n $v ]] || v=$(sed -n 's/.*Kernel Module  *\([0-9][0-9.]*\).*/\1/p' /proc/driver/nvidia/version 2>/dev/null | head -1)
  [[ -n $v ]] && echo "$v"
}

# uid of the CT user as the HOST sees it: shifted by the idmap of an unprivileged CT, plain in a VM or privileged CT
host_uid() {
  local u; u=$(id -u "$CT_USER" 2>/dev/null) || u=1000
  awk -v u="$u" '$1 <= u && u < $1 + $3 {print $2 + u - $1; f = 1; exit} END {if (!f) print u}' /proc/self/uid_map
}

ct_ip() {
  local ip
  ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4; exit}') || ip=''
  [[ -n $ip ]] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo "${ip:-<container ip>}"
}

# step "… has no file caps" "chk_nocaps <binary>" "do_nocaps <binary>"
chk_nocaps() { bash -c 'f=$(readlink -f "$(command -v "$1")") && [ -z "$(getcap "$f")" ]' _ "$1"; }
do_nocaps()  { bash -c 'setcap -r "$(readlink -f "$(command -v "$1")")"' _ "$1"; }
