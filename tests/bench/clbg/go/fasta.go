package main

import (
	"bufio"
	"os"
	"strconv"
)

const alu = "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGACCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAATACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCAGCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGGAGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCCAGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA"

const lineWidth = 60

type acid struct {
	c byte
	p float64
}

var iub = []acid{
	{'a', 0.27}, {'c', 0.12}, {'g', 0.12}, {'t', 0.27},
	{'B', 0.02}, {'D', 0.02}, {'H', 0.02}, {'K', 0.02}, {'M', 0.02}, {'N', 0.02},
	{'R', 0.02}, {'S', 0.02}, {'V', 0.02}, {'W', 0.02}, {'Y', 0.02},
}

var homosapiens = []acid{
	{'a', 0.3029549426680}, {'c', 0.1979883004921}, {'g', 0.1975473066391}, {'t', 0.3015094502008},
}

const (
	im = 139968
	ia = 3877
	ic = 29573
)

var seed = 42

func random() float64 {
	seed = (seed*ia + ic) % im
	return float64(seed) / im
}

func repeatFasta(out *bufio.Writer, header string, n int) {
	out.WriteString(header)
	line := make([]byte, lineWidth+1)
	k := 0
	for n > 0 {
		m := lineWidth
		if n < m {
			m = n
		}
		for i := 0; i < m; i++ {
			line[i] = alu[k]
			k++
			if k == len(alu) {
				k = 0
			}
		}
		line[m] = '\n'
		out.Write(line[:m+1])
		n -= m
	}
}

func randomFasta(out *bufio.Writer, header string, table []acid, n int) {
	out.WriteString(header)
	cum := make([]float64, len(table))
	sum := 0.0
	for i, a := range table {
		sum += a.p
		cum[i] = sum
	}
	last := len(table) - 1
	line := make([]byte, lineWidth+1)
	for n > 0 {
		m := lineWidth
		if n < m {
			m = n
		}
		for i := 0; i < m; i++ {
			r := random()
			j := 0
			for j < last && cum[j] <= r {
				j++
			}
			line[i] = table[j].c
		}
		line[m] = '\n'
		out.Write(line[:m+1])
		n -= m
	}
}

func main() {
	n := 2500000
	if len(os.Args) > 1 {
		n, _ = strconv.Atoi(os.Args[1])
	}
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()
	repeatFasta(out, ">ONE Homo sapiens alu\n", 2*n)
	randomFasta(out, ">TWO IUB ambiguity codes\n", iub, 3*n)
	randomFasta(out, ">THREE Homo sapiens frequency\n", homosapiens, 5*n)
}
