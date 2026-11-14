package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
)

type Node struct{ left, right *Node }

func make_(d int) *Node {
	if d == 0 {
		return &Node{}
	}
	return &Node{make_(d - 1), make_(d - 1)}
}

func (n *Node) check() int {
	if n == nil {
		return 0
	}
	return 1 + n.left.check() + n.right.check()
}

func main() {
	n := 18
	if len(os.Args) > 1 {
		n, _ = strconv.Atoi(os.Args[1])
	}
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()
	minDepth := 4
	maxDepth := n
	if minDepth+2 > maxDepth {
		maxDepth = minDepth + 2
	}
	stretch := maxDepth + 1
	fmt.Fprintf(out, "stretch tree of depth %d\t check: %d\n", stretch, make_(stretch).check())
	long := make_(maxDepth)
	for d := minDepth; d <= maxDepth; d += 2 {
		iters := 1 << uint(maxDepth-d+minDepth)
		sum := 0
		for i := 0; i < iters; i++ {
			sum += make_(d).check()
		}
		fmt.Fprintf(out, "%d\t trees of depth %d\t check: %d\n", iters, d, sum)
	}
	fmt.Fprintf(out, "long lived tree of depth %d\t check: %d\n", maxDepth, long.check())
}
