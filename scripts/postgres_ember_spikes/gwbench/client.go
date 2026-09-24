// Load generator. Opens N concurrent TLS connections through the gateway and
// either measures per-request latency (small responses) or aggregate
// throughput (large responses).
package main

import (
	"crypto/tls"
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:7443", "gateway address")
	conns := flag.Int("conns", 50, "concurrent connections")
	respSize := flag.Int("size", 64, "response bytes per request")
	duration := flag.Duration("duration", 10*time.Second, "test duration")
	mode := flag.String("mode", "latency", "latency | throughput | idle")
	flag.Parse()

	if *mode == "idle" {
		holdIdle(*addr, *conns)
		return
	}

	var totalBytes int64
	var mu sync.Mutex
	var samples []float64
	deadline := time.Now().Add(*duration)
	var wg sync.WaitGroup
	var failed int64

	for i := 0; i < *conns; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c, err := tls.Dial("tcp", *addr, &tls.Config{InsecureSkipVerify: true})
			if err != nil {
				atomic.AddInt64(&failed, 1)
				return
			}
			defer c.Close()
			var hdr [4]byte
			binary.BigEndian.PutUint32(hdr[:], uint32(*respSize))
			buf := make([]byte, 65536)
			local := []float64{}
			for time.Now().Before(deadline) {
				t0 := time.Now()
				if _, err := c.Write(hdr[:]); err != nil {
					atomic.AddInt64(&failed, 1)
					return
				}
				remaining := *respSize
				for remaining > 0 {
					n := len(buf)
					if remaining < n {
						n = remaining
					}
					r, err := io.ReadFull(c, buf[:n])
					if err != nil {
						atomic.AddInt64(&failed, 1)
						return
					}
					remaining -= r
					atomic.AddInt64(&totalBytes, int64(r))
				}
				local = append(local, float64(time.Since(t0).Microseconds())/1000.0)
			}
			mu.Lock()
			samples = append(samples, local...)
			mu.Unlock()
		}()
	}
	wg.Wait()

	sort.Float64s(samples)
	p := func(q float64) float64 {
		if len(samples) == 0 {
			return 0
		}
		return samples[int(float64(len(samples)-1)*q)]
	}
	mb := float64(totalBytes) / 1024 / 1024 / duration.Seconds()
	fmt.Printf("{\"mode\":\"%s\",\"conns\":%d,\"size\":%d,\"requests\":%d,\"failed\":%d,"+
		"\"p50_ms\":%.3f,\"p90_ms\":%.3f,\"p99_ms\":%.3f,\"mb_per_s\":%.1f,\"req_per_s\":%.0f}\n",
		*mode, *conns, *respSize, len(samples), failed, p(0.50), p(0.90), p(0.99), mb,
		float64(len(samples))/duration.Seconds())
}

// Hold N connections open and idle, so the gateway's memory per connection can
// be read from the outside.
func holdIdle(addr string, conns int) {
	held := []*tls.Conn{}
	for i := 0; i < conns; i++ {
		c, err := tls.Dial("tcp", addr, &tls.Config{InsecureSkipVerify: true})
		if err != nil {
			fmt.Fprintf(os.Stderr, "failed at %d: %v\n", i, err)
			break
		}
		held = append(held, c)
	}
	fmt.Printf("{\"held\":%d}\n", len(held))
	time.Sleep(60 * time.Second)
	for _, c := range held {
		c.Close()
	}
}
