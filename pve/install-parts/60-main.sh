# ── main: the order of things lives here ───────────────────────
# To add a step: write chk_*/do_* in the matching phase part and call `step` from its
# phase_* function. A new phase = a new install-parts/NN-*.sh file + one line below.
main() {
  parse_args "$@"
  trap 'rm -rf "${BUNDLE_TMP:-}"' EXIT

  preflight
  if ((CHECK_ONLY)); then echo "${YW}check mode: nothing will be changed${CL}"; fi

  resolve_ctid
  resolve_ct
  resolve_fedora
  resolve_options

  phase_host
  phase_guard
  phase_container
  if ((!SKIPPED)); then   # --check with a missing/stopped CT: nothing to look at inside
    phase_inside
    phase_services
  fi
  phase_summary
}

main "$@"
