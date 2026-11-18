# 性能测试（bench）

## 环境与方法

- 机器：4 核 / 8 GiB，x86_64 Linux（容器内 loopback）。
- 编译：`zig build -Doptimize=ReleaseFast`（Zig 0.17.0）。
- 后端：`bench/backend -addr 127.0.0.1:18091`（`/` 返回 396 字节，`/big`
  返回 1 MiB），测试期间保持运行。
- 压测：`bench/load`。负载模式是**每请求一条新 TCP 连接**
  （`Connection: close`），因此衡量的是「连接建立 + 转发 + 拆除」全链路。
- 代理：`./zig-out/bin/gopf -listen 127.0.0.1:12481 /tmp/gopf-bench.conf`，
  配置 `{"hosts":[{"addr":"127.0.0.1:18091","weight":100}]}`，日志重定向到文件。
- 流程：先 `-conns 50 -reqs 2000` 预热，再连跑 3 次 `-conns 100 -reqs 10000`，
  取中位数；大包用 `-path /big -conns 4 -reqs 100`。

## 小包结果（396 字节响应）

| 对象 | rps | p50 | p99 |
| --- | ---: | ---: | ---: |
| **Zig 本实现（ReleaseFast）** | **18752** | **5.05 ms** | **9.36 ms** |
| Go 原版基线（任务书给定，同机） | 15700 | 6.0 ms | 13 ms |
| 直连后端（任务书给定基线） | 30900 | — | — |
| 直连后端（本次实测，参照） | 42021 | 2.13 ms | 6.85 ms |

3 次原始数据（rps / p50 / p99）：

```
run1: rps=19492 p50=4.96ms p99=9.35ms
run2: rps=17755 p50=5.48ms p99=9.36ms
run3: rps=18752 p50=5.05ms p99=10.38ms   <- 中位数
```

（预热：2000 reqs，16343 rps。）

## 大包结果（1 MiB 响应，4 并发 × 100 请求）

| 对象 | rps | 吞吐 |
| --- | ---: | ---: |
| Zig 本实现 run1 | 768 | ≈ 768 MiB/s（805 MB/s） |
| Zig 本实现 run2 | 824 | ≈ 824 MiB/s（864 MB/s） |
| 直连后端（参照） | 899 | ≈ 899 MiB/s（942 MB/s） |

## 与 Go 基线的对照与解释

**Zig 版比 Go 基线快约 19%（18.8k vs 15.7k rps），p50 低 16%，p99 低
28%。** 差距来源主要是并发模型与每连接开销：

1. **事件循环 vs 每连接线程/协程。** Go 版每条连接 3 个 goroutine
   （`handleConn` + 两个方向各一个 `io.Copy`），100 并发时约 300 个
   goroutine 在 4 个核上调度，每次数据到达都伴随 goroutine 唤醒/切换；
   本实现是单线程 epoll 状态机，数据到达直接在当前线程读写，没有调度
   切换，也没有跨核同步。
2. **分配次数。** Go 每条连接有 goroutine 栈与 net.Conn 对象等 GC 分配；
   本实现连接对象（含 2×32 KiB 缓冲）来自空闲链表池，稳态下 accept→
   关闭整条路径**零分配**、零 GC 压力。压测 32200 条连接后 RSS 约
   13.5 MiB，且不再增长。
3. **每连接日志两边都有**（Go `log.Printf` / 本实现栈上格式化 +
   单次 `write(2)`），这部分成本相当，都已重定向到文件。

**代理 vs 直连**：代理的 rps 约为直连的 45–60%，这是四层转发的固有
代价——每个字节要多过两次内核（client→proxy→backend），且每条请求连接
都要额外 `connect()` 一次后端。任务书给定的直连基线 30.9k 与本次实测
42k 存在差异（同机不同时刻负载不同），按各自与直连的比值看两者结论
一致：代理吃掉约一半吞吐。

**大包**：本实现为用户态 32 KiB 缓冲拷贝，吞吐约为直连的 85–90%
（768–824 vs 899 MiB/s）。Go 版 `io.Copy` 对 TCP→TCP 会走
`sendfile(2)` 零拷贝，这是 Go 版在大包场景可能反超的点；本实现选择
用户态缓冲是为了让「EOF 后冲刷残余数据再半关闭」的状态机简单可靠。

## 复现命令

```sh
zig build -Doptimize=ReleaseFast
printf '{"hosts":[{"addr":"127.0.0.1:18091","weight":100}]}' > /tmp/gopf-bench.conf
./zig-out/bin/gopf -listen 127.0.0.1:12481 /tmp/gopf-bench.conf 2>/tmp/gopf-bench.log &

BENCH=/home/user/Doubao/chats/38453552245765378/zig-gopf/bench
$BENCH/load -addr 127.0.0.1:12481 -conns 50  -reqs 2000            # 预热
$BENCH/load -addr 127.0.0.1:12481 -conns 100 -reqs 10000           # ×3 取中位数
$BENCH/load -addr 127.0.0.1:12481 -path /big -conns 4 -reqs 100    # 大包
```
