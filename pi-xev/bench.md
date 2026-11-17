# pi-xev 压测（macOS arm64）

- 机器：darwin arm64，Zig 0.17.1，`ReleaseFast`，libxev kqueue
- 后端：`bench_backend -addr 127.0.0.1:18091`（396 B）
- 压测：`bench_load`，每连接一次请求

| 场景 | rps | mean | p50 | p99 |
|---|---|---|---|---|
| 10000 / 100 轮1 | 13165 | 7.57 ms | 7.07 ms | 10.27 ms |
| 10000 / 100 轮2 | 11912 | 8.37 ms | 7.33 ms | 19.38 ms |
| 20000 / 200 | 10757 | 18.56 ms | 14.93 ms | 132.06 ms |

同机对照（同日、同后端）：

| 实现 | 10000/100 较好一轮 | 20000/200 |
|---|---|---|
| pi-zio | 14272 rps | 11390 rps |
| pi-xev | 13165 rps | 10757 rps |
| pi（原 poll 池） | 10429 rps | 9867 rps |

说明：压测中 libxev 大量打印 `invalid state in submission queue state=.active`，功能可用但 completion 复用仍有问题。
