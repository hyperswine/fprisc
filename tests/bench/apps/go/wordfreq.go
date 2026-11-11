// wordfreq: word counts, top 10 (SPEC.md)
package main

import (
	"bufio"
	"fmt"
	"os"
	"sort"
	"strings"
)

type entry struct {
	word  string
	count int64
}

func main() {
	path := "data/corpus.txt"
	if len(os.Args) > 1 {
		path = os.Args[1]
	}
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	counts := make(map[string]int64)
	var total int64
	for _, w := range strings.Fields(string(data)) {
		counts[w]++
		total++
	}
	es := make([]entry, 0, len(counts))
	for w, c := range counts {
		es = append(es, entry{w, c})
	}
	sort.Slice(es, func(i, j int) bool {
		if es[i].count != es[j].count {
			return es[i].count > es[j].count
		}
		return es[i].word < es[j].word
	})
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()
	fmt.Fprintf(out, "distinct %d total %d\n", len(es), total)
	for i := 0; i < len(es) && i < 10; i++ {
		fmt.Fprintf(out, "%s %d\n", es[i].word, es[i].count)
	}
}
