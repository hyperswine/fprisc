# Sourced by both board build scripts. Unset FPR_PRESET retains legacy defaults.
if [[ -n "${FPR_PRESET:-}" ]]; then
  [[ "$FPR_PRESET" == fprisc-48 ]] || { echo "unknown FPR_PRESET: $FPR_PRESET" >&2; exit 1; }
  fpr_preset_setting() {
    if [[ -n "${!1+x}" && "${!1}" != "$2" ]]; then
      echo "FPR_PRESET=fprisc-48 requires $1=$2 (got ${!1})" >&2; exit 1
    fi
    export "$1=$2"
  }
  fpr_preset_setting FPR_XLEN 32
  fpr_preset_setting FPR_RVC 1
  fpr_preset_setting FPR_CPU_MHZ 48
  unset -f fpr_preset_setting
fi
