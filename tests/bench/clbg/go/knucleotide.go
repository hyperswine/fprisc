package main

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"sort"
)

func count(seq []byte, k int) map[string]int {
	m := make(map[string]int)
	for i := 0; i+k <= len(seq); i++ {
		m[string(seq[i:i+k])]++
	}
	return m
}

type entry struct {
	kmer string
	n    int
}

func main() {
	path := "data/fasta-1000000.txt"
	if len(os.Args) > 1 {
		path = os.Args[1]
	}
	f, err := os.Open(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<16), 1<<20)
	var seq []byte
	in := false
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) > 0 && line[0] == '>' {
			if in {
				break
			}
			in = bytes.HasPrefix(line, []byte(">THREE"))
			continue
		}
		if in {
			seq = append(seq, line...)
		}
	}
	seq = bytes.ToUpper(seq)

	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()
	for k := 1; k <= 2; k++ {
		m := count(seq, k)
		es := make([]entry, 0, len(m))
		for s, n := range m {
			es = append(es, entry{s, n})
		}
		sort.Slice(es, func(i, j int) bool {
			if es[i].n != es[j].n {
				return es[i].n > es[j].n
			}
			return es[i].kmer < es[j].kmer
		})
		total := float64(len(seq) - k + 1)
		for _, e := range es {
			fmt.Fprintf(out, "%s %.3f\n", e.kmer, 100*float64(e.n)/total)
		}
		out.WriteString("\n")
	}
	for _, q := range []string{"GGT", "GGTA", "GGTATT", "GGTATTTTAATT", "GGTATTTTAATTTATAGT"} {
		m := count(seq, len(q))
		fmt.Fprintf(out, "%d\t%s\n", m[q], q)
	}
}
