"""Configuration registry shared by Base and CI. Distinct modes stay distinct.

Only an explicitly successful CI configuration may cover a Base invocation.
--require-execution strengthens the same check; other arguments/environments
need an explicit coverage declaration and stay separate configurations.
"""
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class Check:
    id: str
    path: str
    timeout: int
    args: tuple = ()
    env: tuple = ()
    alone: bool = False
    lock: str | None = None
    covers: tuple = ()


BASE = []


def base(path, timeout, alone=False, lock=None):
    BASE.append(Check(path, path, timeout, alone=alone, lock=lock))


base('tests/test_check_registry.py', 60)
base('tests/check_core_pipeline.py', 240, lock='cabal')
base('tests/check_compiler_options.py', 300, lock='cabal')
base('tests/check_frontend.py', 240, lock='cabal')
base('tests/check_inference_evidence.py', 240, lock='cabal')
base('tests/check_typed_core.py', 240, lock='cabal')
base('tests/check_typed_ir.py', 900, lock='cabal')
base('tests/check_typed_ir_a64.py', 1200)
base('tests/check_typed_ir_x64.py', 1200)
base('tests/check_typed_ir_kernels.py', 1200)
base('tests/check_x64_retirement.py', 300)
base('tests/check_float_trees.py', 300)
base('tests/check_captured_simd.py', 300)
base('tests/check_typed_ir_builtin.py', 300)
base('tests/check_typed_ir_arc.py', 600)
base('tests/check_native_insns_ratchet.py', 300)
base('tests/check_rv32_float_constants.py', 300)
base('tests/check_a64_fp_pool.py', 600)
base('tests/check_a64_retirement.py', 600)
base('tests/check_self_loops.py', 600, lock='cabal')
base('tests/check_self_loop_x64.py', 300)
base('tests/check_x64_scalar.py', 300)
base('tests/check_x64_qos.py', 300)
base('tests/check_x64_macos.py', 900)
base('tests/check_self_loop_rv64.py', 600)
base('tests/check_rv64_linux.py', 120)
base('tests/check_typed_ir_rv_module.py', 600)
base('tests/check_typed_ir_rv_startup.py', 600)
base('tests/check_typed_ir_rv_frames.py', 1200)
base('tests/check_typed_ir_a64_frames.py', 1200)
base('tests/check_typed_ir_x64_frames.py', 1200)
base('tests/check_native_data.py', 300)
base('tests/check_native_required.py', 300)
base('tests/check_stack_reservation.py', 600)
base('tests/check_fixed_stack_reservation.py', 600)
base('tests/check_typed_ir_qrv64.py', 600)
base('tests/check_typed_ir_esp.py', 600)
base('tests/check_byte_strings.py', 300)
base('tests/check_view_construction.py', 600)
base('tests/check_inbox.py', 300)
base('tests/check_check_only.py', 120)
base('tests/check_commit_interfaces.py', 300)
base('tests/check_publication.py', 600)
base('tests/check_watch_app.py', 600)
base('tests/check_live_runner.py', 600)
base('tests/check_live_writer_lifetime.py', 300, alone=True)
base('tests/check_pos_reload.py', 1800)  # three cold POS app builds
base('tests/check_posix_modules.py', 600)
base('tests/check_posix_pic.py', 300)
base('tests/check_owned_watchers.py', 300)
base('tests/check_loop_state.py', 300)
base('tests/check_receive_turns.py', 600)
base('tests/check_mvu_reload.py', 600)
base('tests/check_deadlines.py', 300)
base('tests/check_actor_reap.py', 120)
base('examples/ideal/check.py', 600)
base('tests/check_higher_order_contracts.py', 600)
base('tests/check_contract_rewrites.py', 600)
base('tests/check_printer_ownership.py', 600)
base('tools/sol-linearity-check.py', 300)
base('tests/check_structural_ownership.py', 300)
base('tests/check_generic_ownership.py', 600)
base('tests/check_pos_core.py', 300)
base('tests/check_pagination.py', 300)
base('tests/check_typed_vectors.py', 300)
base('tests/check_vector_limits.py', 300)
base('tests/check_vector_kinds.py', 300)
base('tests/check_vector_pipelines.py', 600)
base('tests/check_reuse.py', 600, lock='cabal')
base('tests/check_consuming_reuse.py', 600)
base('tests/check_x64_vectors.py', 300)
base('tests/check_wide_params.py', 300)
base('tests/check_vector_fallback_frames.py', 600)
base('tests/check_trust.py', 60)
base('tests/check_specialization.py', 300, lock='cabal')
base('tests/check_workers.py', 300, lock='cabal')
base('tests/check_wide_workers.py', 600)

