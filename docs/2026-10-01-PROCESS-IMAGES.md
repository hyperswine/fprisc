# Mortal process images in the runtime

Date: 2026-10-01. Kind: implementation record, the runtime half of QOS's
`docs/2026-10-01-PROCESS-IMAGES.md`. That page has the loader and the build;
this one covers what the runtime itself had to learn.

## The registry (`runtime.c`, `fpr.h`)

QOS now places a native process image in an ordinary buddy block. An image's
cells (string literals, nullary constructors, static closures) have no
16-byte allocation preheader. So `fpr_in_heap` must not call them heap, even
though they lie inside the buddy's span.

- `fpr_image_add(im)` / `fpr_image_remove(im)` register a block as the image
  of process `im->pid`.
- One bit per buddy minimum block marks image blocks, which makes
  `fpr_in_heap`'s test O(1) and lock-free. The map is sized from the buddy's
  span at the first registration (`buddy_geometry`), so it is a fact of the
  machine, not a chosen limit. It replaces the kernel's use of the single
  `fpr_static_lo/hi` window. An image's own runtime still uses that window
  for its own cells.
- The records (range and pid) are a list under a lock, read only on the slow
  paths. `fpr_image_of_pid` and `fpr_image_count` answer the loader.
- `fpr_pid_quiet` is a hook `reap()` calls for each reclaimed actor of a
  process. QOS's loader frees the image when `fpr_pid_live(pid)` is 0.

## What may leave an image (`runtime.c` deep copier, `actors.c`)

Every copy now knows the process it is for. `fpr_hart_t.copy_pid` is set by
`msg_copy_in`. `fpr_msg_copy_to(v, pid)` is used by `send` and `sendLinear`
(the receiver's pid) and by `spawn` (the child's pid).
`fpr_msg_copy`/`fpr_msg_copy_fresh` use the current actor's pid.

| Static met by the copier | Receiver in the image's process | Receiver elsewhere |
|---|---|---|
| any data static (string, header-only constructor, Result, device) | shared by identity, as before | **copied** into the message |
| a static closure, or a heap closure whose code is in the image | shared | **refused**: the sender fails alone (`fpr_actor_fail`) |
| a static of an unexpected shape | shared | refused, by name |

The copier can size a static without a preheader only because the generator
and the runtime make few shapes of them:

- **Generated** (`Codegen.hs`): strings, header-only nullary constructors,
  and static closures (`fpr_obj_*`).
- **Runtime C**: `fpr_unit`/`true`/`false`, a few static `Result`s in
  `actors.c`, device handles, and `FPR_FN` closures.

A new kind of static must be added to `img_static_raw`. Until it is, it is
refused, not mis-copied.

`sendArc` across processes falls back to a copying send. `sendLinear`
moves only within a process. Both would otherwise hand the receiver the
sender's statics by identity.

## Verified

`tests/base/images.fpr` with `tests/base/images_probe.c` runs in `check_base`
on 1 and 2 harts. The probe registers a fake image as process 7. The string
it holds, sent by process 0, outlives the image being poisoned and freed.
Sending its closure ends the sender, and the parent hears `Err dead actor`.

The QOS check `tools/nativeimage-check.sh` covers the real loader on QEMU.

## Also

- `machine/virt/link.ld` lost the 32 MiB `_proc_arena` after the heap, and
  `fpr.h` lost its declaration. `hal_heap_span`'s span ends at the heap's
  end. The heap is unchanged (128 MiB).
- `machine/virt/link-app.ld` links an image at `PROC_IMAGE_BASE` (0), for
  relocation.
