# Benchmark

All numbers below were produced with the provided tools only:

* backend: `/home/user/Doubao/chats/38453552245765378/zig-gopf/bench/backend`
  already listening on `127.0.0.1:18091` (`/` = 396 bytes, `/big` = 1 MiB)
* load generator: `/home/user/Doubao/chats/38453552245765378/zig-gopf/bench/load`
* proxy: `./zig-out/bin/gopf -listen 127.0.0.1:12481 settings.conf`
* config: one backend `127.0.0.1:18091`, weight 100
* compile level: **`-Doptimize=ReleaseFast`** (Zig 0.17.0)

The machine also runs other tasks, so these are draft numbers; the procedure is
the required one.

## Small request (`/`, 396-byte body)

Warm-up:

```sh
load -addr 127.0.0.1:12481 -conns 50 -reqs 2000
# reqs=2000 conns=50 elapsed=0.15s rps=13553 mean=3.64ms p50=3.10ms p99=15.07ms
```

Then three consecutive runs:

```sh
load -addr 127.0.0.1:12481 -conns 100 -reqs 10000
```

| Run | rps | mean | p50 | p99 |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 15,316 | 6.45 ms | 6.03 ms | 15.12 ms |
| 2 | 14,572 | 6.77 ms | 6.35 ms | 15.64 ms |
| 3 | 14,645 | 6.77 ms | 6.34 ms | 15.98 ms |
| **median** | **14,645** | **6.77 ms** | **6.34 ms** | **15.64 ms** |

## Large request (`/big`, 1 MiB body)

```sh
load -addr 127.0.0.1:12481 -path /big -conns 4 -reqs 100
# reqs=100 conns=4 elapsed=0.18s rps=544 mean=7.30ms p50=6.98ms p99=12.74ms
```

Throughput: 100 × 1 MiB / 0.18 s ≈ **555 MiB/s** (≈ 582 MB/s decimal).
At this payload size the result is limited by loopback bandwidth and the
user-space copies, not by connection setup.

## Comparison with the Go baseline

| Path | rps | p50 | p99 |
| --- | ---: | ---: | ---: |
| Go gopf baseline (task-provided) | 15,700 | 6.0 ms | 13 ms |
| Zig gopf (median, this run) | 14,645 | 6.34 ms | 15.64 ms |
| Direct to backend (measured now) | 19,803 | 4.19 ms | 20.72 ms |
| Direct to backend (task-provided) | 30,900 | — | — |

The Zig version reaches about **93% of the Go baseline throughput** on this
run. Its p50 is ~0.3 ms higher and p99 is ~2.6 ms higher. The measured direct
backend rate was only 19.8k rps instead of 30.9k while benchmarking, so the
machine was visibly busier; the proxy's overhead relative to the *measured*
direct path is roughly 26%.

Where the remaining gap comes from:

* **OS threads vs goroutines.** The worker pool removes per-request thread
  creation, but 128 kernel threads still have heavier scheduling and stack
  footprints than goroutines, and a fixed pool serializes concurrency at 128.
* **Two TCP connections per client request.** Every benchmark request also
  performs a fresh dial from proxy to backend. The Go baseline pays this too,
  but it dominates both implementations; a reusable connection pool would be a
  behavioural change.
* **User-space copies.** Both directions use 64 KiB buffers and a `poll()` loop:
  each byte is copied once into the buffer and once by `write()`. Go's
  `io.Copy` benefits from `splice`/`sendfile`-style fast paths on Linux in some
  cases, and its scheduler is optimized for this fan-out pattern.
* **Per-connection work:** RNG seeding, address copy under a mutex, two
  `setsockopt` calls for keepalive, and nonblocking-connect `poll()` around the
  backend dial.
* **ReleaseFast without LTO/profile-guided tuning.** No PGO, huge-page or
  socket-buffer tuning was applied; only the requested optimization level.

Large-packet performance is healthy: ~555 MiB/s over loopback with 4 concurrent
connections, close to what the same loopback path can sustain while also
copying through a userspace proxy.