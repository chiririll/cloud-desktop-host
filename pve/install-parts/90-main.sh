# ── main: the order of things lives here ───────────────────────
# To add a step: write chk_*/do_* in the matching phase part and call `step` from its
# phase_* function. A new phase = a new parts/NN-*.sh file + one line below.
main() {
  parse_args "$@"
  trap 'rm -rf "${BUNDLE_TMP:-}"' EXIT

  [[ $EUID -eq 0 ]] || die "run as root on the Proxmox host"
  command -v pct >/dev/null || die "pct not found: this must run on a Proxmox VE host"
  if ((CHECK_ONLY)); then echo "${YW}check mode: nothing will be changed${CL}"; fi

  resolve_ctid
  resolve_ct
  resolve_fedora
  resolve_options

  phase_host
  phase_container
  phase_inside
  phase_services
  phase_summary
}

main "$@"
