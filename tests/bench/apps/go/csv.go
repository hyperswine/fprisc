// csv: parse and aggregate (SPEC.md)
package main

import (
	"bufio"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
)

type agg struct {
	count, sumA, maxB int64
}

func main() {
	path := "data/sales.csv"
	if len(os.Args) > 1 {
		path = os.Args[1]
	}
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	text := string(data)
	m := make(map[string]*agg)
	var lines int64
	for _, line := range strings.Split(text, "\n") {
		if line == "" {
			continue
		}
		fields := strings.Split(line, ",")
		a, _ := strconv.ParseInt(fields[1], 10, 64)
		b, _ := strconv.ParseInt(fields[2], 10, 64)
		e, ok := m[fields[0]]
		if !ok {
			e = &agg{}
			m[fields[0]] = e
		}
		e.count++
		e.sumA += a
		if b > e.maxB {
			e.maxB = b
		}
		lines++
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		a, b := m[keys[i]], m[keys[j]]
		if a.sumA != b.sumA {
			return a.sumA > b.sumA
		}
		return keys[i] < keys[j]
	})
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	fmt.Fprintf(w, "keys %d lines %d\n", len(keys), lines)
	for i := 0; i < len(keys) && i < 10; i++ {
		e := m[keys[i]]
		fmt.Fprintf(w, "%s %d %d %d\n", keys[i], e.count, e.sumA, e.maxB)
	}
}
