# Implementation notes

## Build / run

```
zig build                 # produces zig-out/bin/gopf
zig build test            # runs unit tests
zig build -Doptimize=ReleaseFast   # optimized build (used for benchmarks)
zig-out/bin/gopf [-listen ADDR] config_file
zig-out/bin/gopf -h       # prints usage to stderr, exit 0
zig-out/bin/gopf          # missing config: usage, exit 1
python3 verify/acceptance.py zig-out/bin/gopf   # external acceptance suite
zig-out/bin/gopf --selftest  # offline check: forwarding over a Unix socketpair
```

## Design choices

- **Structure**: `src/config.zig` (JSON parse + validation + weighted choice),
  `src/log.zig` (Go-style timestamped stderr log), `src/main.zig` (CLI,
  signals, accept loop, forwarding). Mirrors the Go file layout.
- **Entry**: `pub fn main(init: std.process.Init) !void`, using `init.io`
  (`std.Io.Threaded`), `init.gpa`, and `init.minimal.args`.
- **Concurrency**: one `Io.concurrent` task per accepted connection, plus one
  for the accept loop so the main task can `sigwait`. Each connection runs two
  copy directions in an `Io.Group` and awaits both, exactly like Go's
  `WaitGroup`.
- **Backend dial timeout**: `std.Io.Threaded.netConnectIpPosix` panics on
  `options.timeout != .none` ("TODO implement ..."), so the 5 s timeout is
  implemented manually in `connectWithTimeout`: create a nonblocking
  `SOCK.STREAM` socket, `connect(2)` (treat `EINPROGRESS`/`EAGAIN` as
  pending), `poll(POLL.OUT, 5000)`, check `SO_ERROR`, then `fcntl` back to
  blocking before handing the fd to the `Io` reader/writer (their POSIX
  implementation treats `EAGAIN` as a programmer bug, so blocking mode is
  mandatory). Errnos are mapped to `ConnectionRefused` / `Timeout` /
  `HostUnreachable` / `NetworkUnreachable` / `AccessDenied` etc., mirroring
  `net.IpAddress.ConnectError`.
- **Socket ownership**: each fd has exactly one owner that closes it.
  `handleConn` delegates the client stream to `forwardWithBackend`, which
  closes it; the backend stream is closed in the same function.
- **Config storage**: global `options.backend` protected by `std.Io.Mutex`
  (Go: `sync.RWMutex`). Each config generation lives in its own
  `ArenaAllocator`; on reload the arena is swapped atomically and the old one
  is *retired*, not freed: connections started under the old config may still
  reference its strings, so retired arenas stay alive until process exit
  (tiny memory cost, bounded by the number of `SIGHUP`s).
- **Random selection**: `std.Random.DefaultPrng` seeded from
  `std.Io.random`; `intRangeLessThan(0, weight_sum)` matches Go's `rand.Intn`.
  Both the RNG state and the backend are guarded by the same mutex, mirroring
  Go where `rand.Intn` uses the locked global source.
- **Logging**: `YYYY/MM/DD HH:MM:SS` prefix computed from
  `Io.Clock.real.now(io)` via `std.time.epoch`; all log lines go through a
  single locked `Io.Writer` to stderr.
- **Signals**: `sigprocmask` blocks `HUP/USR1/TERM/INT` process-wide before
  the accept loop starts; the main task then consumes them with
  `std.c.sigwait` (no async-signal-safety concerns). `SIGHUP` reloads,
  `SIGUSR1` logs status, `SIGTERM`/`SIGINT` exit 0.
- **Half-close**: each copy direction loops on
  `reader.interface.stream(&writer.interface, .limited(16 KiB))` and flushes the
  writer after every chunk; `EndOfStream` ends the loop, a read/write error is
  logged, and a 0-byte chunk is treated as EOF. Flushing per chunk is required:
  with a single `.unlimited` copy that only flushes at EOF, a client that sends a
  request and then waits (the normal HTTP pattern) never gets its request
  delivered, and sub-buffer responses stay invisible until the peer closes. On
  EOF the client→backend direction issues `shutdown(.send)` on the backend
  (Go `CloseWrite`); backend→client issues `shutdown(.recv)` on the client
  (Go `CloseRead`). Both directions then finish and the sockets are closed.
