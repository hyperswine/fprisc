# Generator retirement acceptance

Final compiler: codegen 89, SHA-256 recorded in `metadata.json`. The compiler
remained unchanged throughout these acceptance runs. This directory describes
local results; hosted CI must be checked against the committed revision.

| Gate | Evidence | Result |
|---|---|---|
| Complete Base sweep | `base.log`, `base.exit` | 123 jobs, 524 seconds, four workers, exit 0 |
| Independent static data / mandatory native coverage | Included in Base; frozen predecessor fixtures in `tests/typed_ir/native_data.golden` | Pass; unsupported coverage and retired aliases refuse before output |
| Predecessor emission parity | `emission-parity.py`, `.json`, `.log`, `.exit` | 20 cases, four selectors, 5,762 function texts/order/instruction reports identical after cache identity normalization |
| Linux RV64 production runtime | `linux-rv64.log`, `.exit`, `linux-rv64-results.json` | All 17 real runtime/module cases pass under QEMU user mode |
| Linux x64 production runtime | `linux-x64.py`, `.log`, `.exit` | Nine nested 9,000-field frames; default/32 KiB first stacks, one/four harts pass under QEMU user mode |
| Linux A64 native runtime | `linux-a64.py`, `.log`, `.exit` | FP context bits, negative control, live FP values, yields/calls/large frames, one/four harts pass |
| Clean source package and installed compiler | `package-layout.log`, `clean-package-build.log`, `.exit`, `installed-smoke.log`, `.exit` | Package excludes retired modules, fresh isolated Cabal project builds, hosted smoke runs |
| Physical 48 MHz Tang Nano | `tang-fixed-stack.log`, `.exit` | Fitting frames and expected pre-frame exhaustion pass; RAM uploads only |
| Complete QOS sweep | `qos-full.log`, `.exit` | 155 pass, 0 fail, 7 registered skips of 162 legs |
| Supplemental FPRLive | `qos-fprlive-pass.log`, `.exit` | Complete protocol, hostile input, capacity, event storm, slow consumer and restart persistence pass |
| Supplemental POS1 | `qos-pos1-final.log`, `.exit` | Complete suite, four crash windows and 300 receipts against a 50-row page pass |
| QOS native budget | `qos-native-final.json`, `.log`, `.exit` | 1,699 functions / 28 files; maximum segment 312, runtime call sites 67; ceilings unchanged |
| QOS parser bounds | `coreutil-bounds.log` | Maximum Int accepted and oversized natural rejected on Portable and RV64 QEMU |
| Harness failure controls | `http-readiness-controls.log` | Three HTTP readiness controls and eight sweep-verdict tests pass |
| Stronger inliner behavior parity | `register-inliner-parity.log`, `.exit` | Inliner on/off parity plus 285 independent x64 C-reference cases pass |

The QOS sweep ran before its supplemental harness/demo/parser repairs. Its
WebSocket checks had missing dependencies, and its passing-leg count includes
those old implicit skips. The private `build/typed-retirement-web-tests` environment
then supplied the dependency and both full suites above actually executed.
The seven registered skips require unavailable A64 Linux tools or Linux Xvfb/
GLFW/xdotool in that host environment. The log also explicitly skips Linux DRM,
GPU dispatch capture and an A64 hand-JIT subcheck. These are unexecuted scopes,
not passing physical or graphical results. Separate Linux A64 native-runtime
tests above cover the compiler context/large-frame contract.

Supplemental checks exposed old behavior also reproduced with the pre-deletion
g88 compiler: HTTP listeners become available before application storage replay,
the generated JavaScript uses a parenthesized WebSocket constructor, the POS
fixture selected the typed-style helper for legacy named classes, and the shared
strict decimal parser could overflow before rejecting hostile input. QOS repairs
wait for an actual HTTP 200, assert the emitted client/field/layout CSS, use the
matching stylesheet helper, and check decimal bounds before arithmetic. Both
complete WebSocket suites and the refreshed instruction budget use those repairs.
The original full QOS sweep was not repeated after these focused changes.

Earlier failed or developmental WebSocket logs are retained by their original
names (`qos-fprlive*.exit` values 1, `qos-pos1.exit`), and predecessor timing/full
controls identify their old failure classes. They are not final acceptance.
`development/` holds migration-test expectation corrections. The negative Tang
case intentionally produces an exhaustion trace and exit 1 inside a passing
outer oracle; `tang-fixed-stack.exit` is the acceptance status.

The two temporary Linux containers were removed after successful tests. The
attached non-Tang serial device identified as ESP32-D0WDQ6-V3, not P4; no flash
was written, and physical P4 acceptance remains unavailable. Earlier QEMU,
physical board and paired performance increments retain their own source hashes
and scope in the adjacent dated evidence directories.

`production-audit.json` records absent old modules and no live compiler readers
of their APIs, switches or instruction bounds. Performance follow-ups such as
fused SIMD pipelines, other targets' FP pools and dynamic-width compaction do not
provide missing functionality for any retired generator consumer.
