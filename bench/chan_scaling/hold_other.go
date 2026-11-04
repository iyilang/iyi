//go:build !windows

package main

import "time"

// hold looks at Go's monotonic clock until holdNS has passed.
func hold() {
	began := time.Now()
	for time.Since(began) < holdNS*time.Nanosecond {
	}
}
