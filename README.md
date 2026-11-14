# agent-repro-gopf

同一道题交给两个 Agent 独立完成，用来对比「复现一个已有实现」这件事上的差异。

- 题目：用 **Zig 0.17** 复现 [RaindyRoye/gopf](https://github.com/RaindyRoye/gopf)（308 行的 Go 四层负载均衡器），要求带单元/集成测试与性能测试。
- 方式：两边拿到完全相同的任务书（`task.md`），串行执行，互不可见；不共享代码，只共享压测工具与后端。
- 结构：仓库第一层目录就是 Agent 名字。
  - `pi/` — pi（pi-mono）的实现与报告
  - `kimi-code/` — kimi-code 的实现与报告
- 每个目录内：`src/`、`build.zig`、`README.md`（设计与运行方式）、`bench.md`（性能数据）。

## 复现方法

```bash
cd pi        # 或 kimi-code
zig build test
zig build -Doptimize=ReleaseFast
./zig-out/bin/gopf -listen 127.0.0.1:12481 settings.conf
```

后端与压测器需先编译：

```bash
go build -o bench_backend bench_backend.go   # 监听 127.0.0.1:18091
go build -o bench_load bench_load.go
./bench_backend -addr 127.0.0.1:18091 &
./bench_load -addr 127.0.0.1:12481 -conns 100 -reqs 10000
```

基线（同机、Go 原版 gopf）：15.7k rps，p50 6.0 ms，p99 13 ms；直连后端 30.9k rps。

结果对照见 `复现对比.md`。
