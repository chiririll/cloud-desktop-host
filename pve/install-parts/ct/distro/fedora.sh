# ── distro backend: Fedora (dnf / rpm) ─────────────────────────
# Implements the interface documented in 20-distro.sh; every function is prefixed fedora_.

fedora_ct_packages() {
  printf '%s\n' dbus-daemon dbus-tools dbus-x11 pipewire wireplumber pipewire-pulseaudio \
    pipewire-utils xorg-x11-server-Xwayland kwin plasma-desktop grim curl libcap xprop \
    xdg-utils kde-cli-tools
}
fedora_steam_packages() { printf '%s\n' steam gamescope mangohud; }   # after RPM Fusion nonfree
fedora_admin_group() { echo wheel; }
fedora_pkg_ext() { echo rpm; }
fedora_sunshine_pattern() { echo "\\.fc$DISTRO_VERSION\\.x86_64\\.rpm"; }
fedora_sunshine_missing_hint() { :; }

# pkg_missing pkg… : prints the missing package names, fails if any
fedora_pkg_missing() {
  local out rc=0 m
  out=$(rpm -q "$@" 2>&1) || rc=$?
  ((rc == 0)) && return 0
  m=$(awk '/is not installed/{print $2}' <<<"$out" | xargs)
  [[ -n $m ]] && { why "missing: $m"; return; }
  why "rpm -q failed: $(head -1 <<<"$out")"
}

# Some %post scripts (udisks2: `udevadm trigger` -> EACCES on /sys/.../uevent in a container) exit non-zero
# although everything is installed. So the exit code is NOT the verdict: callers let step() re-run the check.
fedora_pkg_install() {
  local rc=0
  dnf install -y "$@" || rc=$?
  ((rc == 0)) || echo "package manager exited $rc (usually a container-hostile postinst), verifying afterwards"
  return 0
}

# fedora_pkg_install_file <url|path> [lenient]: dnf takes both
fedora_pkg_install_file() {
  local rc=0
  dnf install -y "$1" || rc=$?
  if ((${2:-0})); then return 0; fi   # e.g. Sunshine's %post fails in a container
  return "$rc"
}

# number of packages with a newer version (0 = up to date)
fedora_pkg_upgrades() {
  local rc=0
  dnf -q check-upgrade >/dev/null 2>&1 || rc=$?
  ((rc == 100)) && echo 1 || echo 0   # dnf does not say how many without parsing; any is enough
}
fedora_pkg_upgrade() {
  local rc=0
  dnf upgrade -y || rc=$?
  ((rc == 0)) || echo "package manager exited $rc, verifying afterwards"
  return 0
}

fedora_pkg_version() { rpm -q --qf '%{VERSION}' "$1"; }

# the installed package called <name> in any case (Sunshine RPM)
fedora_pkg_name_ci() {
  local n
  n=$(rpm -qa --qf '%{NAME}\n' | grep -ix "$1" | head -1)
  [[ -n $n ]] && echo "$n"
}

# ── Steam prerequisites: RPM Fusion nonfree ──
fedora_chk_steamrepos() { pkg_missing rpmfusion-nonfree-release; }
fedora_do_steamrepos()  { dnf install -y "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$DISTRO_VERSION.noarch.rpm"; }
fedora_steam_repos_label() { echo "RPM Fusion nonfree"; }
fedora_steam_prepare() { :; }
