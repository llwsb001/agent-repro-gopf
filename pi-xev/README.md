# pi-xev

基于 `pi/` 的 gopf 复现，用 [libxev](https://github.com/mitchellh/libxev) 回调式事件循环做 accept → connect → 双向 read/write。

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/gopf -listen 127.0.0.1:12482 settings.conf
```

压测数据见 `bench.md`。高并发下 kqueue 后端会刷 `invalid state in submission queue`（连接仍能完成，但生命周期还有毛刺）。
