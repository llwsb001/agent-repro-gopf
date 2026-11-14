package main

import (
	"bufio"
	"flag"
	"fmt"
	"net"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:1248", "proxy address")
	conns := flag.Int("conns", 100, "concurrent connections")
	reqs := flag.Int("reqs", 10000, "total requests")
	path := flag.String("path", "/", "request path")
	flag.Parse()

	var done int64
	var mu sync.Mutex
	lats := make([]time.Duration, 0, *reqs)
	var wg sync.WaitGroup
	start := time.Now()
	per := *reqs / *conns
	for i := 0; i < *conns; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				n := atomic.AddInt64(&done, 1)
				if int(n) > *reqs {
					return
				}
				t0 := time.Now()
				c, err := net.DialTimeout("tcp", *addr, 3*time.Second)
				if err != nil {
					continue
				}
				fmt.Fprintf(c, "GET %s HTTP/1.1\r\nHost: bench\r\nConnection: close\r\n\r\n", *path)
				br := bufio.NewReaderSize(c, 4096)
				for {
					if _, err := br.ReadByte(); err != nil {
						break
					}
				}
				c.Close()
				d := time.Since(t0)
				mu.Lock()
				lats = append(lats, d)
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	el := time.Since(start)
	_ = per
	sort.Slice(lats, func(i, j int) bool { return lats[i] < lats[j] })
	var sum time.Duration
	for _, d := range lats {
		sum += d
	}
	p := func(q float64) time.Duration {
		if len(lats) == 0 { return 0 }
		i := int(float64(len(lats)-1) * q)
		return lats[i]
	}
	fmt.Printf("reqs=%d conns=%d elapsed=%.2fs rps=%.0f mean=%.2fms p50=%.2fms p99=%.2fms\n",
		len(lats), *conns, el.Seconds(), float64(len(lats))/el.Seconds(),
		float64(sum.Microseconds())/float64(len(lats))/1000,
		float64(p(0.5).Microseconds())/1000, float64(p(0.99).Microseconds())/1000)
}
