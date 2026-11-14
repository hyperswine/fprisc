package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
)

func main() {
	n := 4000
	if len(os.Args) > 1 {
		n, _ = strconv.Atoi(os.Args[1])
	}
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()
	fmt.Fprintf(out, "P4\n%d %d\n", n, n)
	fn := float64(n)
	for y := 0; y < n; y++ {
		ci := 2.0*float64(y)/fn - 1.0
		var bits byte
		bitNum := 0
		for x := 0; x < n; x++ {
			cr := 2.0*float64(x)/fn - 1.5
			var zr, zi, tr, ti float64
			for i := 0; i < 50 && tr+ti <= 4.0; i++ {
				zi = 2.0*zr*zi + ci
				zr = tr - ti + cr
				tr = zr * zr
				ti = zi * zi
			}
			bits <<= 1
			if tr+ti <= 4.0 {
				bits |= 1
			}
			bitNum++
			if bitNum == 8 {
				out.WriteByte(bits)
				bits, bitNum = 0, 0
			}
		}
		if bitNum > 0 {
			out.WriteByte(bits << uint(8-bitNum))
		}
	}
}
