# The FP-RISC runtime, the esp-idf machine layer, and the program's generated
# rv32 assembly (FPR_GEN_DIR, written by machine/esp-idf/build.sh).
get_filename_component(FPR_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../.." ABSOLUTE)
set(FPR_RT ${FPR_ROOT}/runtime)
set(FPR_M ${FPR_ROOT}/machine/esp-idf)
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
  SRCS ${FPR_M}/main.c ${FPR_M}/hal.c ${FPR_M}/esp.c ${FPR_M}/wifi.c ${FPR_M}/ble.c ${FPR_M}/ctx.S ${FPR_ROOT}/machine/virt/ctx_fab.c
       ${FPR_RT}/runtime.c ${FPR_RT}/actors.c ${FPR_RT}/bits.c ${FPR_RT}/vec.c
       ${FPR_RT}/sstr.c ${FPR_RT}/mod.c ${FPR_RT}/buddy.c
       ${FPR_ROOT}/machine/posix/os_io.c ${FPR_ROOT}/machine/posix/os_net.c ${FPR_ROOT}/machine/posix/os_watch.c
       ${FPR_GEN}
  INCLUDE_DIRS ${FPR_RT}
  REQUIRES esp_timer esp_hw_support freertos heap hal soc driver
           lwip pthread vfs
           esp_wifi esp_netif esp_event nvs_flash bt esp_hosted)
# the runtime is freestanding C with its own conventions: its warnings are its own
target_compile_options(${COMPONENT_LIB} PRIVATE -w
  -DFPR_NHARTS=2 -DFPR_CTX_WORDS=28 -DFPR_ESP_IDF
  -DFPR_SLAB_SZ=32768 -DFPR_STACK_SZ=65528
  $<$<BOOL:${FPR_ESP_DEBUG}>:-DFPR_ESP_DEBUG>)

# Optional hardware regression helper; absent from normal applications.
if(FPR_ESP_IO_SMOKE)
  target_sources(${COMPONENT_LIB} PRIVATE ${FPR_M}/tests/io_probe.c)
  target_compile_definitions(${COMPONENT_LIB} PRIVATE FPR_ESP_IO_SMOKE)
endif()
