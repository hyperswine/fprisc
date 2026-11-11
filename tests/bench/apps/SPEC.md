# Application workloads: specification

Six whole-program workloads that measure ordinary application code, not
micro-kernels (item 0 of [performance priorities](../../../docs/2026-11-09-PERFORMANCE-PRIORITIES.md)).
Every implementation, in every language, must print **byte-identical** stdout.
Inputs come from `gen.py` (deterministic, no dependencies) into `data/`.

The LCG used everywhere is

    lcg(x) = (x * 1103515245 + 12345) mod 2147483648

on non-negative 64-bit integers (the product fits in 63 bits). All arithmetic
below is 64-bit signed integer arithmetic; no floating point anywhere.
`mod` on non-negative operands only. `M = 1000000007`.

Peers are written the way an experienced programmer writes them in that
language: standard library collections, in-place arrays where the language
encourages them, no hand-tuned SIMD, no unsafe tricks, single-threaded.

## csv: parse and aggregate

Input `data/sales.csv`: 1,000,000 lines, each `KEY,A,B\n` with no header,
where KEY is `k` followed by 4 digits (1000 distinct keys), A in 0..999 and
B in 0..99999, written in decimal without leading zeros.

Read the whole file, split it into lines, split each line on `,`, parse A and
B as integers. Per key, keep count, sum of A and max of B.

Output:

    keys K lines N
    KEY count sumA maxB        (10 lines)

where the 10 lines are the keys with the largest sumA, ties broken by KEY
ascending (byte order).

## wordfreq: word counts, top 10

Input `data/corpus.txt`: 2,000,000 lowercase ASCII words from 50,000 distinct,
separated by single spaces, a newline after every 12th word.

Split on whitespace, count each word, sort (word, count) by count descending
then word ascending, print

    distinct D total T
    WORD COUNT                 (10 lines)

## format: string building

No input. For i in 0..999999 build the line

    order I cust cC qty Q total D.CC status S

- C = (i * 7919) mod 10007
- Q = i mod 17 + 1
- cents = (i * 104729) mod 1000000; D = cents / 100; CC = cents mod 100
  written with exactly two digits (leading zero)
- S = `open` if i mod 3 = 0, `paid` if i mod 3 = 1, `shipped` otherwise

Keep every line (the program must hold all 1,000,000 strings, as a report
builder would), then print

    lines 1000000 bytes B hash H
    LINE 0
    LINE 499999
    LINE 999999

where B is the sum of the byte lengths of the lines (no newlines counted) and
H is the fold h = (h * 31 + len(line)) mod M from h = 0, in order i = 0..999999.

## records: three-key sort and group-by

No input. x = 42. For id in 0..999999: x = lcg(x); the record is

- dept = x mod 100
- age = 18 + (x / 100) mod 63
- salary = 30000 + (x / 6300) mod 90000

Sort all records by dept ascending, then age descending, then id ascending.
Then group consecutive records by dept. Output:

    records 1000000 order O
    DEPT count sumSalary firstId   (one line per dept present, ascending)

where O is the fold o = (o * 31 + id) mod M over ids in sorted order, and
firstId is the id of the first record of that dept in sorted order.

## treemap: ordered map inserts and lookups

No input. x = 7. 500,000 times: x = lcg(x); insert key x mod 1000000 with
value i (the loop index, 0-based), replacing an existing value. Then,
continuing from the same x, 500,000 times: x = lcg(x); look up x mod 1000000;
on a hit add 1 to hits and the value to sum. Output one line:

    size S hits H sum U keyhash K

K is the fold k = (k * 31 + key) mod M over the keys in ascending order.
Peers use their standard ordered map where one exists (Rust `BTreeMap`, OCaml
`Map`, Java `TreeMap`); Go and C use a hash map and sort the keys for K.

## sim: particle simulation

No input. x = 1. 20,000 particles; for each, in order, draw four values:
x = lcg(x), px = x mod 1000000; x = lcg(x), py = x mod 1000000;
x = lcg(x), vx = x mod 2001 - 1000; x = lcg(x), vy = x mod 2001 - 1000.

2,000 steps. Each step updates every particle:

    vy = vy - 1
    px = px + vx; if px < 0 { px = -px; vx = -vx } else if px > 1000000 { px = 2000000 - px; vx = -vx }
    py = py + vy; if py < 0 { py = -py; vy = -vy } else if py > 1000000 { py = 2000000 - py; vy = -vy }

Output one line:

    particles 20000 steps 2000 sx SX sy SY energy E

SX and SY are the sums of px and py; E is the sum of vx*vx + vy*vy.
