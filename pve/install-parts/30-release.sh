# ── release bundle: cdh/{cloud-desktop-host,scripts,configs,pve} ──
# MANIFEST: "sha256  path" for cloud-desktop-host, scripts/*, configs/*.
# --check only needs this (a few KB), the bundle is downloaded to apply.
release_base() {
  if [[ -z $CDH_VERSION || $CDH_VERSION == latest ]]; then
    echo "https://github.com/$CDH_GH_REPO/releases/latest/download"
  else
    echo "https://github.com/$CDH_GH_REPO/releases/download/$CDH_VERSION"
  fi
}
# The release MANIFEST has one binary line per Fedora (cloud-desktop-host-fcNN-x86_64); keep ours
# under the plain name used by local_manifest and drop the others.
fetch_manifest() {
  local raw
  raw=$(curl -fsSL "$(release_base)/MANIFEST") || return 1
  MANIFEST=$(sed -n -e "s|  cloud-desktop-host-fc$FEDORA-x86_64\$|  cloud-desktop-host|p" -e '/  cloud-desktop-host-fc/d;/  \(scripts\|configs\)\//p' <<<"$raw")
  [[ -n $MANIFEST ]]
}
local_manifest() {
  printf '%s  cloud-desktop-host\n' "$(sha256sum <"$CDH_BIN" | cut -d' ' -f1)"
  (cd "$REPO" && find scripts configs -type f | sort | xargs sha256sum)
}
# Downloads + verifies the bundle into BUNDLE_TMP (removed by the EXIT trap in main)
# and points REPO/CDH_BIN at it.
fetch_release() {
  local asset="cdh-fc$FEDORA-x86_64.tar.gz" base
  base=$(release_base)
  BUNDLE_TMP=$(mktemp -d /tmp/cdh-release.XXXXXX)
  curl -fsSL -o "$BUNDLE_TMP/$asset" "$base/$asset" || return 1
  curl -fsSL -o "$BUNDLE_TMP/SHA256SUMS" "$base/SHA256SUMS" || return 1
  (cd "$BUNDLE_TMP" && grep " $asset\$" SHA256SUMS | sha256sum -c --quiet -) || return 1
  tar -C "$BUNDLE_TMP" -xzf "$BUNDLE_TMP/$asset"
  REPO=$BUNDLE_TMP/cdh CDH_BIN=$BUNDLE_TMP/cdh/cloud-desktop-host
}

# Decides where scripts/configs/binary come from: local build or release. Sets MANIFEST.
phase_bundle() {
  if [[ -n $CDH_VERSION || ! -x $CDH_BIN || ! -d $REPO/scripts ]]; then
    if ((CHECK_ONLY)) && fetch_manifest; then
      msg_ok "Release ${CDH_VERSION:-latest} manifest" "bundle not downloaded in check mode"
    else
      msg_info "Downloading release ${CDH_VERSION:-latest} from $CDH_GH_REPO"
      fetch_release || die "could not download/verify cdh-fc$FEDORA-x86_64.tar.gz from $CDH_GH_REPO (${CDH_VERSION:-latest})"
      MANIFEST=$(local_manifest)
      msg_ok "Release ${CDH_VERSION:-latest} downloaded" "sha256 ok"
    fi
  else
    MANIFEST=$(local_manifest)
    msg_ok "Using local build" "$CDH_BIN"
  fi
}
