# env.sh -- ESP-IDF's environment without export.sh (source it).
#   IDF_PATH defaults to ~/.espressif/esp-idf/v5.3.2, the tools to the versions
#   installed beside it.  export.sh refuses to run while an optional tool
#   (openocd, for JTAG debugging) is missing, and may pick up the wrong
#   Python; building and flashing need neither.
: "${IDF_PATH:=$HOME/.espressif/esp-idf/v5.3.2}"
T=$HOME/.espressif/tools
export IDF_PATH
export IDF_PYTHON_ENV_PATH="${IDF_PYTHON_ENV_PATH:-$(ls -d $HOME/.espressif/python_env/idf5.3_py3* 2>/dev/null | head -1)}"
export ESP_ROM_ELF_DIR="$(ls -d $T/esp-rom-elfs/* 2>/dev/null | head -1)/"
export PATH="$IDF_PYTHON_ENV_PATH/bin:$IDF_PATH/tools:$(ls -d $T/riscv32-esp-elf/*/riscv32-esp-elf/bin | head -1):$(ls -d $T/cmake/*/CMake.app/Contents/bin | head -1):$(ls -d $T/ninja/* | head -1):$PATH"
