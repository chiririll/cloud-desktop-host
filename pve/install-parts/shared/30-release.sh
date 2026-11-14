# ── release bundle: cdh/{cloud-desktop-host,scripts,configs,pve} ──
# Shared: the host script downloads the bundle (which contains ct-install.sh) and pushes it into the CT;
# ct-install.sh downloads it itself when run standalone.
# MANIFEST: "sha256  path" for cloud-desktop-host, scripts/*, configs/*.
# --check only needs this (a few KB), the bundle is downloaded to apply.
release_base() {
  if [[ -z $CDH_VERSION || $CDH_VERSION == latest ]]; then
    echo "https://github.com/$CDH_GH_REPO/releases/latest/download"
  else
    echo "https://github.com/$CDH_GH_REPO/releases/download/$CDH_VERSION"
  fi
}
# The release MANIFEST has one binary line per distro (cloud-desktop-host-<DISTRO_TAG>-x86_64, e.g.
# -fc43- or -ubuntu2604-); keep ours under the plain name used by local_manifest and drop the others.
fetch_manifest() {
  local raw
  raw=$(curl -fsSL "$(release_base)/MANIFEST") || return 1
  MANIFEST=$(sed -n -e "s|  cloud-desktop-host-$DISTRO_TAG-x86_64\$|  cloud-desktop-host|p" \
                    -e '/  cloud-desktop-host-/d;/  \(scripts\|configs\)\//p' <<<"$raw")
  [[ -n $MANIFEST ]]
}
local_manifest() {
  printf '%s  cloud-desktop-host\n' "$(sha256sum <"$CDH_BIN" | cut -d' ' -f1)"
  (cd "$REPO" && find scripts configs -type f | sort | xargs sha256sum)
}
# release lines of MANIFEST that belong inside the CT (scripts/, configs/)
manifest() { grep -E '  (scripts|configs)/' <<<"$MANIFEST"; }

# Downloads + verifies the bundle into BUNDLE_TMP (removed by the EXIT trap in main)
# and points REPO/CDH_BIN at it.
fetch_release() {
  local asset="cdh-$DISTRO_TAG-x86_64.tar.gz" base
  base=$(release_base)
  BUNDLE_TMP=$(mktemp -d /tmp/cdh-release.XXXXXX)
  curl -fsSL -o "$BUNDLE_TMP/$asset" "$base/$asset" || return 1
  curl -fsSL -o "$BUNDLE_TMP/SHA256SUMS" "$base/SHA256SUMS" || return 1
  (cd "$BUNDLE_TMP" && grep " $asset\$" SHA256SUMS | sha256sum -c --quiet -) || return 1
  tar -C "$BUNDLE_TMP" -xzf "$BUNDLE_TMP/$asset"
  REPO=$BUNDLE_TMP/cdh CDH_BIN=$BUNDLE_TMP/cdh/cloud-desktop-host
}
