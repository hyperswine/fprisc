get_filename_component(board "${CMAKE_CURRENT_LIST_DIR}/../../../main" ABSOLUTE)
idf_component_register(SRCS "test.c" "${board}/log.c" INCLUDE_DIRS "${board}"
    PRIV_REQUIRES esp_partition spi_flash)
