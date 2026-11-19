# gopf (Zig)

A four-layer TCP load balancer, rewritten in Zig 0.17 from the Go reference
implementation. Only the Zig standard library and Linux syscalls are used; no
third-party dependencies and no Go binary is invoked.

## Build

```sh
zig build                         # debug binary at zig-out/bin/gopf
zig build -Doptimize=ReleaseFast  # optimized binary
zig build test                    # unit + integration tests
```

Zig used here: `/home/user/.local/bin/zig` (0.17.0).

## Run

```sh
./zig-out/bin/gopf -listen 127.0.0.1:12481 settings.conf
```

`-listen` defaults to `:1248`. The first positional argument is the JSON config:

```json
{
  "hosts": [
    { "addr": "127.0.0.1:18091", "weight": 100 }
  ]
}
```

Keys are matched case-insensitively, so the reference file's `Hosts` / `Addr` /
`Weight` style also works. Unknown fields such as `traffic_url` are ignored.

Signals:

| Signal | Action |
| --- | --- |
| `SIGHUP` | Reload the config. On any error the old config stays active. |
| `SIGUSR1` | Print active/total connection counts and the current backend list. |
| `SIGTERM`, `SIGINT` | Exit. |

Accepted connections, dial failures, reload results, and status are printed to
stderr.

## Behaviour

* Backend choice is **weighted random**, not round-robin: draw
  `r in [0, weightSum)` and walk cumulative weights. If `weightSum <= 0`
  (empty backend list or all-zero weights), the client connection is closed
  immediately.
* Each client connection selects a backend and dials it with a 5-second
  timeout.
* Both sockets get TCP keepalive, 60 seconds.
* Forwarding is bidirectional. On EOF (or a read error) in one direction, the
  peer's write side is shut down with `shutdown(SHUT_WR)`. The other direction
  keeps running, and both sockets are closed only after both directions end.
* Config validation rejects the whole file if any address cannot be split into
  `host:port` or any weight is negative. Empty `hosts` and all-zero weights are
  valid and simply mean "no usable backend".

## Design choices

### Threading model

A fixed worker pool of 128 OS threads consumes accepted sockets from a bounded
queue (8192 entries). This avoids creating one thread per request, which is the
dominant cost for short HTTP-style connections. The bounded queue provides
backpressure instead of unbounded memory/fd growth.

Each connection is handled entirely by one worker. Inside the worker a single
`poll()` loop drives both directions, with two 64 KiB stack buffers. This costs
one thread per in-flight connection (not two copy threads), and naturally
implements the half-close rule: when one direction reaches EOF, flush its
buffered bytes, `shutdown(SHUT_WR)` on the destination, then keep polling the
other direction.

Dialing uses raw Linux syscalls: a nonblocking `connect()` plus `poll()` for the
5-second timeout, then the fd is switched back to blocking mode. This is
necessary because this Zig standard-library revision does not implement the
`std.Io` connect-timeout path. Listening/accepting use `std.Io.net`; hostname
resolution goes through `std.Io` (`/etc/hosts` and DNS), while numeric
addresses avoid I/O.

### Memory allocation

* The steady-state connection path performs **no heap allocation** per
  connection. Buffers live on the worker stack; accepted sockets sit in a
  fixed-size queue; backend choice copies at most 512 bytes to a stack buffer.
* Config objects own their address strings and are heap-allocated once per
  successful load. A reload builds and validates the complete new config
  before touching the active one. On failure the new one is discarded.
* The active-config mutex is held only while copying the selected backend
  address, so a reload can free the old config immediately after the swap.
* JSON parsing uses a temporary `std.json` parse tree that is freed before the
  config is installed.

### Deliberate trade-offs

The worker pool is simpler and much faster at this connection rate than
spawning a thread per accept, but a fixed 128 workers caps concurrency if all
workers are blocked on slow backends. Goroutines have no such hard cap. An
epoll-based single-thread state machine would reduce thread count further, at
the cost of substantially more connection-state machinery. The current model
matches the reference's straightforward "block per connection" semantics while
staying close to the Go baseline on this workload.

## Tests

`zig build test` runs:

* config parsing: valid config, capitalized keys, empty hosts, all-zero
  weights, invalid addresses, negative weights, malformed JSON;
* weighted selection: 1:2 ratio over 100,000 draws, zero-weight hosts never
  selected, `weightSum <= 0` returns no backend;
* host:port splitting and rejection cases;
* integration tests with a real in-process echo TCP server:
  * small-payload echo with the client half-closing its write side;
  * 2 MiB payload checked byte-for-byte (covers half-close and large transfer);
  * reload swapping the backend selection set;
  * all-zero weights closing the client connection.

Performance results are in [bench.md](bench.md).