BY_ID = {c.id: c for c in BASE}


def ci(path, *, required=False, args=(), env=(), variant=None, covers=False, timeout=1200):
    original = BY_ID.get(path, Check(path, path, timeout))
    args = (('--require-execution',) if required else ()) + args
    default_mode = not args and not env
    required_mode = args == ('--require-execution',) and not env and variant is None
    if not default_mode and not required_mode and variant is None:
        raise ValueError('extra modes need their own variant and coverage review')
    suffix = variant or ('required' if required else '')
    # Exact defaults and execution-required versions cover the Base default.
    covered = (path,) if path in BY_ID and (default_mode or required_mode or covers) else ()
    return replace(original, id=path + ('::' + suffix if suffix else ''),
                   args=args, env=env, covers=covered, timeout=max(original.timeout, timeout))


GROUPS = {
    'rv32-runtime': (
        ci('tests/check_rv32_float_constants.py', required=True),
        ci('tests/check_fixed_stack_reservation.py', required=True),
    ),
    'native': (
        ci('tests/check_native_data.py'),
        ci('tests/check_native_required.py'),
        ci('tests/check_typed_ir_a64.py'),
        ci('tests/check_typed_ir_a64_frames.py'),
        ci('tests/check_typed_ir_x64.py', required=True),
        ci('tests/check_typed_ir_x64_frames.py'),
        ci('tests/check_typed_ir_x64.py', required=True,
           args=('--entry-optimizations',), variant='entry-optimizations'),
        ci('tests/check_typed_ir_aggregates.py'),
        ci('tests/check_typed_ir_coverage.py'),
        ci('tests/check_typed_ir_kernels.py', required=True),
        ci('tests/check_typed_ir_bench.py'),
    ),
    'riscv': (
        ci('tests/check_typed_ir_rv.py', required=True, args=('--width', '32'), variant='rv32'),
        ci('tests/check_typed_ir_rv.py', required=True, args=('--width', '64'), variant='rv64'),
        ci('tests/check_typed_ir_rv_module.py', required=True),
        ci('tests/check_typed_ir_rv_startup.py', required=True),
        ci('tests/check_typed_ir_rv_frames.py', required=True),
        ci('tests/check_stack_reservation.py'),
        ci('tests/check_typed_ir_qrv64.py', required=True),
        ci('tests/check_typed_ir_esp.py', required=True),
        ci('tests/check_typed_ir_builtin.py', required=True),
        ci('tests/check_typed_ir_arc.py', required=True),
        ci('tests/check_self_loop_rv64.py'),
    ),
    'rv64-typed': (
        ci('tests/check_rv64_linux.py', args=('--typed-ir', '--cc', 'riscv64-linux-gnu-gcc',
           '--output', '{output}/rv64-typed', '--runner', 'qemu-riscv64 -L /usr/riscv64-linux-gnu'),
           env=(('FPR_TYPED_IR_BACKEND', 'mixed'),), variant='typed-runtime'),
    ),
    'host-extra': (
        ci('tests/check_i32.py'),
        # ARC runs check_raw with a strict typed environment. Keep this default
        # environment invocation too; those are different configurations.
        ci('tests/check_raw.py'),
        ci('tests/check_self_loops.py'),
        ci('tests/check_workers.py'),
        ci('tests/check_registers.py'),
        # Same default lowering assertions as Base, plus the cross-built runtime.
        ci('tests/check_rv64_linux.py', args=('--cc', 'riscv64-linux-gnu-gcc',
           '--output', '{output}/rv64', '--runner', 'qemu-riscv64 -L /usr/riscv64-linux-gnu'),
           variant='runtime', covers=True),
    ),
}
CI = {c.id: c for group in GROUPS.values() for c in group}
assert len(CI) == sum(map(len, GROUPS.values())), 'duplicate CI configuration ID'
