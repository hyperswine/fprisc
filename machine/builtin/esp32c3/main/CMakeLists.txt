get_filename_component(fpr "${CMAKE_CURRENT_LIST_DIR}/../../../.." ABSOLUTE)
if(DEFINED ENV{FPRISC_ROOT})
    set(fpr "$ENV{FPRISC_ROOT}")
endif()
set(sources "main.c" "io.c" "gpio_clock.c" "memory.c" "${fpr}/machine/builtin/heap.c" "${fpr}/machine/builtin/unsafe.c"
    "${fpr}/runtime/runtime.c" "${fpr}/runtime/i32.c")
set(drivers esp_driver_usb_serial_jtag esp_driver_gpio esp_timer)
if("$ENV{FPR_IDF_FLASH_FILES}" STREQUAL "1")
    list(APPEND sources "file.c")
    list(APPEND drivers spiffs esp_partition spi_flash)
endif()
idf_component_register(SRCS ${sources} INCLUDE_DIRS "${fpr}/runtime" "${fpr}/machine/builtin"
    PRIV_REQUIRES ${drivers})
if(FPR_RUNTIME_STATS)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE FPR_BUILTIN_HEAP_STATS)
endif()
if(FPR_FLASH_FILES)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE FPR_FLASH_LABEL="${FPR_FLASH_LABEL}")
endif()
target_compile_definitions(${COMPONENT_LIB} PRIVATE FPR_BUILTIN FPR_ESP_IDF FPR_NHARTS=1)
target_compile_options(${COMPONENT_LIB} PRIVATE -ffixed-x27)
set(guest "${CMAKE_CURRENT_BINARY_DIR}/guest.o")
if(POLICY CMP0116)
    cmake_policy(SET CMP0116 NEW)
endif()
add_custom_command(OUTPUT "${guest}.s" "${guest}"
    COMMAND ${CMAKE_COMMAND} "-Dfpr=${fpr}/fpr" "-Dsource=${FPR_PROGRAM}" "-Dcc=${CMAKE_C_COMPILER}"
        "-Dguest=${guest}" -P "${CMAKE_CURRENT_LIST_DIR}/compile.cmake"
    DEPFILE "${guest}.d"
    DEPENDS "${FPR_PROGRAM}" "${fpr}/fpr" "${CMAKE_CURRENT_LIST_DIR}/compile.cmake" VERBATIM)
set_source_files_properties("${guest}" PROPERTIES EXTERNAL_OBJECT TRUE GENERATED TRUE)
target_sources(${COMPONENT_LIB} PRIVATE "${guest}")
