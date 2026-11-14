# ── distro detection and dispatch ──────────────────────────────
# detect_distro sets DISTRO (fedora|ubuntu), DISTRO_VERSION (43, 26.04) and DISTRO_TAG (fc43, ubuntu2604),
# the suffix of the release assets.
#
# Everything that differs between distros lives in ct/distro/<distro>.sh, which defines these functions
# prefixed with <distro>_ (fedora_pkg_install, ubuntu_pkg_install, …). The phases never look at $DISTRO:
# they call the generic names below, which forward to the active distro. A new distro = a new
# ct/distro/<id>.sh implementing this interface + a case in detect_distro.
#
#   ct_packages / steam_packages      package names, one per line
#   admin_group                       the group that grants sudo (wheel | sudo)
#   pkg_ext                           rpm | deb
#   pkg_missing pkg…                  why()s and fails if one is not installed
#   pkg_install pkg…                  lenient: the verdict is the re-run check, see step()
#   pkg_install_file src [lenient]    install a url/path
#   pkg_upgrades / pkg_upgrade        count of pending upgrades / do them
#   pkg_version pkg / pkg_name_ci n   installed version / installed name matched case-insensitively
#   sunshine_pattern                  regex of the Sunshine release asset for this distro
#   sunshine_missing_hint             extra advice when there is no such asset
#   steam_repos_label                 title of the step that prepares the repos for Steam
#   chk_steamrepos / do_steamrepos    that step
#   steam_prepare                     runs before the Steam packages are installed

detect_distro() {
  local id ver t ok=0
  [[ -r /etc/os-release ]] || { echo "no /etc/os-release: unsupported system"; exit 2; }
  eval "$(. /etc/os-release; printf 'id=%q ver=%q' "${ID:-}" "${VERSION_ID:-}")"
  case $id in
    fedora) DISTRO=fedora DISTRO_VERSION=$ver DISTRO_TAG=fc$ver ;;
    ubuntu) DISTRO=ubuntu DISTRO_VERSION=$ver DISTRO_TAG=ubuntu${ver//./} ;;
    *) echo "unsupported distro '$id' (supported: ${SUPPORTED_TAGS[*]})"; exit 2 ;;
  esac
  for t in "${SUPPORTED_TAGS[@]}"; do [[ $t == "$DISTRO_TAG" ]] && ok=1; done
  if ((!ok)) && [[ -z $CDH_LOCAL_BUNDLE ]]; then
    echo "$id $ver has no release bundle (supported: ${SUPPORTED_TAGS[*]})"; exit 2
  fi
  return 0
}

ct_packages()             { "${DISTRO}_ct_packages"; }
steam_packages()          { "${DISTRO}_steam_packages"; }
admin_group()             { "${DISTRO}_admin_group"; }
pkg_ext()                 { "${DISTRO}_pkg_ext"; }
pkg_missing()             { "${DISTRO}_pkg_missing" "$@"; }
pkg_install()             { "${DISTRO}_pkg_install" "$@"; }
pkg_install_file()        { "${DISTRO}_pkg_install_file" "$1" "${2:-0}"; }
pkg_upgrades()            { "${DISTRO}_pkg_upgrades"; }
pkg_upgrade()             { "${DISTRO}_pkg_upgrade"; }
pkg_version()             { "${DISTRO}_pkg_version" "$1"; }
pkg_name_ci()             { "${DISTRO}_pkg_name_ci" "$1"; }
sunshine_pattern()        { "${DISTRO}_sunshine_pattern"; }
sunshine_missing_hint()   { "${DISTRO}_sunshine_missing_hint"; }
steam_repos_label()       { "${DISTRO}_steam_repos_label"; }
chk_steamrepos()          { "${DISTRO}_chk_steamrepos"; }
do_steamrepos()           { "${DISTRO}_do_steamrepos"; }
steam_prepare()           { "${DISTRO}_steam_prepare"; }
