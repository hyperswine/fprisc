# ESP32-C3 wireless archive audit

The archive and header lock uses the same Espressif wireless revision as
the esp-radio C3 reference. Use the revision in archives.json to check out
the upstream repository. The tool verifies the archive, header, version
and license bytes before invoking the same RV32 GNU toolchain used by the
bare-metal builds.

    python3 audit.py /path/to/esp-wireless-drivers-3rdparty ble
    python3 audit.py /path/to/esp-wireless-drivers-3rdparty wifi

Each probe starts from the listed public entry points and performs a
garbage-collected relocatable link. The resulting undefined symbols include
C3 ROM exports, compiler helpers, hardware services and any other archive
dependencies. Callback slots are passed in tables and require a separate
ABI audit. The probe does not initialize a radio.

Keep the matched binaries and headers together. The lock includes the
upstream Apache-2.0 LICENSE digest. Review upstream notices for the binary
set before publishing a firmware image.
