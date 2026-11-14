package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
)

func main() {
	n := 10
	if len(os.Args) > 1 {
		n, _ = strconv.Atoi(os.Args[1])
	}
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()
	perm1 := make([]int, n)
	for i := range perm1 {
		perm1[i] = i
	}
	perm := make([]int, n)
	count := make([]int, n)
	maxFlips, checksum, permIndex, r := 0, 0, 0, n
	for {
		for r != 1 {
			count[r-1] = r
			r--
		}
		copy(perm, perm1)
		flips := 0
		for k := perm[0]; k != 0; k = perm[0] {
			for i, j := 0, k; i < j; i, j = i+1, j-1 {
				perm[i], perm[j] = perm[j], perm[i]
			}
			flips++
		}
		if flips > maxFlips {
			maxFlips = flips
		}
		if permIndex%2 == 0 {
			checksum += flips
		} else {
			checksum -= flips
		}
		for {
			if r == n {
				fmt.Fprintf(out, "%d\nPfannkuchen(%d) = %d\n", checksum, n, maxFlips)
				return
			}
			p0 := perm1[0]
			for i := 0; i < r; i++ {
				perm1[i] = perm1[i+1]
			}
			perm1[r] = p0
			count[r]--
			if count[r] > 0 {
				break
			}
			r++
		}
		permIndex++
	}
}
