//go:build windows

package main

import (
	"syscall"
	"unsafe"
)

// On Windows Go's monotonic clock moved too coarsely for the hold: read
// from time.Since, a 20 us hold took 1.84 ms an update, the floor's median
// of 5 (Windows 11, 12 logical processors, the user's machine). Read from
// QueryPerformanceCounter through syscall, each read cost enough that the
// floor grew with the goroutines reading it, 448 ns at one pair and 20,858
// at twelve. So the hold is a spin of holdTurns turns, measured once
// against QueryPerformanceCounter, and reads no clock.
var (
	holdTurns int64
	sink      uint64
)

func init() {
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	qpc := kernel32.NewProc("QueryPerformanceCounter")
	var hz, began, ended int64
	kernel32.NewProc("QueryPerformanceFrequency").Call(uintptr(unsafe.Pointer(&hz)))
	const turns = 20000000
	qpc.Call(uintptr(unsafe.Pointer(&began)))
	spin(turns)
	qpc.Call(uintptr(unsafe.Pointer(&ended)))
	holdTurns = turns * holdNS / ((ended - began) * 1000000000 / hz)
}

func spin(turns int64) {
	x := sink
	for i := int64(0); i < turns; i++ {
		x = x*6364136223846793005 + 1442695040888963407
	}
	sink = x
}

// hold spins holdTurns turns, holdNS by the measure taken at start.
func hold() {
	spin(holdTurns)
}
