# pi-zio

基于 `pi/` 的 gopf 复现，用 [zio](https://github.com/yujincheng08/zio) 协程运行时做 TCP 双向转发（`std.Io` 风格流 + `Group` 双向 copy）。

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/gopf -listen 127.0.0.1:12481 settings.conf
```

压测数据见 `bench.md`。
