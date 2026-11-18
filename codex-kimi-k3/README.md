# gopf-zig (codex + kimi-k3)

Zig 0.17 port of [`gopf`](https://github.com/RaindyRoye/gopf), a weighted-random
TCP port forwarder / load balancer. Implemented by codex CLI running the
kimi-k3 model; verified independently against real TCP.

## Build

```
zig build
```

Produces `zig-out/bin/gopf`.

Run unit tests:

```
zig build test
```

Optimized build (used for benchmarks):

```
zig build -Doptimize=ReleaseFast
```

## Run

```
zig-out/bin/gopf [-listen ADDR] config_file
```

- `-listen` defaults to `:1248`. Empty host binds all interfaces.
- `config_file` is JSON; keys match Go's `encoding/json` case-insensitively,
  so both `{"Hosts":[{"Addr":"…","Weight":100}]}` and lowercase variants parse.

Example:

```
zig-out/bin/gopf -listen :1248 examples/settings.conf
```

## Signals

| Signal    | Behavior                                            |
|-----------|-----------------------------------------------------|
| `SIGHUP`  | Reload config; on failure the old config stays live |
| `SIGUSR1` | Log a status line (live/total connection counts)    |
| `SIGTERM` | Log and exit 0                                       |
| `SIGINT`  | Log and exit 0                                       |

## Acceptance tests

Independent external harness (requires `python3` and unrestricted loopback
TCP):

```
python3 verify/acceptance.py zig-out/bin/gopf
```

Covers forwarding, client half-close propagation, weighted selection,
backend-initiated close, `SIGHUP` reload, failed reload keeping the old config,
request/response without client half-close (HTTP-like), 1 MiB payload integrity,
`SIGUSR1` status, 100 concurrent connections, and `SIGTERM` exit code 0.

In restricted environments where `socket()` is unavailable,
`./zig-out/bin/gopf --selftest` runs the forwarding path over a Unix
socketpair.

## Performance benchmark

Uses the shared tools from the repository root (see `task.md`), so numbers are
directly comparable with the other agents and the Go baseline:

```
go build -o bench_backend bench_backend.go   # 396 bytes on /, 1 MiB on /big
go build -o bench_load bench_load.go
./bench_backend -addr 127.0.0.1:18091 &
./bench_load -addr 127.0.0.1:12481 -conns 50 -reqs 2000     # warmup
./bench_load -addr 127.0.0.1:12481 -conns 100 -reqs 10000   # 3 rounds, take median
./bench_load -addr 127.0.0.1:12481 -path /big -conns 4 -reqs 100
```

Results and the comparison against the Go original: `bench.md`.

## Layout

- `src/main.zig` — CLI, signals, accept loop, forwarding, self-test hook.
- `src/config.zig` — JSON config parsing, validation, weighted host choice.
- `src/log.zig` — Go-style `YYYY/MM/DD HH:MM:SS` stderr logging.
- `examples/` — sample config files.
- `IMPL-NOTES.md` — design choices, deviations, known limitations.