- **Keepalive**: `SO_KEEPALIVE` + `TCP.KEEPIDLE=60` on both sockets via
  `std.posix.setsockopt`, matching Go's `SetKeepAlive(true)` /
  `SetKeepAlivePeriod(60s)`.
- **DNS**: non-IP host names (e.g. `localhost`) are resolved through
  `std.Io.net.HostName.lookup` with a 16-entry queue; the first returned
  address is used, mirroring Go's `DialTimeout` which resolves via the
  resolver.

## Deviations from the Go behavior

- **`SIGUSR1` status**: Go prints the goroutine count and a full stack dump.
  The Zig port logs `active_connections` / `total_connections` counters and a
  short backend summary instead, as permitted by the task brief.
- **Usage message**: Go's `flag` package prints `Usage: <prog> [options] config_file`
  plus `-listen` help. The Zig port prints the same text but exit codes are:
  `0` for explicit `-h`, `1` for missing config (same as Go's `usage()`),
  whereas Go's flag package uses exit code 2 for parse errors.
- **Log format on fatal startup errors**: Go uses `log.Fatalf` which prefixes
  with the timestamp; the port prints the same timestamped line and exits 1.
- **`config.weight_sum` type**: `i64` instead of Go's `int` (64-bit on the
  reference platform, so equivalent).
- **Accept-error classification**: Go checks `net.Error.Temporary()`. The port
  maps the transient `AcceptError` variants (`ProcessFdQuotaExceeded`,
  `SystemFdQuotaExceeded`, `SystemResources`, `ConnectionAborted`,
  `WouldBlock`) to continue, everything else stops the loop.
- **`--selftest` flag**: extra hidden flag, not present in Go. Exercises the
  forwarding path over a Unix socketpair for restricted sandboxes.

## Verification results (cloud host, 2026-11-14)

- `zig build` clean; `zig build test` **10/10** pass (config parse incl. JSON `null`,
  validation, weight overflow rejection, weighted choice, connect-error mapping,
  forwarding group await, request/response without client half-close, 1 MiB payload
  integrity).
- `python3 verify/acceptance.py zig-out/bin/gopf` → **ALL PASS (10 checks)**: forwarding +
  client half-close, backend-initiated close, weighted 1/1 (≈50/50), `SIGHUP` reload,
  failed reload keeps the old config live, HTTP-like request/response without client
  half-close, 1 MiB payload sha256 match, `SIGUSR1` status, 100 concurrent connections
  (0 errors), `SIGTERM` exit 0.
- Hardening run: invalid configs (negative weight / bad addr / port > 65535 / malformed
  JSON / i64 weight overflow) all rejected with exit 1; 30 `SIGHUP` reloads during
  sustained traffic (20 workers + 1 long-lived connection) → no crash, no errors, fd
  count unchanged (4 → 4), clean exit.
- Benchmark with the repository's shared `bench_backend` / `bench_load` (see `bench.md`):
  4 vCPU Xeon 8457C, 396-byte responses, 100 connections, three rounds, median —
  Zig **15,835 rps** (p50 5.86 ms, p99 14.28 ms) vs Go reference **14,530 rps**
  (p50 6.36 ms, p99 15.57 ms) → **1.09×**. 1 MiB responses: Zig 552 rps ≈ 579 MB/s,
  Go 549 rps ≈ 576 MB/s (within noise).

## Known limitations

- Development happened in a sandbox that blocks `socket()` with `EPERM`; every
  end-to-end TCP check above was executed on the unrestricted cloud host.
  `--selftest` remains as an offline fallback for restricted environments.
- Hostname resolution relies on `/etc/hosts` + DNS via `std.Io.net.HostName`;
  there is no support for scoped IPv6 (`fe80::1%eth0`) in config addresses.
- The weight distribution uses one PRNG protected by a mutex, identical in
  statistical behavior to Go but not goroutine-parallel like `math/rand`'s
  fast path; contention is negligible for this workload.
