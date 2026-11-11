// sim: particle simulation (SPEC.md)
package main

import "fmt"

const (
	NP    = 20000
	STEPS = 2000
)

type particle struct {
	px, py, vx, vy int64
}

func lcg(x int64) int64 { return (x*1103515245 + 12345) % 2147483648 }

func main() {
	ps := make([]particle, NP)
	x := int64(1)
	for i := range ps {
		x = lcg(x)
		ps[i].px = x % 1000000
		x = lcg(x)
		ps[i].py = x % 1000000
		x = lcg(x)
		ps[i].vx = x%2001 - 1000
		x = lcg(x)
		ps[i].vy = x%2001 - 1000
	}
	for s := 0; s < STEPS; s++ {
		for i := range ps {
			p := &ps[i]
			p.vy--
			p.px += p.vx
			if p.px < 0 {
				p.px = -p.px
				p.vx = -p.vx
			} else if p.px > 1000000 {
				p.px = 2000000 - p.px
				p.vx = -p.vx
			}
			p.py += p.vy
			if p.py < 0 {
				p.py = -p.py
				p.vy = -p.vy
			} else if p.py > 1000000 {
				p.py = 2000000 - p.py
				p.vy = -p.vy
			}
		}
	}
	var sx, sy, e int64
	for i := range ps {
		sx += ps[i].px
		sy += ps[i].py
		e += ps[i].vx*ps[i].vx + ps[i].vy*ps[i].vy
	}
	fmt.Printf("particles %d steps %d sx %d sy %d energy %d\n", NP, STEPS, sx, sy, e)
}
