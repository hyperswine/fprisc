"""Count a finite controlled RV64 callback path, including linked callees.

An ordinary call costs its instruction, the called activation and the caller's
continuation. A tail jump has only a target. Conditional branches choose the
larger successor bound. Only a verified ABI return terminates an activation.
"""
from graphlib import CycleError, TopologicalSorter

if __package__:
    from .check_linked_stack import Image, MASK, reachable_functions
    from .check_target_image import require
else:
    from check_linked_stack import Image, MASK, reachable_functions
    from check_target_image import require


def callback_work(data, symbols, steps, limit):
    """data has passed target/placement admission; symbols are public adapters."""
    require(type(limit) is int and 0 < limit < 2**64, 'invalid callback instruction budget')
    steps = tuple(steps)
    require(steps and all(name in symbols for name in steps), 'invalid callback instruction schedule')
    image = Image(data)
    entries = {}
    for name, symbol in symbols.items():
        require(symbol in image.symbols and image.symbols[symbol][1] == 1,
                'missing/weak callback instruction root: ' + symbol)
        entries[name] = image.symbols[symbol][0]

    # Keep activation identity separate from PC. Two callers can share a
    # target without accidentally acquiring one another's return paths.
    functions = reachable_functions(image, entries.values(), include_control=True)
    order = TopologicalSorter()
    for entry, facts in functions.items():
        for pc, (callee, successors) in facts['control'].items():
            children = [(entry, target) for target in successors]
            if callee is not None:
                children.append((callee, callee))
            order.add((entry, pc), *children)

    counts = {}
    try:
        for entry, pc in order.static_order():
            callee, successors = functions[entry]['control'][pc]
            continuation = max((counts[entry, target] for target in successors), default=0)
            bound = 1 + continuation + (counts[callee, callee] if callee is not None else 0)
            require(bound <= MASK, 'callback work exceeds the RV64 instruction budget domain')
            counts[entry, pc] = bound
    except CycleError as exc:
        entry, pc = exc.args[1][0]
        raise ValueError(f'callback instruction bound unproved: reachable cycle in {image.label(entry)} at {pc:#x}') from exc

    per_entry = {name: counts[entry, entry] for name, entry in entries.items()}
    total = sum(per_entry[name] for name in steps)
    require(total <= limit, f'callback work needs {total} instructions, limit {limit}')
    return dict(schema='linked-rv64-callback-instructions-v1', per_entry=per_entry, symbols=dict(symbols),
                callbacks=len(steps), required=total, limit=limit,
                linked_functions=[dict(symbol=image.label(entry),address=entry,instructions=counts[entry,entry])
                                  for entry in sorted(functions)],
                scope='C ABI callback entry through return, including generated adapters and all synchronous callees. '
                      'Counts RV64 IMC instructions. Startup, dispatcher, resets, interrupts and elapsed time are outside this budget.',
                return_policy='Checks preserved registers, stack balance, intact saved return links and frame-confined writes at each activation.',
                assumptions=['Valid memory reads and instruction fetches, immutable code and no asynchronous handlers or external mutation of active frames.'])
