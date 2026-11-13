"""Typed scalar hand-offs for a finite, sequential builtin application."""

import re
from check_target_image import require

SCHEMA = "static-builtin-sequence-v1"
PREVIOUS = {"previous": True}


def parse_sequence(document):
    require(
        isinstance(document, dict)
        and set(document) == {"schema", "steps"}
        and document["schema"] == SCHEMA,
        "invalid static sequence schema",
    )
    steps = document["steps"]
    require(
        isinstance(steps, list) and steps, "a static sequence needs at least one step"
    )
    for index, step in enumerate(steps):
        require(
            isinstance(step, dict) and set(step) == {"entry", "arguments"},
            "invalid static sequence step",
        )
        name = step["entry"]
        require(
            isinstance(name, str) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]*", name),
            "invalid source entry name",
        )
        require(isinstance(step["arguments"], list), "step arguments must be a list")
        for argument in step["arguments"]:
            if type(argument) is int:
                continue
            require(
                isinstance(argument, dict)
                and set(argument) == {"previous"}
                and argument["previous"] is True,
                "sequence argument must be an integer or a previous-result reference",
            )
            require(index > 0, "first step has no previous result")
    return steps


def invocation(steps, symbols, signatures, kinds, literal, heap_setup, checkpoint):
    """Use a read-only schedule and one statically linked call site per entry."""
    members = {"KWord": "word", "KInt": "integer", "KBool": "boolean", "KUnit": "unit"}
    numbers = {name: i for i, name in enumerate(symbols)}
    instructions = []
    constants = []
    previous_kind = None
    for step in steps:
        name = step["entry"]
        params, result = signatures[name]
        require(
            len(params) == len(step["arguments"]),
            "argument count differs from the checked callback signature",
        )
        offset = len(constants)
        previous_mask = 0
        for i, (kind, value) in enumerate(zip(params, step["arguments"])):
            if type(value) is int:
                constants.append(literal(kind, value))
            else:
                require(
                    previous_kind == kind,
                    "previous result kind differs from the checked parameter",
                )
                previous_mask |= 1 << i
                constants.append("0")
        instructions.append(f"{{{numbers[name]}, {offset}, UINT64_C({previous_mask})}}")
        previous_kind = result

    declarations = []
    cases = []
    for name, symbol in symbols.items():
        params, result = signatures[name]
        result_type = "void" if result == "KUnit" else kinds[result]
        declarations.append(
            f"extern {result_type} {symbol}("
            + (",".join(kinds[k] for k in params) or "void")
            + ");"
        )
        args = [
            f"((step->previous & (UINT64_C(1)<<{i})) ? state.{members[kind]} : ({kinds[kind]})fpr_static_literals[step->offset+{i}])"
            for i, kind in enumerate(params)
        ]
        call = symbol + "(" + ",".join(args) + ")"
        statement = (
            call + "; state.unit=0;"
            if result == "KUnit"
            else f"state.{members[result]}={call};"
        )
        cases.append(f"case {numbers[name]}: {statement} break;")
    declarations.append(
        "static const uint64_t fpr_static_literals[]={"
        + (",".join(constants) or "0")
        + "};"
    )
    declarations.append(
        "static const struct static_step {uw entry,offset,previous;} fpr_static_steps[]={"
        + ",".join(instructions)
        + "};"
    )
    dispatch = (
        "union { uintptr_t word,unit; intptr_t integer; int boolean; } state={0};\n"
        "for (uw i=0; i<sizeof(fpr_static_steps)/sizeof(fpr_static_steps[0]); ++i) {\n"
        "const struct static_step *step=&fpr_static_steps[i];\n"
        "if (i) {\n" + checkpoint + heap_setup + "}\n"
        "switch (step->entry) {\n"
        + "\n".join(cases)
        + '\ndefault: fpr_cpanic("invalid static entry");}\n}\n'
        f"fpr_static_result=(uw)state.{members[previous_kind]};"
    )
    return "\n".join(declarations), dispatch
