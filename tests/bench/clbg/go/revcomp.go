package main

import (
	"bufio"
	"fmt"
	"os"
)

var comp [256]byte

func init() {
	pairs := "ATCGGCTAUAMKRYWWSSYRKMVBHDDHBVNN"
	for i := range comp {
		comp[i] = byte(i)
	}
	for i := 0; i < len(pairs); i += 2 {
		comp[pairs[i]] = pairs[i+1]
		comp[pairs[i]+'a'-'A'] = pairs[i+1]
	}
}

func flush(out *bufio.Writer, header []byte, seq []byte) {
	out.Write(header)
	out.WriteByte('\n')
	for i, j := 0, len(seq)-1; i < j; i, j = i+1, j-1 {
		seq[i], seq[j] = comp[seq[j]], comp[seq[i]]
	}
	if len(seq)%2 == 1 {
		m := len(seq) / 2
		seq[m] = comp[seq[m]]
	}
	for i := 0; i < len(seq); i += 60 {
		e := i + 60
		if e > len(seq) {
			e = len(seq)
		}
		out.Write(seq[i:e])
		out.WriteByte('\n')
	}
}

func main() {
	path := "data/fasta-2500000.txt"
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
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()
	var header []byte
	var seq []byte
	have := false
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) > 0 && line[0] == '>' {
			if have {
				flush(out, header, seq)
			}
			header = append(header[:0], line...)
			seq = seq[:0]
			have = true
			continue
		}
		seq = append(seq, line...)
	}
	if have {
		flush(out, header, seq)
	}
}
