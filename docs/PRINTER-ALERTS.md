# Live printer alerts

The native printer dashboard displays print errors and Bambu HMS health alerts
on each card, including when collapsed. The first three are shown in the summary;
expanding details shows up to 33 alerts (one print error plus 32 HMS entries).
Each contains a conservative category, severity, exact code and Bambu help link.
Paused/failed jobs also show a banner even when no fault code is available.
Active external/AMS source appears in details when the printer reports it.

Known exact codes are categorized as runout, cutter, feeding, thermal, fan,
motion, print/storage or build-plate attention. Labels describe the reported
category, not the underlying cause. A tangled spool might trigger a feeding
fault, or might be invisible to the printer; operator observations belong in
Care & print log. This feature adds no printer control commands or auto-resume.

Unknown/model-ambiguous codes stay visible with a generic label and help link.
The short print_error code links to Bambu's code index; full HMS codes link to
the official HMS resolver. HMS levels follow BambuStudio: fatal/serious -> error,
common -> warning, information -> info, unknown values -> unknown. Severity is
read from the high word of `code`, not from `attr`.

## Incremental reports and bounds

Fault-only, explicit-zero and empty-HMS reports count as telemetry updates.
Omitted fields retain their previous value; only an explicit zero/empty list
clears that source's faults. Malformed, negative, overflowing or oversized fault
updates retain prior state and expose a warning. Flags for the two sources are
tracked separately so a valid print update cannot hide a bad HMS update.
Numeric fault values support the full unsigned 32-bit range; temperatures and
other numeric telemetry retain their tighter bounds. HMS is capped at 32 entries;
only numeric attr/code survive. No raw firmware messages, credentials or other
HMS fields are copied into the public snapshot.

Offline/stale cards label alerts as last known. Missing fault/HMS data is not
presented as proof of healthy hardware. Existing packet size/depth limits and
bounded report-rate storage remain in force. Source-only AMS updates preserve
prior material summaries.

## Catalog provenance

`std/printeralertcodes.fpr` is generated from the installed BambuStudio model
catalogs using `python3 scripts/generate_printer_alert_codes.py`. Input filenames,
versions, SHA-256 values and category counts are pinned in
`docs/printer-alert-catalog.json`. The application needs no BambuStudio files or
internet access to classify known codes. The generator emits exact identifiers
and our own category labels, not vendor messages. Conflicting classifications
across models are omitted rather than guessed. Updating a catalog requires
regeneration and regression validation.

Protocol references:
- [BambuStudio HMS decoder](https://github.com/bambulab/BambuStudio/blob/master/src/slic3r/GUI/DeviceCore/DevHMS.cpp)
- [BambuStudio HMS severity definitions](https://github.com/bambulab/BambuStudio/blob/master/src/slic3r/GUI/DeviceCore/DevHMS.h)

## Verification

`./fpr run tests/std/printertelemetry.fpr` checks fault-only delivery, explicit
clears, omission retention, malformed/oversized input, unsigned codes, unknown
codes, severity, redaction and source-only filament deltas.
`tests/check_native_gateway.py --binary <printer-host>` exercises synthetic MQTT
fault delivery through authenticated API and live UI, then clearing through WSS,
on one/four harts, alongside existing auth/camera checks.
`node tests/check_printer_styles.cjs` checks desktop/mobile rendering, long unknown
codes, accessible links, paused banners and existing layout/focus behavior.
No real printer fault is injected by these tests.

## Accepted deployment, 2026-10-20

The feature is live at `https://3dprint.cswine.cloud` from the versioned mini
release `b415870-printer-alerts-20261020`. It uses the deployed historical source
baseline `b4158705155c9fc901d9b2bd3e07e968636d99cc` plus the prior socket-lifetime
fix/diagnostics and this feature's exact patch. The new feature source remains
local working-tree changes; this is not a claim that it has been committed.

- Source patch SHA-256: `bf7a8e5becd58b9f772055a8b1f2c4cf8f928e211bca7bab90f3621e21983615`.
- Unsigned executable: `5a37e8dbd0b6f5408b514d3a8a8b85aeb2b97b3e89705281ee2bd2cb384d2702`.
- Signed executable: `63ca5e8d3cc34e03852e9b57def3164285c1c0481da6aab907a0c20f8cac3474`.
- Accepted PID: 7499; preceding app backup is
  `rollback/writer-lifetime-20261020T053806Z/PrinterHost.app`.
- Shared maintenance file unchanged across installation:
  `8bdd19ea90cb9c63b667154d295669222868d9391e45fc8d5a86eeff8969957f`.
  Revision 1 and the existing A1 spool issue (id 1) are retained.

The primary and exact production-baseline binaries passed all four synthetic
native gateway cases (demo/TLS peers, one/four harts), including runout/feeding
fault delivery, live clearing, auth and camera regressions. The pure telemetry
suite and real Chromium desktop/mobile style/media checks passed. The deployed
service then passed public real A1/P1S telemetry, cameras/sharing/cleanup, WSS,
maintenance and logout acceptance. Real Chromium verified the new card panels,
A1 FAILED banner, both cameras, responsive widths and client-side key handling.

Evidence in ignored `build/printer-alerts-20261020/` and alongside the release:
`public-acceptance.json`, `public-browser.json`, `live-alert-projection.json`,
`release.patch`, `source-provenance.json` and `deployment.json`.

The newly exposed real P1S HMS code `0300310000010001` was categorized as fan
attention. The installed Bambu English catalog identifies it as the part-cooling
fan running too slowly or stopping (possible obstruction or connector issue).
This is the printer's report, not a physical diagnosis. The globe remained
RUNNING at 18% during verification. The A1 was FAILED with print_error zero,
confirming why the failed-job banner must be independent of numeric fault codes.
No printer pause/resume/temperature/print commands were sent during this rollout.
