'use strict';
// Benchmarks Game binary-trees, single-threaded (see ../SPEC.md).

class Node {
  constructor(left, right) {
    this.left = left;
    this.right = right;
  }
}

function make(d) {
  return d === 0 ? new Node(null, null) : new Node(make(d - 1), make(d - 1));
}

function check(t) {
  return t === null ? 0 : 1 + check(t.left) + check(t.right);
}

function main() {
  const n = process.argv.length > 2 ? parseInt(process.argv[2], 10) : 18;
  const minDepth = 4;
  const maxDepth = Math.max(minDepth + 2, n);
  const stretch = maxDepth + 1;
  const out = [];
  out.push(`stretch tree of depth ${stretch}\t check: ${check(make(stretch))}`);
  const long = make(maxDepth);
  for (let d = minDepth; d <= maxDepth; d += 2) {
    const iters = 2 ** (maxDepth - d + minDepth);
    let sum = 0;
    for (let i = 0; i < iters; i++) sum += check(make(d));
    out.push(`${iters}\t trees of depth ${d}\t check: ${sum}`);
  }
  out.push(`long lived tree of depth ${maxDepth}\t check: ${check(long)}`);
  process.stdout.write(out.join('\n') + '\n');
}

main();
