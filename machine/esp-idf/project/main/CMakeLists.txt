# The FP-RISC runtime, the posix system's shared files and its esp-idf host, and the program's generated
# rv32 assembly (FPR_GEN_DIR, written by machine/esp-idf/build.sh).
get_filename_component(FPR_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../.." ABSOLUTE)
set(FPR_RT ${FPR_ROOT}/runtime)
set(FPR_M ${FPR_ROOT}/machine/esp-idf)
# platform libraries (std/wifi, std/ble, std/gpio): linked only when a program
# references their primitives, since nothing else names them
set(FPR_P ${FPR_ROOT}/platform/esp-idf)
# CONFIGURE_DEPENDS: another program built into the same directory has other
# units.  IDF also runs this file in script mode (requirements), where the
# option is refused.
if(CMAKE_SCRIPT_MODE_FILE)
  file(GLOB FPR_GEN "$ENV{FPR_GEN_DIR}/*.s")
else()
  file(GLOB FPR_GEN CONFIGURE_DEPENDS "$ENV{FPR_GEN_DIR}/*.s")
endif()
if(NOT FPR_GEN)
  message(FATAL_ERROR "FPR_GEN_DIR has no generated .s files: build with machine/esp-idf/build.sh")
endif()
idf_component_register(
  SRCS ${FPR_M}/main.c ${FPR_M}/hal.c ${FPR_M}/esp.c ${FPR_M}/ctx.S ${FPR_ROOT}/machine/virt/ctx_fab.c
       ${FPR_RT}/runtime.c ${FPR_RT}/actors.c ${FPR_RT}/bits.c ${FPR_RT}/vec.c
       ${FPR_RT}/sstr.c ${FPR_RT}/mod.c ${FPR_RT}/buddy.c
       ${FPR_ROOT}/machine/posix/hal.c ${FPR_ROOT}/machine/posix/os_job.c ${FPR_ROOT}/machine/posix/os_io.c ${FPR_ROOT}/machine/posix/os_net.c ${FPR_ROOT}/machine/posix/os_watch.c
       ${FPR_ROOT}/machine/posix/os_fs.c ${FPR_ROOT}/machine/posix/base_file.c ${FPR_ROOT}/machine/posix/base.c ${FPR_M}/fs.c
       ${FPR_P}/radio.c ${FPR_P}/wifi.c ${FPR_P}/bluetooth.c ${FPR_P}/gpio.c
       ${FPR_GEN}
  INCLUDE_DIRS ${FPR_RT} ${FPR_ROOT}/machine/posix ${FPR_P}
  REQUIRES esp_timer esp_hw_support freertos heap hal soc driver esp_driver_uart
           lwip pthread vfs fatfs wear_levelling
           esp_wifi esp_netif esp_event nvs_flash bt esp_hosted)
# the runtime is freestanding C with its own conventions: its warnings are its own
target_compile_options(${COMPONENT_LIB} PRIVATE -w
  -DFPR_NHARTS=2 -DFPR_CTX_WORDS=28 -DFPR_ESP_IDF
  -DFPR_SLAB_SZ=32768 -DFPR_STACK_SZ=65528
  $<$<BOOL:${FPR_ESP_DEBUG}>:-DFPR_ESP_DEBUG>
  $<$<BOOL:${FPR_ESP_STACK_GUARD}>:-DFPR_ESP_STACK_GUARD>)

# Optional hardware regression helper; absent from normal applications.
if(FPR_ESP_IO_SMOKE)
  target_sources(${COMPONENT_LIB} PRIVATE ${FPR_M}/tests/io_probe.c)
  target_compile_definitions(${COMPONENT_LIB} PRIVATE FPR_ESP_IO_SMOKE)
endif()

# ESP-Hosted starts from a C constructor in a WHOLE_ARCHIVE component, so it
# would run in every image; its call is wrapped so the start waits for a
# program's first radio call (platform/esp-idf/radio.c)
target_link_libraries(${COMPONENT_LIB} INTERFACE "-Wl,--wrap=esp_hosted_init")
