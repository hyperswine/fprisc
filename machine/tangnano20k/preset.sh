# Sourced by both board build scripts. Unset FPR_PRESET retains legacy defaults.
if [[ -n "${FPR_PRESET:-}" ]]; then
  # fprisc-48 and fprisc-72 match simple-risc's SDRAM presets of the same name
  # (CPU clock 48 or 72 MHz); the runtime clock is all that differs here.
  case "$FPR_PRESET" in fprisc-48) fpr_preset_mhz=48;; fprisc-72) fpr_preset_mhz=72;;
    *) echo "unknown FPR_PRESET: $FPR_PRESET" >&2; exit 1;; esac
  fpr_preset_setting() {
    if [[ -n "${!1+x}" && "${!1}" != "$2" ]]; then
      echo "FPR_PRESET=$FPR_PRESET requires $1=$2 (got ${!1})" >&2; exit 1
    fi
    export "$1=$2"
  }
  fpr_preset_setting FPR_XLEN 32
  fpr_preset_setting FPR_RVC 1
  fpr_preset_setting FPR_CPU_MHZ "$fpr_preset_mhz"
  unset -f fpr_preset_setting
  unset fpr_preset_mhz
fi
