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
DISTRO=${DISTRO:-${FEDORA:+fedora-$FEDORA}}
SUPPORTED_DISTROS=(fedora-43 fedora-44 fedora-45 ubuntu-26.04)   # keep in sync with the matrix in .github/workflows/release.yml
DEFAULT_DISTRO=fedora-43
CT_USER=${CT_USER:-user}
INSTALL_STEAM=${INSTALL_STEAM:-}
SHM_SIZE=${SHM_SIZE:-4G}
NVIDIA_PCI=${NVIDIA_PCI:-}
CSRF_EXTRA=${CSRF_EXTRA:-}

CDH_GH_REPO=${CDH_GH_REPO:-chiririll/cloud-desktop-host}
CDH_VERSION=${CDH_VERSION:-}
CDH_REF=${CDH_REF:-main}   # git ref ct-install.sh is fetched from when this script is run via curl (not a checkout)
# host kernel module that keeps container input away from the host console
INSTALL_INPUT_GUARD=${INSTALL_INPUT_GUARD:-1}
CDH_GUARD_REPO=${CDH_GUARD_REPO:-chiririll/cdh-input-guard}
CDH_GUARD_VERSION=${CDH_GUARD_VERSION:-}   # empty = latest release
REPO=$(cd "$(dirname "${BASH_SOURCE[0]:-.}")/.." && pwd)
CDH_BIN=$REPO/dist/cloud-desktop-host
# Local build (dist/ of a checkout): pushed into the CT instead of a release download. It must be
# built for the CT's distro (docker build --build-arg BASE=… -o dist .).
SUNSHINE_PKG=${SUNSHINE_PKG:-${SUNSHINE_RPM:-}}
SUNSHINE_VERSION=${SUNSHINE_VERSION:-}
CLOUD_MOUSE_PKG=${CLOUD_MOUSE_PKG:-${CLOUD_MOUSE_RPM:-}}
INSTALL_UPDATE_TIMER=${INSTALL_UPDATE_TIMER:-0}
CT_CDH=/opt/cloud-desktop-host   # scripts + configs, root-owned, read-only for the user
CT_INSTALLER=$REPO/pve/ct-install.sh   # the in-container script: checkout, else the release asset
LOG=/var/log/cdh-lxc-install.log
LOG_CT=/var/log/cdh-ct-install.log   # written by ct-install.sh inside the CT

# ── runtime state (set while running, read across parts) ──
CHECK_ONLY=0
CONF=''          # /etc/pve/lxc/<CTID>.conf
CT_NAME=''       # hostname of the CT if it already exists, empty = will be created
BUNDLE_TMP=''    # temp dir for the downloaded ct-install.sh, removed on exit
UPDATE=0         # --update
FORCE_RESTART=0  # --force-restart
OS_TYPE=fedora   # pct --ostype of a new CT
NEEDED=0         # steps still needed (--check)
RESTART_CT=0     # a step changed the CT config: restart before going inside
APPLIED=0        # set by step() when it changed something
SKIPPED=0        # --check could not look inside the CT (missing / stopped), see skip_rest()

usage() { local IFS='|'; echo "usage: install.sh [--check] [--update [--force-restart]] [--distro ${SUPPORTED_DISTROS[*]}]   (settings: see the script header)"; }

parse_args() {
  while (($#)); do
    case "$1" in
      --check|-n) CHECK_ONLY=1 ;;
      --update|-u) UPDATE=1 ;;
      --force-restart) FORCE_RESTART=1 ;;
      --distro=*) DISTRO=${1#*=} ;;
      --distro|-d) [[ $# -ge 2 ]] || { usage; exit 2; }; DISTRO=$2; shift ;;
      --fedora=*) DISTRO=fedora-${1#*=} ;;
      --fedora|-f) [[ $# -ge 2 ]] || { usage; exit 2; }; DISTRO=fedora-$2; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown option: $1"; usage; exit 2 ;;
    esac
    shift
  done
}
