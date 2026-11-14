# ── distro backend: Ubuntu (apt / dpkg) ────────────────────────
# Implements the interface documented in 20-distro.sh; every function is prefixed ubuntu_.

# candidate list: verify every name on the 26.04 template
ubuntu_ct_packages() {
  printf '%s\n' dbus dbus-user-session dbus-x11 pipewire wireplumber pipewire-pulse \
    pipewire-audio xwayland kwin-wayland plasma-desktop plasma-workspace polkit-kde-agent-1 \
    grim curl ca-certificates libcap2-bin x11-utils xdg-utils kde-cli-tools
}
ubuntu_steam_packages() { printf '%s\n' steam-installer gamescope mangohud; }   # after i386 + multiverse
ubuntu_admin_group() { echo sudo; }
ubuntu_pkg_ext() { echo deb; }
ubuntu_sunshine_pattern() { echo "ubuntu-${DISTRO_VERSION//./\\.}-amd64\\.deb"; }
ubuntu_sunshine_missing_hint() {
  echo "Build Sunshine from subprojects/sunshine (docs/BUILD.md) and pass it as SUNSHINE_PKG=<file.deb>."
}

APT_ENV=(DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a)

PKG_REFRESHED=0
ubuntu_pkg_refresh() {
  if ((!PKG_REFRESHED)); then apt-get update -q; PKG_REFRESHED=1; fi
  return 0
}

# pkg_missing pkg… : prints the missing package names, fails if any
ubuntu_pkg_missing() {
  local p miss=()
  for p; do
    [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null)" == ii* ]] || miss+=("$p")
  done
  ((${#miss[@]} == 0)) || why "missing: ${miss[*]}"
}

# Some postinst scripts (udisks2: `udevadm trigger` -> EACCES on /sys/.../uevent in a container) exit non-zero
# although everything is installed. So the exit code is NOT the verdict: callers let step() re-run the check.
ubuntu_pkg_install() {
  local rc=0
  ubuntu_pkg_refresh
  env "${APT_ENV[@]}" apt-get install -y "$@" || rc=$?
  ((rc == 0)) || echo "package manager exited $rc (usually a container-hostile postinst), verifying afterwards"
  return 0
}

# ubuntu_pkg_install_file <url|path> [lenient]: apt needs a local .deb (dependencies are resolved)
ubuntu_pkg_install_file() {
  local src=$1 lenient=${2:-0} rc=0 tmp=''
  ubuntu_pkg_refresh
  if [[ $src =~ ^https?:// ]]; then
    tmp=$(mktemp /tmp/cdh-pkg.XXXXXX.deb)
    curl -fsSL -o "$tmp" "$src" || { rm -f "$tmp"; return 1; }
    src=$tmp
  fi
  [[ $src == /* ]] || src=$PWD/$src
  env "${APT_ENV[@]}" apt-get install -y "$src" || rc=$?
  [[ -z $tmp ]] || rm -f "$tmp"
  if ((lenient)); then return 0; fi   # e.g. Sunshine's postinst modprobe/udevadm fail in a container
  return "$rc"
}

# number of packages with a newer version (0 = up to date)
ubuntu_pkg_upgrades() {
  ubuntu_pkg_refresh >&2
  apt-get -s dist-upgrade | grep -c '^Inst ' || true
}
ubuntu_pkg_upgrade() {
  local rc=0
  ubuntu_pkg_refresh
  env "${APT_ENV[@]}" apt-get dist-upgrade -y \
    -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef || rc=$?
  ((rc == 0)) || echo "package manager exited $rc, verifying afterwards"
  return 0
}

ubuntu_pkg_version() { dpkg-query -W -f='${Version}' "$1"; }

# the installed package called <name> in any case (sunshine deb)
ubuntu_pkg_name_ci() {
  local n
  n=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' | awk '$1=="ii"{print $2}' | grep -ix "$1" | head -1)
  [[ -n $n ]] && echo "$n"
}

# ── Steam prerequisites: Steam is 32-bit and lives in multiverse ──
ubuntu_chk_steamrepos() {
  dpkg --print-foreign-architectures | grep -qx i386 || { why "i386 architecture not enabled"; return; }
  grep -qsE '^(Components:|deb ).*[[:space:]]multiverse' /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list \
    || why "multiverse not enabled in apt sources"
}
ubuntu_do_steamrepos() {
  local f
  dpkg --add-architecture i386
  for f in /etc/apt/sources.list.d/*.sources; do   # deb822
    [[ -f $f ]] && grep -q 'ubuntu\.com' "$f" && sed -i '/^Components:/{/multiverse/!s/$/ multiverse/}' "$f"
  done
  if [[ -f /etc/apt/sources.list ]]; then sed -i '/^deb .*ubuntu\.com/{/multiverse/!s/$/ multiverse/}' /etc/apt/sources.list; fi
  PKG_REFRESHED=0; ubuntu_pkg_refresh
}
ubuntu_steam_repos_label() { echo "i386 + multiverse (Steam)"; }
# the license question would block a non-interactive install
ubuntu_steam_prepare() {
  printf '%s\n' 'steam steam/question select I AGREE' 'steam steam/license note ' | debconf-set-selections
}
