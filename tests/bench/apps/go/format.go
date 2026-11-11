// format: string building (SPEC.md)
package main

import "fmt"

const (
	N = 1000000
	M = 1000000007
)

func main() {
	status := [3]string{"open", "paid", "shipped"}
	lines := make([]string, 0, N)
	for i := int64(0); i < N; i++ {
		c := (i * 7919) % 10007
		q := i%17 + 1
		cents := (i * 104729) % 1000000
		lines = append(lines, fmt.Sprintf("order %d cust c%d qty %d total %d.%02d status %s",
			i, c, q, cents/100, cents%100, status[i%3]))
	}
	var bytes, h int64
	for _, l := range lines {
		n := int64(len(l))
		bytes += n
		h = (h*31 + n) % M
	}
	fmt.Printf("lines %d bytes %d hash %d\n", N, bytes, h)
	fmt.Println(lines[0])
	fmt.Println(lines[499999])
	fmt.Println(lines[999999])
}
