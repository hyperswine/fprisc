"""The unit-local slow-path wrappers are emitted once per assembly unit, after
its functions (Codegen.emitProgram): the ticks' (fpr_fuel_save_local) and the
inline bump allocation's refill (fpr_alloc_save_local, 2026-11-03). A harness
that links function bodies cut out of a unit appends them with this."""
import re

def fuel_wrapper(text, body=None):
    """Each wrapper the unit has; with `body` (the cut-out functions), only
    the ones it calls, so an oracle need not define fpr_alloc for bodies that
    never allocate."""
    out = ''
    for name in ('fpr_fuel_save_local', 'fpr_alloc_save_local'):
        m = re.search(rf'(?ms)^{name}:\n.*?^\s*ret\n', text)
        if m and (body is None or name in body):
            out += '\n' + m.group(0)
    return out
