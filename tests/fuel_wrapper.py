"""The ticks' register-saving slow path (fpr_fuel_save_local) is emitted once
per assembly unit, after its functions (Codegen.emitProgram). A harness that
links function bodies cut out of a unit appends it with this."""
import re

def fuel_wrapper(text):
    m = re.search(r'(?ms)^fpr_fuel_save_local:\n.*?^\s*ret\n', text)
    return '\n' + m.group(0) if m else ''
