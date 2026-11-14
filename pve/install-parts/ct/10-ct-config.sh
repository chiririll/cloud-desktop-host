# ── settings: the environment contract, see the header ─────────
CT_USER=${CT_USER:-user}
INSTALL_STEAM=${INSTALL_STEAM:-1}
CDH_INPUT_ISOLATED=${CDH_INPUT_ISOLATED:-0}
CDH_GH_REPO=${CDH_GH_REPO:-chiririll/cloud-desktop-host}
CDH_VERSION=${CDH_VERSION:-}
CDH_LOCAL_BUNDLE=${CDH_LOCAL_BUNDLE:-}
SUNSHINE_PKG=${SUNSHINE_PKG:-}
SUNSHINE_VERSION=${SUNSHINE_VERSION:-}
CLOUD_MOUSE_PKG=${CLOUD_MOUSE_PKG:-}
CSRF_EXTRA=${CSRF_EXTRA:-}
INSTALL_UPDATE_TIMER=${INSTALL_UPDATE_TIMER:-0}
CT_CDH=${CT_CDH:-/opt/cloud-desktop-host}   # scripts + configs, root-owned, read-only for the user
LOG=${LOG:-/var/log/cdh-ct-install.log}
SUPPORTED_TAGS=(fc43 fc44 fc45 ubuntu2604)   # keep in sync with the matrix in .github/workflows/release.yml

# ── runtime state ──
CHECK_ONLY=0
UPDATE=0
FORCE_RESTART=0
NEEDED=0            # steps still needed (--check)
RESTART_CT=0        # a step needs a container restart (exit 11)
APPLIED=0           # set by step() when it changed something
SESSION_RESTARTED=0
SESSION_APPLIED=0   # the session unit was (re)started by its own step
MANIFEST=''         # "sha256  path" lines of the release bundle, see shared/30-release.sh
BUNDLE_TMP=''       # temp dir of the downloaded bundle, removed on exit
BUNDLE_SKIP=0       # --check without curl: the release can't be looked at
REPO=''             # where scripts/ and configs/ come from (bundle dir)
CDH_BIN=''          # the binary to install
DISTRO='' DISTRO_VERSION='' DISTRO_TAG=''   # set by detect_distro (20-distro.sh)

usage() { echo "usage: ct-install.sh [--check] [--update [--force-restart]]   (settings: see the script header)"; }

parse_args() {
  while (($#)); do
    case "$1" in
      --check|-n) CHECK_ONLY=1 ;;
      --update|-u) UPDATE=1 ;;
      --force-restart) FORCE_RESTART=1 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown option: $1"; usage; exit 2 ;;
    esac
    shift
  done
  if ((FORCE_RESTART && !UPDATE)); then echo "--force-restart only makes sense with --update"; exit 2; fi
}
