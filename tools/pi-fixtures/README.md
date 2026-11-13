# Pi build fixtures

These FP-RISC sources and seven plans are the build inputs for
`tools/build-pi-runtime-qualification.sol`. They replace runtime imports of
Python test modules. Shared sources are stored once; each plan records its own
compiler controls, allocation expectations, test arguments and expected output.
`@ROOT@` and `@OUT@` are expanded by the Sol driver. Case expansion and scheduler
fixture generation remain in the existing Sol modules.

Change a fixture and its expectations together. The independent migration
oracle lives under `tests/build-reference/`; it is test-only and is never
installed or executed by a build or packaging command.
