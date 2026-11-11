// treemap: map inserts and lookups (SPEC.md); Go has no ordered map, so the
// built-in map plus a sort of the keys for the key hash.
package main

import (
	"fmt"
	"sort"
)

const M = 1000000007

func lcg(x int64) int64 { return (x*1103515245 + 12345) % 2147483648 }

func main() {
	m := make(map[int64]int64)
	x := int64(7)
	for i := int64(0); i < 500000; i++ {
		x = lcg(x)
		m[x%1000000] = i
	}
	var hits, sum int64
	for i := 0; i < 500000; i++ {
		x = lcg(x)
		if v, ok := m[x%1000000]; ok {
			hits++
			sum += v
		}
	}
	keys := make([]int64, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })
	var k int64
	for _, key := range keys {
		k = (k*31 + key) % M
	}
	fmt.Printf("size %d hits %d sum %d keyhash %d\n", len(m), hits, sum, k)
}
