package main

import (
	"bufio"
	"fmt"
	"math"
	"os"
	"strconv"
)

func a(i, j int) float64 { return 1.0 / float64((i+j)*(i+j+1)/2+i+1) }

func av(v, out []float64) {
	for i := range out {
		s := 0.0
		for j := range v {
			s += a(i, j) * v[j]
		}
		out[i] = s
	}
}

func atv(v, out []float64) {
	for i := range out {
		s := 0.0
		for j := range v {
			s += a(j, i) * v[j]
		}
		out[i] = s
	}
}

func atav(v, out, tmp []float64) {
	av(v, tmp)
	atv(tmp, out)
}

func main() {
	n := 2000
	if len(os.Args) > 1 {
		n, _ = strconv.Atoi(os.Args[1])
	}
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()
	u := make([]float64, n)
	v := make([]float64, n)
	tmp := make([]float64, n)
	for i := range u {
		u[i] = 1.0
	}
	for i := 0; i < 10; i++ {
		atav(u, v, tmp)
		atav(v, u, tmp)
	}
	var vBv, vv float64
	for i := range u {
		vBv += u[i] * v[i]
		vv += v[i] * v[i]
	}
	fmt.Fprintf(out, "%.9f\n", math.Sqrt(vBv/vv))
}
