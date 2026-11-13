# ── settings: defaults, env overrides, CLI ─────────────────────
CTID=${CTID:-}
CT_HOSTNAME=${CT_HOSTNAME:-}
CT_STORAGE=${CT_STORAGE:-}
CT_DISK=${CT_DISK:-}
CT_CORES=${CT_CORES:-}
CT_MEMORY=${CT_MEMORY:-}
CT_BRIDGE=${CT_BRIDGE:-}
CT_IP=${CT_IP:-}             # "dhcp" or a static address in CIDR form, e.g. 192.168.1.50/24
CT_GATEWAY=${CT_GATEWAY:-}   # only used with a static CT_IP
YES=${YES:-0}
TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-local}
FEDORA=${FEDORA:-}
SUPPORTED_FEDORA=(43 44 45)   # keep in sync with the matrix in .github/workflows/release.yml
DEFAULT_FEDORA=43
CT_USER=${CT_USER:-user}
INSTALL_STEAM=${INSTALL_STEAM:-}
SHM_SIZE=${SHM_SIZE:-4G}
NVIDIA_PCI=${NVIDIA_PCI:-}
CSRF_EXTRA=${CSRF_EXTRA:-}

CDH_GH_REPO=${CDH_GH_REPO:-chiririll/cloud-desktop-host}
CDH_VERSION=${CDH_VERSION:-}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]:-.}")/.." && pwd)
CDH_BIN=$REPO/dist/cloud-desktop-host
# empty = resolve the latest Sunshine release's fc$FEDORA asset at install time
# (asset names embed the version, so /releases/latest/download/<name> can't be used)
SUNSHINE_RPM=${SUNSHINE_RPM:-}
# KDE System Settings → Input Devices → Cloud Mouse (pointer speed etc. over org.gamescope.Input;
# KWin's own mouse page can't see CDH's input devices)
CLOUD_MOUSE_RPM=${CLOUD_MOUSE_RPM:-}   # default is set once FEDORA is known
CLOUD_MOUSE_DEFAULT=0
CT_CDH=/opt/cloud-desktop-host   # scripts + configs, root-owned, read-only for the user
LOG=/var/log/cdh-lxc-install.log

CT_PACKAGES=(dbus-daemon dbus-tools dbus-x11 pipewire wireplumber pipewire-pulseaudio
  pipewire-utils xorg-x11-server-Xwayland kwin plasma-desktop grim curl libcap xprop
  xdg-utils kde-cli-tools)

# ── runtime state (set while running, read across parts) ──
CHECK_ONLY=0
CONF=''          # /etc/pve/lxc/<CTID>.conf
CT_NAME=''       # hostname of the CT if it already exists, empty = will be created
MANIFEST=''      # "sha256  path" lines of the release bundle, see 50-release.sh
BUNDLE_TMP=''    # temp dir of the downloaded bundle, removed on exit
NEEDED=0         # steps still needed (--check)
RESTART_CT=0     # a step changed the CT config: restart before going inside
APPLIED=0        # set by step() when it changed something

usage() { local IFS='|'; echo "usage: install.sh [--check] [--fedora ${SUPPORTED_FEDORA[*]}]   (settings: see the script header)"; }

parse_args() {
  while (($#)); do
    case "$1" in
      --check|-n) CHECK_ONLY=1 ;;
      --fedora=*) FEDORA=${1#*=} ;;
      --fedora|-f) [[ $# -ge 2 ]] || { usage; exit 2; }; FEDORA=$2; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown option: $1"; usage; exit 2 ;;
    esac
    shift
  done
}
