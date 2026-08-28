# shellcheck shell=bash disable=SC2034
# Shared Go package metadata and backend-selection link contract.
readonly LMM_CLI_PHASE_T0=t0
readonly LMM_CLI_PHASE_T1=t1
readonly LMM_CLI_T1_RELEASE=0.1.60
readonly LMM_CLI_SOURCE_PHASE=t1

lmm_cli_phase_validate() {
  [[ $1 == "$LMM_CLI_PHASE_T0" || $1 == "$LMM_CLI_PHASE_T1" ]]
}

lmm_cli_phase_for_binary_release() {
  local version=$1
  if (( $(vercmp "$version" "$LMM_CLI_T1_RELEASE") < 0 )); then
    printf '%s\n' "$LMM_CLI_PHASE_T0"
  else
    printf '%s\n' "$LMM_CLI_PHASE_T1"
  fi
}

lmm_cli_phase_apply_metadata() {
  local phase=$1 version=$2
  shift 2
  lmm_cli_phase_validate "$phase" || return 1
  provides=("lmm-api-go=${version}" "lmm-api=${version}")
  conflicts=("$@")
  replaces=()
  if [[ $phase == "$LMM_CLI_PHASE_T1" ]]; then
    conflicts+=('lmm-api-deploy' 'lmm-api-deploy-bin')
    replaces+=('lmm-api-deploy-bin')
  fi
  return 0
}

# Packages always ship the real Go provider as /usr/bin/lmm-api-go. The
# user-facing /usr/bin/lmm-api path is a forward symlink to the selected
# provider, never the real executable and never a reverse compatibility alias.
lmm_cli_phase_install_compatibility_alias() {
  local phase=$1 pkgdir=$2
  lmm_cli_phase_validate "$phase" || return 1
  [[ -f $pkgdir/usr/bin/lmm-api-go && ! -L $pkgdir/usr/bin/lmm-api-go ]] || return 1
  [[ ! -e $pkgdir/usr/bin/lmm-api && ! -L $pkgdir/usr/bin/lmm-api ]] || return 1
  ln -s lmm-api-go "$pkgdir/usr/bin/lmm-api"
}
