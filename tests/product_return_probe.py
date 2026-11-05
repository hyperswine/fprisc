"""Select the real reader/return-worker closure for independent ABI oracles."""
import re


def emitted_bodies(whole, roots):
    functions = {m[1]: m[0] for m in re.finditer(
        r'^(fpr_fn_[A-Za-z0-9_]+):\n.*?(?=^# native-insns-v1:)', whole, re.M | re.S)}
    assert all(name in functions for name in roots), roots
    pending, seen, bodies = list(roots), set(), []
    while pending:
        name = pending.pop(0)
        if name in seen:
            continue
        seen.add(name)
        body = functions[name]
        bodies.append('.globl '+name+'\n'+body)
        # With constructor inlining disabled, a nominal unary producer may
        # call its constructor's own payload worker. Include the emitted
        # closure, not a replacement implementation of that worker.
        pending.extend(n for n in re.findall(r'\bfpr_fn_[A-Za-z0-9_]+', body)
                       if n in functions and n not in seen)
    result = '\n'.join(bodies)
    assert 'fpr_alloc' not in result, 'unexpected product materialization'
    return result


def return_bodies(whole, width):
    return emitted_bodies(whole, ['fpr_fn_loop', f'fpr_fn__x24worker_x2eret{width}_x2emake'])
