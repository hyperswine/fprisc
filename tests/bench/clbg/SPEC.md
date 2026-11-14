# Benchmarks Game suite: specification

Eight programs from the Computer Language Benchmarks Game
(https://benchmarksgame-team.pages.debian.net/benchmarksgame/), written in
FP-RISC and in C, Rust, Go, Java, OCaml, Haskell, JavaScript (Node) and
Python. Every implementation of a program must print **byte-identical**
stdout for the same argument.

The two Benchmarks Game programs not here are `pidigits` (needs arbitrary
precision integers, which FP-RISC does not have) and `regex-redux` (needs a
regular expression library, which FP-RISC does not have).

## Running

From this directory, with `fpr` (or `FPR=...`) and the peer toolchains on PATH:

    sol build.sol < /dev/null          # peers into bin/, FP-RISC into bin-fpr/, inputs into data/
    sol run.sol < /dev/null            # all programs and languages; RUNS=3, LANGS=fpr,c,...
    sol run.sol nbody fasta < /dev/null

`run.sol` checks every output against `expected/<program>.md5` and writes
`results/<date>-<host>.md` and `.tsv`.

## Rules for every implementation

- **Single-threaded.** No threads, goroutines, domains, parallel streams,
  worker processes or SIMD intrinsics. The fastest Benchmarks Game entries are
  multi-core and hand-vectorised; these are not. FP-RISC programs run on one
  hart, and the comparison is per core.
- **Idiomatic.** Write the program the way an experienced programmer writes
  it in that language: standard library collections and I/O, in-place arrays
  where the language encourages them, buffered output. No `unsafe` blocks in
  Rust, no hand-rolled allocators or memory pools, no third-party packages
  (Haskell may use the packages that ship with GHC: `base`, `containers`,
  `bytestring`, `array`). Python is plain CPython with no numpy.
- **Same algorithm.** Follow the steps below, including the order of floating
  point operations where it is given, so the printed digits agree.
- **Arguments.** Each program takes one command-line argument: N, or for the
  two input programs the path of an input file. With no argument it uses the
  default given below.
- **Output** goes to stdout. Floats print in fixed notation with the stated
  number of decimals, rounded as C's `printf` rounds.

## Default sizes

| program        | argument                 | default |
|----------------|--------------------------|---------|
| binarytrees    | N (max depth)            | 18      |
| fannkuchredux  | N                        | 10      |
| nbody          | N (steps)                | 5000000 |
| spectralnorm   | N                        | 2000    |
| mandelbrot     | N (width = height)       | 4000    |
| fasta          | N                        | 2500000 |
| knucleotide    | path of a fasta output   | `data/fasta-1000000.txt` |
| revcomp        | path of a fasta output   | `data/fasta-2500000.txt` |

The input files are `fasta 1000000` and `fasta 2500000` written to `data/`.

## binarytrees

A tree is either empty or a node with a left and a right subtree (nodes carry
no value). `make(d)` builds a perfect tree: depth 0 is a node with two empty
children; depth d is a node whose children are `make(d-1)`. `check(t)` counts
nodes: `1 + check(left) + check(right)`, 0 for empty.

Every tree must be allocated node by node and become garbage (or be freed)
when it is no longer used; no pools, no arenas, no reusing nodes.

    minDepth = 4
    maxDepth = max(minDepth + 2, N)
    stretch  = maxDepth + 1
    print "stretch tree of depth {stretch}\t check: {check(make(stretch))}"
    long = make(maxDepth)                       # kept alive to the end
    for d = minDepth; d <= maxDepth; d += 2:
        iters = 2^(maxDepth - d + minDepth)
        sum = 0; repeat iters times: sum += check(make(d))
        print "{iters}\t trees of depth {d}\t check: {sum}"
    print "long lived tree of depth {maxDepth}\t check: {check(long)}"

Check: N=10 prints

    stretch tree of depth 11	 check: 4095
    1024	 trees of depth 4	 check: 31744
    256	 trees of depth 6	 check: 32512
    64	 trees of depth 8	 check: 32704
    16	 trees of depth 10	 check: 32752
    long lived tree of depth 10	 check: 2047

## fannkuchredux

Permutations of 0..N-1 in the Benchmarks Game order, counting pancake flips.
Arrays are 0-based.

    perm1 = [0, 1, ..., N-1]; count = [0] * N
    maxFlips = 0; checksum = 0; permIndex = 0; r = N
    loop:
        while r != 1: count[r-1] = r; r -= 1
        perm = copy of perm1
        flips = 0; k = perm[0]
        while k != 0:
            reverse perm[0..k] (inclusive); flips += 1; k = perm[0]
        maxFlips = max(maxFlips, flips)
        checksum += flips if permIndex is even else -flips
        # next permutation
        loop:
            if r == N: print "{checksum}"; print "Pfannkuchen({N}) = {maxFlips}"; stop
            p0 = perm1[0]
            for i in 0 .. r-1: perm1[i] = perm1[i+1]
            perm1[r] = p0
            count[r] -= 1
            if count[r] > 0: break
            r += 1
        permIndex += 1

Check: N=7 prints `228` and `Pfannkuchen(7) = 16`; N=10 prints `73196` and
`Pfannkuchen(10) = 38`.

## nbody

Five bodies, 64-bit floats. Constants:

    PI = 3.141592653589793
    SOLAR_MASS = 4 * PI * PI
    DAYS_PER_YEAR = 365.24

Bodies in this order, positions x y z, velocities vx vy vz, then mass. Each
velocity is multiplied by DAYS_PER_YEAR and each mass by SOLAR_MASS.

    sun      0 0 0, 0 0 0, 1
    jupiter  4.84143144246472090e+00 -1.16032004402742839e+00 -1.03622044471123109e-01
             1.66007664274403694e-03  7.69901118419740425e-03 -6.90460016972063023e-05
             9.54791938424326609e-04
    saturn   8.34336671824457987e+00  4.12479856412430479e+00 -4.03523417114321381e-01
            -2.76742510726862411e-03  4.99852801234917238e-03  2.30417297573763929e-05
             2.85885980666130812e-04
    uranus   1.28943695621391310e+01 -1.51111514016986312e+01 -2.23307578892655734e-01
             2.96460137564761618e-03  2.37847173959480950e-03 -2.96589568540237556e-05
             4.36624404335156298e-05
    neptune  1.53796971148509165e+01 -2.59193146099879641e+01  1.79258772950371181e-01
             2.68067772490389322e-03  1.62824170038242295e-03 -9.51592254519715870e-05
             5.15138902046611451e-05

Offset momentum: px = sum of vx*mass over all bodies (likewise py, pz); then
sun.vx = -px / SOLAR_MASS (likewise vy, vz).

    energy: e = 0
      for i: e += 0.5 * m_i * (vx_i^2 + vy_i^2 + vz_i^2)
             for j > i: dx = x_i - x_j (dy, dz); e -= m_i * m_j / sqrt(dx^2 + dy^2 + dz^2)

    advance(dt = 0.01):
      for i, for j > i:
        dx = x_i - x_j; dy = ...; dz = ...
        d2 = dx*dx + dy*dy + dz*dz
        mag = dt / (d2 * sqrt(d2))
        v_i -= (dx, dy, dz) * m_j * mag
        v_j += (dx, dy, dz) * m_i * mag
      for i: x_i += dt * vx_i (likewise y, z)

Print the energy with 9 decimals, run advance N times, print it again.
Check: N=1000 prints `-0.169075164` and `-0.169087605`.

## spectralnorm

    A(i, j) = 1.0 / ((i + j) * (i + j + 1) / 2 + i + 1)     # integer division by 2, 0-based i, j
    Av(v)[i]  = sum over j of A(i, j) * v[j]
    Atv(v)[i] = sum over j of A(j, i) * v[j]
    AtAv(v)   = Atv(Av(v))

    u = [1.0] * N
    repeat 10 times: v = AtAv(u); u = AtAv(v)
    vBv = sum u[i] * v[i]; vv = sum v[i] * v[i]
    print sqrt(vBv / vv) with 9 decimals

Check: N=100 prints `1.274219991`.

## mandelbrot

Writes a binary PBM image of the Mandelbrot set, N by N pixels.

    print "P4\n{N} {N}\n" (bytes, no trailing newline after the pixels)
    for y in 0 .. N-1, for x in 0 .. N-1:
        cr = 2.0 * x / N - 1.5; ci = 2.0 * y / N - 1.0
        zr = zi = tr = ti = 0.0
        repeat 50 times, stopping early once tr + ti > 4.0:
            zi = 2.0 * zr * zi + ci
            zr = tr - ti + cr
            tr = zr * zr; ti = zi * zi
        the pixel is 1 if tr + ti <= 4.0, else 0

Pixels pack 8 to a byte, most significant bit first. Each row is padded with
0 bits to a whole byte (when N is not a multiple of 8). `2.0 * x / N` means
(2.0 * x) / N in floating point.

## fasta

Writes three sequences in FASTA format, 60 characters a line (the last line
of a sequence may be shorter, and is not empty).

    print ">ONE Homo sapiens alu";      repeat ALU, 2*N characters
    print ">TWO IUB ambiguity codes";   random from IUB, 3*N characters
    print ">THREE Homo sapiens frequency"; random from HOMOSAPIENS, 5*N characters

`repeat` writes ALU cyclically: character k is ALU[k mod len(ALU)], with k
counting from 0 for the first sequence.

    ALU = "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGACCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAATACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCAGCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGGAGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCCAGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA"

(287 characters.) `random` uses one generator shared by both random sequences,
state seed starting at 42:

    IM = 139968; IA = 3877; IC = 29573
    next() = seed = (seed * IA + IC) mod IM; return seed / IM    # as a 64-bit float in [0, 1)

Each character: r = next(); pick the first entry whose cumulative probability
is greater than r. Cumulative probabilities are running sums, in table order,
of the probabilities below, summed in 64-bit floats. If rounding leaves r at or
above the last cumulative value, pick the last entry.

    IUB:  a 0.27  c 0.12  g 0.12  t 0.27
          B 0.02  D 0.02  H 0.02  K 0.02  M 0.02  N 0.02  R 0.02  S 0.02  V 0.02  W 0.02  Y 0.02
    HOMOSAPIENS:  a 0.3029549426680  c 0.1979883004921  g 0.1975473066391  t 0.3015094502008

Check: `fasta 1000` prints `>ONE` and 34 lines (2000 = 33*60 + 20), `>TWO` and
50 lines, `>THREE` and 84 lines (5000 = 83*60 + 20). The first line after
`>TWO` should be `cttBtatcatatgctaKggNcataaaSatgtaaaDcDRtBggDtctttataattcBgtcg`
(from the Benchmarks Game reference output; if every language agrees on
something else, report it rather than forcing it).

## knucleotide

Reads a fasta output file. Take the third sequence: the lines after the line
that starts with `>THREE` up to the end of the file (or the next `>` line),
newlines removed, converted to upper case.

Count every overlapping substring of length k (k-mers) with a hash table.

1. For k = 1 then k = 2: all k-mers that occur, sorted by count descending,
   ties by k-mer ascending; print `{kmer} {percent}` with percent =
   100 * count / (total k-mers of that length), 3 decimals. Print an empty
   line after each of the two blocks.
2. For each of `GGT`, `GGTA`, `GGTATT`, `GGTATTTTAATT`, `GGTATTTTAATTTATAGT`,
   in that order: print `{count}\t{kmer}` (count of that k-mer, 0 if absent).

The total number of k-mers of length k in a sequence of length L is L - k + 1.
Each length counts its own k-mers in its own pass (build the table for length
k, then query it); do not derive one length from another.

## revcomp

Reads a fasta output file. For each sequence in order: print its header line
unchanged, then the reverse complement of its sequence (newlines removed),
written 60 characters a line (last line shorter, never empty).

Complement, applied to each character (lower case maps to the upper case
complement; other characters do not occur):

    A->T  C->G  G->C  T->A  U->A  M->K  R->Y  W->W  S->S  Y->R  K->M
    V->B  H->D  D->H  B->V  N->N
