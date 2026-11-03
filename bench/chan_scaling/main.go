// The Go twin of bench/chan_scaling.iyi's pingpong and fanin shapes, at
// GOMAXPROCS = W: W pairs ping-ponging on two unbuffered channels each, and
// W producers sending into one channel of 128 that one goroutine drains,
// every answer checked as the iyi program checks it.
//
//	go build -o chan_scaling_go . && ./chan_scaling_go W ROUNDS
package main

import (
	"fmt"
	"os"
	"runtime"
	"strconv"
	"sync"
	"time"
)

func pingpong(w int, rounds int64) int64 {
	var wg sync.WaitGroup
	for range w {
		there, back := make(chan int64), make(chan int64)
		wg.Add(2)
		go func() {
			defer wg.Done()
			for r := range rounds {
				there <- r
				if <-back != r+1 {
					panic("pingpong: a round trip answered wrong")
				}
			}
		}()
		go func() {
			defer wg.Done()
			for range rounds {
				back <- (<-there) + 1
			}
		}()
	}
	wg.Wait()
	return int64(w) * rounds * 2
}

func fanin(w int, rounds int64) int64 {
	fan := make(chan int64, 128)
	done := make(chan int64)
	go func() {
		expected := make([]int64, w)
		total := int64(w) * rounds
		for range total {
			v := <-fan
			who := v >> 32
			if v&0xFFFFFFFF != expected[who] {
				panic("fanin: a value out of its producer's order")
			}
			expected[who]++
		}
		done <- total
	}()
	for p := range w {
		go func(who int64) {
			for i := range rounds {
				fan <- who<<32 | i
			}
		}(int64(p))
	}
	return <-done
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: chan_scaling_go WORKERS ROUNDS")
		os.Exit(1)
	}
	w, _ := strconv.Atoi(os.Args[1])
	rounds, _ := strconv.ParseInt(os.Args[2], 10, 64)
	runtime.GOMAXPROCS(w)
	for _, shape := range []string{"pingpong", "fanin"} {
		start := time.Now()
		var ops int64
		if shape == "pingpong" {
			ops = pingpong(w, rounds)
		} else {
			ops = fanin(w, rounds)
		}
		us := max(time.Since(start).Microseconds(), 1)
		fmt.Printf("shape=%s workers=%d rounds=%d ops=%d wall_us=%d ops_per_s=%d\n", shape, w, rounds, ops, us, ops*1000000/us)
	}
}
