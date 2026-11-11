// records: three-key sort and group-by (SPEC.md)
package main

import (
	"bufio"
	"fmt"
	"os"
	"sort"
)

const (
	N = 1000000
	M = 1000000007
)

type record struct {
	id, dept, age, salary int64
}

func lcg(x int64) int64 { return (x*1103515245 + 12345) % 2147483648 }

func main() {
	rs := make([]record, N)
	x := int64(42)
	for id := int64(0); id < N; id++ {
		x = lcg(x)
		rs[id] = record{id, x % 100, 18 + (x/100)%63, 30000 + (x/6300)%90000}
	}
	sort.Slice(rs, func(i, j int) bool {
		a, b := &rs[i], &rs[j]
		if a.dept != b.dept {
			return a.dept < b.dept
		}
		if a.age != b.age {
			return a.age > b.age
		}
		return a.id < b.id
	})
	var o int64
	for i := range rs {
		o = (o*31 + rs[i].id) % M
	}
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	fmt.Fprintf(w, "records %d order %d\n", N, o)
	for i := 0; i < len(rs); {
		dept, first := rs[i].dept, rs[i].id
		var count, sum int64
		for i < len(rs) && rs[i].dept == dept {
			count++
			sum += rs[i].salary
			i++
		}
		fmt.Fprintf(w, "%d %d %d %d\n", dept, count, sum, first)
	}
}
